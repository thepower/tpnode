-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-compile(nowarn_export_all).
%-compile(export_all).
-endif.

-export([start_link/0]).
-export([generate_block/5, decode_tpic_txs/1, sort_txs/1]).

-type mkblock_acc() :: #{'emit':=[{_,_}],
                         'export':=list(),
                         'failed':=[{_,_}],
                         'fee':=bal:bal(),
                         'tip':=bal:bal(),
                         'height':=number(),
                         'outbound':=[{_,_}],
                         'parent':=binary(),
                         'table':=map(),
                         'pick_block':=#{_=>1},
                         'settings':=[{_,_}],
                         'success':=[{_,_}]
                        }.

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, #{
       nodeid=>nodekey:node_id(),
       preptxl=>[],
       settings=>#{}
      }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin) of
        {ok, Struct} ->
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            lager:info("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
           <<"hash">> := ParentHash,
           <<"signed">> := SignedBy
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  lager:debug("MB presig got ~s ~p", [Origin, SignedBy]),
  if Origin==false ->
       {noreply, State};
     true ->
       PreSig=maps:get(presig, State, #{}),
       {noreply,
      State#{
        presig=>maps:put(Origin, {ParentHash, SignedBy}, PreSig)
       }}
  end;

handle_cast({tpic, Origin, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"txs">>:=TPICTXs
                    }}, State)  ->
  TXs=decode_tpic_txs(TPICTXs),
  if TXs==[] -> ok;
     true ->
       lager:info("Got txs from ~s: ~p",
            [
             chainsettings:is_our_node(Origin),
             TXs
            ])
  end,
  handle_cast({prepare, Origin, TXs}, State);

handle_cast({prepare, Node, Txs}, #{preptxl:=PreTXL}=State) ->
  Origin=chainsettings:is_our_node(Node),
  if Origin==false ->
       lager:error("Got txs from bad node ~s",
             [bin2hex:dbin2hex(Node)]),
       {noreply, State};
     true ->
       if Txs==[] -> ok;
        true ->
          lager:info("TXs from node ~s: ~p",
               [ Origin, length(Txs) ])
       end,
       MarkTx=fun({TxID, TxB}) ->
              TxB1=try
                     case TxB of
                       #{patch:=_} ->
                         VerFun=fun(PubKey) ->
                                    NodeID=chainsettings:is_our_node(PubKey),
                                    is_binary(NodeID)
                                end,
                         {ok, Tx1} = settings:verify(TxB, VerFun),
                         tx:set_ext(origin, Origin, Tx1);
                       #{ hash:=_,
                          header:=_,
                          sign:=_} ->
                         %do nothing with inbound block
                         TxB;
                       _ ->
                         {ok, Tx1} = tx:verify(TxB),
                         tx:set_ext(origin, Origin, Tx1)
                     end
                 catch _Ec:_Ee ->
                     S=erlang:get_stacktrace(),
                     lager:error("Error ~p:~p", [_Ec, _Ee]),
                     lists:foreach(fun(SE) ->
                                 lager:error("@ ~p", [SE])
                             end, S),
                     file:write_file("tmp/mkblk_badsig_" ++ binary_to_list(nodekey:node_id()),
                             io_lib:format("~p.~n", [TxB])),

                     TxB
                 end,
              {TxID,TxB1}
          end,
       {noreply,
      case maps:get(parent, State, undefined) of
        undefined ->
          #{header:=#{height:=Last_Height}, hash:=Last_Hash}=gen_server:call(blockchain, last_block),
          State#{
            preptxl=>PreTXL ++ lists:map(MarkTx, Txs),
            parent=>{Last_Height, Last_Hash}
           };
        _ ->
          State#{ preptxl=>PreTXL ++ lists:map(MarkTx, Txs) }
      end
       }
  end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("MB unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(process, #{settings:=#{mychain:=MyChain}=MySet, preptxl:=PreTXL0}=State) ->
  lager:info("-------[MAKE BLOCK]-------"),
  PreTXL1=lists:foldl(
            fun({TxID, TXB}, Acc) ->
                case maps:is_key(TxID, Acc) of
                  true ->
                    TXB1=tx:mergesig(TXB,
                                     maps:get(TxID, Acc)),
                    {ok, Tx1} = tx:verify(TXB1),
                    maps:put(TxID, Tx1, Acc);
                  false ->
                    maps:put(TxID, TXB, Acc)
                end
            end, #{}, PreTXL0),
  PreTXL=lists:keysort(1, maps:to_list(PreTXL1)),

  AE=maps:get(ae, MySet, 1),

  {_, ParentHash}=Parent=case maps:get(parent, State, undefined) of
                           undefined ->
                             lager:info("Fetching last block from blockchain"),
                             #{header:=#{height:=Last_Height1}, hash:=Last_Hash1}=gen_server:call(blockchain, last_block),
                             {Last_Height1, Last_Hash1};
                           {A, B} -> {A, B}
                         end,

  PreNodes=try
             PreSig=maps:get(presig, State),
             BK=maps:fold(
                  fun(_, {BH, _}, Acc) when BH =/= ParentHash ->
                      Acc;
                     (Node1, {_BH, Nodes2}, Acc) ->
                      [{Node1, Nodes2}|Acc]
                  end, [], PreSig),
             lists:sort(bron_kerbosch:max_clique(BK))
           catch Ec:Ee ->
                   Stack1=erlang:get_stacktrace(),
                   lager:error("Can't calc xsig ~p:~p ~p", [Ec, Ee, Stack1]),
                   []
           end,

  try
    if(AE==0 andalso PreTXL==[]) -> throw(empty);
      true -> ok
    end,
    T1=erlang:system_time(),
    lager:debug("MB pre nodes ~p", [PreNodes]),

    PropsFun=fun(mychain) ->
                 MyChain;
                (settings) ->
                 blockchain:get_settings();
                ({valid_timestamp, TS}) ->
                 abs(os:system_time(millisecond)-TS)<3600000;
                ({endless, From, Cur}) ->
                 EndlessPath=[<<"current">>, <<"endless">>, From, Cur],
                 case blockchain:get_settings(EndlessPath) of
                   true -> true;
                   _ ->
                     % TODO 2018-05-01: Replace this code with false
                     Endless=lists:member(
                               From,
                               application:get_env(tpnode, endless, [])
                              ),
                     if Endless ->
                          lager:notice("Deprecated: issue tokens by address in config");
                        true ->
                          ok
                     end,
                     Endless
                 end;
                ({get_block, Back}) when 32>=Back ->
                 FindBlock=fun FB(H, N) ->
                 case gen_server:call(blockchain, {get_block, H}) of
                   undefined ->
                     undefined;
                   #{header:=#{parent:=P}}=Blk ->
                     if N==0 ->
                          maps:without([bals, txs], Blk);
                        true ->
                          FB(P, N-1)
                     end
                 end
             end,
    FindBlock(last, Back)
  end,
  AddrFun=fun({Addr, _Cur}) ->
              case ledger:get(Addr) of
                #{amount:=_}=Bal -> Bal;
                not_found -> bal:new()
              end;
             (Addr) ->
              case ledger:get(Addr) of
                #{amount:=_}=Bal -> Bal;
                not_found -> bal:new()
              end
          end,

  #{block:=Block,
    failed:=Failed,
    emit:=EmitTXs}=generate_block(PreTXL, Parent, PropsFun, AddrFun,
                                  [{<<"prevnodes">>, PreNodes}]),
  T2=erlang:system_time(),
  if Failed==[] ->
       ok;
     true ->
       %there was failed tx. Block empty?
       gen_server:cast(txpool, {failed, Failed}),
       if(AE==0) ->
           case maps:get(txs, Block, []) of
             [] -> throw(empty);
             _ -> ok
           end;
         true ->
           ok
       end
  end,
  Timestamp=os:system_time(millisecond),
  ED=[
      {timestamp, Timestamp},
      {createduration, T2-T1}
     ],
  SignedBlock=sign(Block, ED),
  #{header:=#{height:=NewH}}=Block,
  %cast whole block for my local blockvote
  gen_server:cast(blockvote, {new_block, SignedBlock, self()}),

  case application:get_env(tpnode, dumpblocks) of
    {ok, true} ->
      file:write_file("tmp/mkblk_" ++
                      integer_to_list(NewH) ++ "_" ++
                      binary_to_list(nodekey:node_id()),
                      io_lib:format("~p.~n", [SignedBlock])
                     );
    _ -> ok
  end,
  %Block signature for each other
  lager:info("MB My sign ~p emit ~p",
             [
              maps:get(sign, SignedBlock),
              length(EmitTXs)
             ]),
  HBlk=msgpack:pack(
         #{null=><<"blockvote">>,
           <<"n">>=>node(),
           <<"hash">>=>maps:get(hash, SignedBlock),
           <<"sign">>=>maps:get(sign, SignedBlock),
           <<"chain">>=>MyChain
          }
        ),
  tpic:cast(tpic, <<"blockvote">>, HBlk),
  if EmitTXs==[] -> ok;
     true ->
       lager:info("Inject TXs ~p", [
                                    gen_server:call(txpool, {push_etx, EmitTXs})
                                   ])
  end,
  {noreply, State#{preptxl=>[], parent=>undefined, presig=>#{}}}
catch throw:empty ->
        lager:info("Skip empty block"),
        {noreply, State#{preptxl=>[], parent=>undefined, presig=>#{}}}
    end;

handle_info(process, State) ->
    lager:notice("MKBLOCK Blocktime, but I not ready"),
    {noreply, load_settings(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

getaddr([], _GetFun, Fallback) ->
  Fallback;

getaddr([E|Rest], GetFun, Fallback) ->
  case GetFun(E) of
    B when is_binary(B) ->
      B;
    _ ->
      getaddr(Rest, GetFun, Fallback)
  end.

deposit_fee(#{amount:=Amounts}, Addr, Addresses, TXL, GetFun, Settings) ->
  TBal=maps:get(Addr, Addresses, bal:new()),
  {TBal2, TXL2}=maps:fold(
           fun(Cur, Summ, {Acc, TxAcc}) ->
               {NewT, NewTXL, _}=deposit(Addr, Acc,
                           #{cur=>Cur,
                           amount=>Summ,
                           to=>Addr},
                           GetFun, Settings),
               {NewT, TxAcc ++ NewTXL}
           end,
      {TBal, TXL},
      Amounts),
  if TBal==TBal2 ->
       {Addresses, TXL2};
     true ->
       {maps:put(Addr,
           maps:remove(keep, TBal2),
           Addresses), TXL2}
  end.

-spec try_process([{_,_}], map(), map(), fun(), mkblock_acc()) -> mkblock_acc().
try_process([], Settings, Addresses, GetFun,
      #{fee:=FeeBal, tip:=TipBal, emit:=Emit}=Acc) ->
  try
    GetFeeFun=fun (Parameter) ->
              settings:get([<<"current">>, <<"fee">>, params, Parameter], Settings)
          end,
    lager:debug("fee ~p tip ~p", [FeeBal, TipBal]),
    {Addresses2, NewEmit}=lists:foldl(
                fun({CType, CBal}, {FAcc, TXL}) ->
                    Addr=case CType of
                         fee ->
                           getaddr([<<"feeaddr">>],
                               GetFeeFun,
                               naddress:construct_private(0, 0));
                         tip ->
                           getaddr([<<"tipaddr">>,
                              <<"feeaddr">>],
                               GetFeeFun,
                               naddress:construct_private(0, 0)
                              );
                         _ ->
                           naddress:construct_private(0, 0)
                       end,
                    lager:debug("fee ~s ~p to ~p", [CType, CBal, Addr]),
                    deposit_fee(CBal, Addr, FAcc, TXL, GetFun, Settings)
                end,
                {Addresses, []},
                [ {tip, TipBal}, {fee, FeeBal} ]
               ),
    if NewEmit==[] -> ok;
       true ->
         lager:info("NewEmit ~p", [NewEmit])
    end,
    Acc#{table=>Addresses2,
       emit=>Emit ++ NewEmit
      }
  catch _Ec:_Ee ->
        S=erlang:get_stacktrace(),
        lager:error("Can't save fees: ~p:~p", [_Ec, _Ee]),
        lists:foreach(fun(E) ->
                  lager:info("Can't save fee at ~p", [E])
              end, S),
        Acc#{table=>Addresses}
  end;

%process inbound block
try_process([{BlID, #{ hash:=BHash,
                       txs:=TxList,
                       header:=#{chain:=ChID,height:=BHeight} }=Blk}|Rest],
            SetState, Addresses, GetFun, #{
                                   settings:=Settings,
                                   failed:=Failed
                                  }=Acc) ->
  try
    MyChain=GetFun(mychain),
    OPatchTxID= <<"out", (xchain:pack_chid(MyChain))/binary>>,
    P=proplists:get_value(OPatchTxID,maps:get(settings, Blk,[]), undefined),
    ChainPath=[<<"current">>, <<"sync_status">>, xchain:pack_chid(ChID)],
    {ChainLastHash, ChainLastHei}=case settings:get(ChainPath, SetState) of
                                    #{<<"block">> := LastBlk,
                                      <<"height">> := LastHeight} ->
                                      if(BHeight>LastHeight) -> ok;
                                        true -> throw({overdue, BHash})
                                      end,
                                      {LastBlk, LastHeight};
                                    _ ->
                                      {<<0:64/big>>, 0}
                                  end,
    lager:info("SyncState ~p", [ChainLastHei]),

    IncPtr=[#{<<"t">> => <<"set">>,
              <<"p">> => ChainPath ++ [<<"block">>],
              <<"v">> => BHash
             },
            #{<<"t">> => <<"set">>,
              <<"p">> => ChainPath ++ [<<"height">>],
              <<"v">> => BHeight
             }
           ],
    PatchTxID= <<"sync", (xchain:pack_chid(ChID))/binary>>,
    SyncPatch={PatchTxID, #{sig=>[], patch=>IncPtr}},
    if P==undefined ->
         lager:notice("Old block without settings"),
         try_process([ {TxID,
                        Tx#{
                          origin_block_hash=>BHash,
                          origin_block_height=>BHeight,
                          origin_block=>BlID,
                          origin_chain=>ChID
                         }
                       } || {TxID, Tx} <- TxList ] ++ Rest,
                     SetState, Addresses, GetFun, Acc#{
                                                    settings=>[SyncPatch|lists:keydelete(PatchTxID, 1, Settings)]
                                                   });
       true ->
         IWS=settings:get([<<"current">>,<<"outward">>,xchain:pack_chid(MyChain)],settings:patch(P,#{})),
         case IWS of
           #{<<"pre_hash">> := <<0,0,0,0,0,0,0,0>>,<<"pre_height">> := 0} ->
             lager:debug("New inbound block from ~b with patch ~p",[ChID,IWS]),
             ok;
           #{<<"pre_hash">> := ChainLastHash,<<"pre_height">> := ChainLastHei} ->
             lager:debug("New inbound block from ~b with patch ~p",[ChID,IWS]),
             ok;
           #{<<"pre_hash">> := NeedHash ,<<"pre_height">> := PH} when PH>ChainLastHei ->
             lager:debug("New inbound block from ~b with patch ~p, skipped_block",[ChID,IWS]),
             throw({'block_skipped',NeedHash});
           #{<<"pre_hash">> := _ ,<<"pre_height">> := PH} when PH<ChainLastHei ->
             lager:debug("New inbound block from ~b with patch ~p, overdue",[ChID,IWS]),
             throw({'overdue',BHash});
           #{<<"pre_parent">> := _,<<"pre_height">> := LastHei} when LastHei==ChainLastHei;
                                                                       ChainLastHei==0 ->
             lager:notice("New inbound block with no hash, looking for parent from ~b with patch ~p",[ChID,IWS]),
             lager:notice("Disable this after sync all chains!!!!"),
             ok
         end,

         SS1=settings:patch(SyncPatch, SetState),
         try_process([ {TxID,
                        Tx#{
                          origin_block_hash=>BHash,
                          origin_block_height=>BHeight,
                          origin_block=>BlID,
                          origin_chain=>ChID
                         }
                       } || {TxID, Tx} <- TxList ] ++ Rest,
                     SS1, Addresses, GetFun, Acc#{
                                               settings=>[SyncPatch|lists:keydelete(PatchTxID, 1, Settings)]
                                              })
    end
  catch throw:Ee ->
          lager:info("Fail to process inbound ~p ~p", [BlID, Ee]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{BlID, Ee}|Failed]
                       });
        Ec:Ee ->
          S=erlang:get_stacktrace(),
          lager:info("Fail to process inbound block ~p ~p:~p",
                     [BlID, Ec, Ee]),
          lager:info("at ~p", [S]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{BlID, unknown}|Failed]
                       })
  end;


%process settings
try_process([{TxID,
              #{patch:=_LPatch,
                sig:=_,
                sigverify:=#{valid:=ValidSig}
               }=Tx}|Rest], SetState, Addresses, GetFun,
            #{failed:=Failed,
              settings:=Settings}=Acc) ->
  try
    NeedSig=chainsettings:get(patchsig,SetState),
    if(length(ValidSig)<NeedSig) ->
        throw({patchsig, NeedSig});
      true ->
        ok
    end,
    SS1=settings:patch({TxID, Tx}, SetState),
    lager:info("Success Patch ~p against settings ~p", [_LPatch, SetState]),
    try_process(Rest, SS1, Addresses, GetFun,
                Acc#{
                  settings=>[{TxID, Tx}|Settings]
                 }
               )
  catch throw:Ee ->
          lager:info("Fail to Patch ~p ~p",
                     [_LPatch, Ee]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{TxID, Ee}|Failed]
                       });
        Ec:Ee ->
          S=erlang:get_stacktrace(),
          lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                     [_LPatch, Ec, Ee, SetState]),
          lager:info("at ~p", [S]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{TxID, Tx}|Failed]
                       })
  end;

try_process([{TxID, #{ver:=2,
                      kind:=patch,
                      patches:=[_|_]=_LPatch,
                      sigverify:=#{
                        pubkeys:=[_|_]=PubKeys
                       }
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              settings:=Settings}=Acc) ->
  try
    NeedSig=chainsettings:get(patchsig,SetState),
    if(length(PubKeys)<NeedSig) ->
        throw({patchsig, NeedSig});
      true ->
        ok
    end,
    SS1=settings:patch({TxID, Tx}, SetState),
    lager:info("Success Patch ~p against settings ~p", [_LPatch, SetState]),
    try_process(Rest, SS1, Addresses, GetFun,
                Acc#{
                  settings=>[{TxID, Tx}|Settings]
                 }
               )
  catch throw:Ee ->
          lager:info("Fail to Patch ~p ~p",
                     [_LPatch, Ee]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{TxID, Ee}|Failed]
                       });
        Ec:Ee ->
          S=erlang:get_stacktrace(),
          lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                     [_LPatch, Ec, Ee, SetState]),
          lager:info("at ~p", [S]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{TxID, Tx}|Failed]
                       })
  end;



try_process([{TxID,
              #{seq:=_Seq, timestamp:=_Timestamp, to:=To, portin:=PortInBlock}=Tx}
             |Rest],
            SetState, Addresses, GetFun,
            #{success:=Success, failed:=Failed}=Acc) ->
    lager:notice("TODO:Check signature once again and check seq"),
    try
    throw('fixme'),
        Bals=maps:get(To, Addresses),
        case Bals of
            #{} ->
                ok;
            #{chain:=_} ->
                ok;
            _ ->
                throw('address_exists')
        end,
        lager:notice("TODO:check block before porting in"),
        NewAddrBal=maps:get(To, maps:get(bals, PortInBlock)),

        NewAddresses=maps:fold(
                       fun(Cur, Info, FAcc) ->
                               maps:put({To, Cur}, Info, FAcc)
                       end, Addresses, maps:remove(To, NewAddrBal)),
        try_process(Rest, SetState, NewAddresses, GetFun,
                    Acc#{success=>[{TxID, Tx}|Success]})
    catch throw:X ->
              try_process(Rest, SetState, Addresses, GetFun,
                          Acc#{failed=>[{TxID, X}|Failed]})
    end;

try_process([{TxID,
              #{seq:=_Seq, timestamp:=_Timestamp, from:=From, portout:=PortTo}=Tx}
             |Rest],
            SetState, Addresses, GetFun,
            #{success:=Success, failed:=Failed}=Acc) ->
  lager:notice("Ensure verified"),
    try
    throw('fixme'),
        Bals=maps:get(From, Addresses),
        A1=maps:remove(keep, Bals),
        Empty=maps:size(A1)==0,
        OffChain=maps:is_key(chain, A1),
        if Empty -> throw('badaddress');
           OffChain -> throw('offchain');
           true -> ok
        end,
        ValidChains=blockchain:get_settings([chains]),
        case lists:member(PortTo, ValidChains) of
            true ->
                ok;
            false ->
                throw ('bad_chain')
        end,
        NewAddresses=maps:put(From, #{chain=>PortTo}, Addresses),
        lager:info("Portout ok"),
        try_process(Rest, SetState, NewAddresses, GetFun,
                    Acc#{success=>[{TxID, Tx}|Success]})
    catch throw:X ->
              lager:info("Portout fail ~p", [X]),
              try_process(Rest, SetState, Addresses, GetFun,
                          Acc#{failed=>[{TxID, X}|Failed]})
    end;

try_process([{TxID, #{
                ver:=2,
                kind:=deploy,
                from:=Owner,
                txext:=#{"code":=Code,"vm":=VMType0}
               }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success}=Acc) ->
  try
    Verify=try
             %TODO: If it contract issued tx check for minsig
             #{sigverify:=#{valid:=SigValid}}=Tx,
             SigValid>0
           catch _:_ ->
                   false
           end,
    if Verify -> ok;
       true ->
         %error_logger:error_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    VMType=to_bin(VMType0),
    VM=try
         VMName= <<"contract_", VMType/binary>>,
         lager:info("VM ~s",[VMName]),
         erlang:binary_to_existing_atom(VMName, utf8)
       catch error:badarg ->
               throw('unknown_vm')
       end,

    lager:info("Deploy contract ~s for ~s",
               [VM, naddress:encode(Owner)]),
    State0=maps:get(state, Tx, <<>>),
    Bal=maps:get(Owner, Addresses),
    NewF1=bal:put(vm, VMType, Bal),
    NewF2=bal:put(code, Code, NewF1),
    A4=erlang:function_exported(VM,deploy,4),
    A6=erlang:function_exported(VM,deploy,6),
    State1=try
             if A4 ->
                  case erlang:apply(VM, deploy, [Tx, Bal, 1, GetFun]) of
                    {ok, #{null:="exec",
                           "state":=St2,
                           "gas":=_GasLeft
                          }} ->
                      St2;
                    {error, Error} ->
                      throw({'deploy_failed', Error});
                    _ ->
                      throw({'deploy_failed', other})
                  end;
                A6 ->
                  case erlang:apply(VM, deploy, [Owner, Bal, Code, State0, 1, GetFun]) of
                    {ok, NewS} ->
                      NewS;
                    {error, Error} ->
                      throw({'deploy_failed', Error});
                    _ ->
                      throw({'deploy_failed', other})
                  end
             end
           catch Ec:Ee ->
                   S=erlang:get_stacktrace(),
                   lager:error("Can't deploy ~p:~p",
                               [Ec, Ee]),
                   lists:foreach(fun(SE) ->
                                     lager:error("@ ~p", [SE])
                                 end, S),
                   throw({'deploy_error', [Ec, Ee]})
           end,
    NewF3=maps:remove(keep,
                      bal:put(state, State1, NewF2)
                     ),
    lager:info("deploy for ~p ledger1 ~p ledger2 ~p",
               [Owner,
                Bal,
                NewF3
               ]),

    NewAddresses=maps:put(Owner, NewF3, Addresses),

    try_process(Rest, SetState, NewAddresses, GetFun,
                Acc#{success=> [{TxID, Tx}|Success]})
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        throw:X ->
          lager:info("Contract deploy failed ~p", [X]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]})
  end;

try_process([{TxID, #{deploy:=VMType, code:=Code, from:=Owner}=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success}=Acc) ->
  lager:notice("Old deploy. Ensure verified"),
    try
    VM=try
         erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8)
       catch error:badarg ->
           throw('unknown_vm')
       end,

        lager:info("Deploy contract ~s for ~s",
                   [VM, naddress:encode(Owner)]),
    State0=maps:get(state, Tx, <<>>),
    Bal=maps:get(Owner, Addresses),
        NewF1=bal:put(vm, VMType, Bal),
        NewF2=bal:put(code, Code, NewF1),
    State1=try
           case erlang:apply(VM, deploy, [Owner, Bal, Code, State0, 1, GetFun]) of
             {ok, NewS} ->
               NewS;
             {error, Error} ->
               throw({'deploy_failed', Error});
             _ ->
               throw({'deploy_failed', other})
           end
         catch Ec:Ee ->
             S=erlang:get_stacktrace(),
             lager:error("Can't deploy ~p:~p @ ~p",
                   [Ec, Ee, hd(S)]),
             throw({'deploy_error', [Ec, Ee]})
         end,
    NewF3=maps:remove(keep,
              bal:put(state, State1, NewF2)
           ),
    lager:info("deploy for ~p ledger1 ~p ledger2 ~p",
           [Owner,
          Bal,
          NewF3
           ]),

        NewAddresses=maps:put(Owner, NewF3, Addresses),

        try_process(Rest, SetState, NewAddresses, GetFun,
                    Acc#{success=> [{TxID, Tx}|Success]})
    catch throw:X ->
              lager:info("Contract deploy failed ~p", [X]),
              try_process(Rest, SetState, Addresses, GetFun,
                          Acc#{failed=>[{TxID, X}|Failed]})
    end;

try_process([{TxID, #{ver:=2,
                      kind:=register,
                      keysh:=_,
                      sig:=_Signatures,
                      sigverify:=#{
                        valid:=_ValidSig,
                        pow_diff:=PD,
                        pubkeys:=[PubKey|_]
                       }
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success,
              settings:=Settings }=Acc) ->
  lager:notice("Ensure verified"),
  try
    %TODO: multisig fix here
    RegSettings=settings:get([<<"current">>, <<"register">>], SetState),
    Diff=maps:get(<<"diff">>,RegSettings,0),
    Inv=maps:get(<<"invite">>,RegSettings,0),
    lager:info("Expected diff ~p ~p",[Diff,Inv]),
    lager:info("tx ~p",[Tx]),

    if Inv==1 ->
         Invite=maps:get(inv,Tx,<<>>),
         Invites=maps:get(<<"invites">>,RegSettings,[]),
         HI=crypto:hash(md5,Invite),
         InvFound=lists:member(HI,Invites),
         lager:info("Inv ~p ~p",[Invite,InvFound]),
         if InvFound ->
              ok;
            true ->
              throw(bad_invite_code)
         end;
       true ->
         Tx
    end,

    if Diff=/=0 ->
         if PD<Diff ->
              throw({required_difficult,Diff});
            true -> ok
         end;
       true -> ok
    end,

    {CG, CB, CA}=case settings:get([<<"current">>, <<"allocblock">>], SetState) of
                   #{<<"block">> := CurBlk,
                     <<"group">> := CurGrp,
                     <<"last">> := CurAddr} ->
                     {CurGrp, CurBlk, CurAddr+1};
                   _ ->
                     throw(unallocable)
                 end,

    NewBAddr=naddress:construct_public(CG, CB, CA),

    IncAddr=#{<<"t">> => <<"set">>,
              <<"p">> => [<<"current">>, <<"allocblock">>, <<"last">>],
              <<"v">> => CA},
    AAlloc={<<"aalloc">>, #{sig=>[], patch=>[IncAddr]}},
    SS1=settings:patch(AAlloc, SetState),
    lager:info("Alloc address ~p ~s for key ~s",
               [NewBAddr,
                naddress:encode(NewBAddr),
                bin2hex:dbin2hex(PubKey)
               ]),

    NewF=bal:put(pubkey, PubKey, bal:new()),
    NewAddresses=maps:put(NewBAddr, NewF, Addresses),
    NewTx=maps:remove(inv,tx:set_ext(<<"addr">>,NewBAddr,Tx)),
    try_process(Rest, SS1, NewAddresses, GetFun,
                Acc#{success=> [{TxID, NewTx}|Success],
                     settings=>[AAlloc|lists:keydelete(<<"aalloc">>, 1, Settings)]
                    })
  catch throw:X ->
          lager:info("Address alloc fail ~p", [X]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]})
  end;

try_process([{TxID, #{register:=PubKey,pow:=Pow}=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success,
              settings:=Settings }=Acc) ->
  lager:notice("Ensure verified"),
  try
    RegSettings=settings:get([<<"current">>, <<"register">>], SetState),
    Diff=maps:get(<<"diff">>,RegSettings,0),
    Inv=maps:get(<<"invite">>,RegSettings,0),
    lager:info("Expected diff ~p ~p",[Diff,Inv]),
    lager:info("tx ~p",[Tx]),

    Tx1=if Inv==1 ->
         [Invite|_]=binary:split(Pow,<<" ">>,[global]),
         Invites=maps:get(<<"invites">>,RegSettings,[]),
         HI=crypto:hash(md5,Invite),
         InvFound=lists:member(HI,Invites),
         lager:info("Inv ~p ~p",[Invite,InvFound]),
         if InvFound ->
              Tx#{invite=>HI};
            true ->
              throw(bad_invite_code)
         end;
       true ->
             Tx
    end,

    if Diff=/=0 ->
         <<PowHash:Diff/big,_/binary>>=crypto:hash(sha512,Pow),
         if PowHash>0 ->
              throw({required_difficult,Diff});
            true -> ok
         end;
       true -> ok
    end,

    {CG, CB, CA}=case settings:get([<<"current">>, <<"allocblock">>], SetState) of
                   #{<<"block">> := CurBlk,
                     <<"group">> := CurGrp,
                     <<"last">> := CurAddr} ->
                     {CurGrp, CurBlk, CurAddr+1};
                   _ ->
                     throw(unallocable)
                 end,

    NewBAddr=naddress:construct_public(CG, CB, CA),

    IncAddr=#{<<"t">> => <<"set">>,
              <<"p">> => [<<"current">>, <<"allocblock">>, <<"last">>],
              <<"v">> => CA},
    AAlloc={<<"aalloc">>, #{sig=>[], patch=>[IncAddr]}},
    SS1=settings:patch(AAlloc, SetState),
    lager:info("Alloc address ~p ~s for key ~s",
               [NewBAddr,
                naddress:encode(NewBAddr),
                bin2hex:dbin2hex(PubKey)
               ]),

    NewF=bal:put(pubkey, PubKey, bal:new()),
    NewAddresses=maps:put(NewBAddr, NewF, Addresses),
    FixTx=case maps:get(<<"cleanpow">>, RegSettings, 0) of
            1 ->
              Tx1#{pow=>crypto:hash(sha512,Pow),address=>NewBAddr};
            _ ->
              Tx1#{address=>NewBAddr}
          end,
    try_process(Rest, SS1, NewAddresses, GetFun,
                Acc#{success=> [{TxID, FixTx}|Success],
                     settings=>[AAlloc|lists:keydelete(<<"aalloc">>, 1, Settings)]
                    })
  catch throw:X ->
          lager:info("Address alloc fail ~p", [X]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]})
  end;

try_process([{TxID, #{from:=From, to:=To}=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed}=Acc) ->
    MyChain=GetFun(mychain),
    FAddr=addrcheck(From),
    TAddr=addrcheck(To),
    case {FAddr, TAddr} of
        {{true, {chain, MyChain}}, {true, {chain, MyChain}}} ->
            try_process_local([{TxID, Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true, {chain, MyChain}}, {true, {chain, OtherChain}}} ->
            try_process_outbound([{TxID, Tx#{
                                          outbound=>OtherChain
                                         }}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true, {chain, _OtherChain}}, {true, {chain, MyChain}}} ->
            try_process_inbound([{TxID,
                                  maps:remove(outbound,
                                              Tx
                                             )}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true, private}, {true, {chain, MyChain}}}  -> %local from pvt
            try_process_local([{TxID, Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true, {chain, MyChain}}, {true, private}}  -> %local to pvt
            try_process_local([{TxID, Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        _ ->
            lager:info("TX ~s addr error ~p -> ~p", [TxID, FAddr, TAddr]),
            try_process(Rest, SetState, Addresses, GetFun,
                        Acc#{failed=>[{TxID, 'bad_src_or_dst_addr'}|Failed]})
    end;

try_process([{TxID, UnknownTx} |Rest],
      SetState, Addresses, GetFun,
      #{failed:=Failed}=Acc) ->
  lager:info("Unknown TX ~p type ~p", [TxID, UnknownTx]),
  try_process(Rest, SetState, Addresses, GetFun,
        Acc#{failed=>[{TxID, 'unknown_type'}|Failed]}).

try_process_inbound([{TxID,
                      #{ver:=2,
                        kind:=generic,
                        to:=To,
                        origin_block:=OriginBlock,
                        origin_block_height:=OriginHeight,
                        origin_block_hash:=OriginHash,
                        origin_chain:=ChID
                       }=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success,
                    failed:=Failed,
                    emit:=Emit,
                    pick_block:=PickBlock}=Acc) ->
    lager:error("Check signature once again"),
    try
      EnsureSettings=fun(undefined) -> GetFun(settings);
                        (SettingsReady) -> SettingsReady
                     end,
      RealSettings=EnsureSettings(SetState),

      lager:info("Orig Block ~p", [OriginBlock]),
      lager:notice("Change chain number to actual ~p", [SetState]),
        {NewT, NewEmit, _GasLeft}=deposit(To, maps:get(To, Addresses), Tx, GetFun, RealSettings),
        NewAddresses=maps:put(To, NewT, Addresses),
        TxExt=maps:get(extdata,Tx,#{}),
        NewExt=TxExt#{
          <<"orig_bhei">>=>OriginHeight,
          <<"orig_bhash">>=>OriginHash,
          <<"orig_chain">>=>ChID
         },
        FixTX=maps:without(
                [origin_block,origin_block_height, origin_block_hash, origin_chain],
                Tx#{extdata=>NewExt}
               ),
        try_process(Rest, SetState, NewAddresses, GetFun,
                    Acc#{success=>[{TxID, FixTX}|Success],
                         emit=>Emit ++ NewEmit,
                         pick_block=>maps:put(OriginBlock, 1, PickBlock)
                        })
    catch throw:X ->
              try_process(Rest, SetState, Addresses, GetFun,
                          Acc#{failed=>[{TxID, X}|Failed]})
    end;

try_process_inbound([{TxID,
                    #{cur:=Cur, amount:=Amount, to:=To,
                      origin_block:=OriginBlock,
                      origin_block_height:=OriginHeight,
                      origin_block_hash:=OriginHash,
                      origin_chain:=ChID
                     }=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success,
                    failed:=Failed,
                    pick_block:=PickBlock}=Acc) ->
    lager:notice("Check signature once again"),
    TBal=maps:get(To, Addresses),
    try
        lager:debug("Orig Block ~p", [OriginBlock]),
        if Amount >= 0 -> ok;
           true -> throw ('bad_amount')
        end,
        NewTAmount=bal:get_cur(Cur, TBal) + Amount,
        NewT=maps:remove(keep,
                         bal:put_cur(
                           Cur,
                           NewTAmount,
                           TBal)
                        ),
        NewAddresses=maps:put(To, NewT, Addresses),
        TxExt=maps:get(extdata,Tx,#{}),
        NewExt=TxExt#{
                 <<"orig_bhei">>=>OriginHeight,
                 <<"orig_bhash">>=>OriginHash,
                 <<"orig_chain">>=>ChID
                },
        FixTX=maps:without(
                [origin_block,origin_block_height, origin_block_hash, origin_chain],
                Tx#{extdata=>NewExt}
               ),
        try_process(Rest, SetState, NewAddresses, GetFun,
                    Acc#{success=>[{TxID, FixTX}|Success],
                         pick_block=>maps:put(OriginBlock, 1, PickBlock)
                        })
    catch throw:X ->
              try_process(Rest, SetState, Addresses, GetFun,
                          Acc#{failed=>[{TxID, X}|Failed]})
    end.

try_process_outbound([{TxID,
             #{outbound:=OutTo, to:=To, from:=From}=Tx}
            |Rest],
           SetState, Addresses, GetFun,
           #{failed:=Failed,
             success:=Success,
             settings:=Settings,
             outbound:=Outbound,
             parent:=ParentHash,
             height:=MyHeight
            }=Acc) ->
  lager:notice("TODO:Check signature once again"),
  lager:info("outbound to chain ~p ~p", [OutTo, To]),
  FBal=maps:get(From, Addresses),
  EnsureSettings=fun(undefined) -> GetFun(settings);
            (SettingsReady) -> SettingsReady
           end,

  try
    RealSettings=EnsureSettings(SetState),
    {NewF, GotFee}=withdraw(FBal, Tx, GetFun, RealSettings),

    PatchTxID= <<"out", (xchain:pack_chid(OutTo))/binary>>,
    {SS2, Set2}=case lists:keymember(PatchTxID, 1, Settings) of
                  true ->
                    {SetState, Settings};
                  false ->
                    ChainPath=[<<"current">>, <<"outward">>,
                               xchain:pack_chid(OutTo)],
                    SyncSet=settings:get(ChainPath, RealSettings),
                    PC1=case SyncSet of
                          #{<<".">>:=#{<<"height">>:=#{<<"ublk">>:=UBLK}}} ->
                            [
                             #{<<"t">> =><<"set">>,
                               <<"p">> => ChainPath ++ [<<"pre_hash">>],
                               <<"v">> => UBLK
                              }
                            ];
                          _ -> []
                        end,
                    PC2=case SyncSet of
                          #{<<"parent">>:=PP} ->
                            [
                             #{<<"t">> =><<"set">>,
                              <<"p">> => ChainPath ++ [<<"pre_parent">>],
                              <<"v">> => PP
                             }
                            ];
                          _ ->
                            []
                        end,
                    PC3=case SyncSet of
                          #{<<"height">>:=HH} ->
                            [
                             #{<<"t">> =><<"set">>,
                               <<"p">> => ChainPath ++ [<<"pre_height">>],
                               <<"v">> => HH
                              }
                            ];
                          _ ->
                            []
                        end,
                    PCP=if PC1==[] andalso PC2==[] andalso PC3==[] ->
                             [
                              #{<<"t">> =><<"set">>,
                                <<"p">> => ChainPath ++ [<<"pre_hash">>],
                                <<"v">> => <<0,0,0,0,0,0,0,0>>
                               },
                              #{<<"t">> =><<"set">>,
                                <<"p">> => ChainPath ++ [<<"pre_height">>],
                                <<"v">> => 0
                               }
                             ];
                           true ->
                             PC1++PC2++PC3
                        end,
                    IncPtr=[
                            #{<<"t">> => <<"set">>,
                              <<"p">> => ChainPath ++ [<<"parent">>],
                              <<"v">> => ParentHash
                             },
                            #{<<"t">> => <<"set">>,
                              <<"p">> => ChainPath ++ [<<"height">>],
                              <<"v">> => MyHeight
                             }
                            |PCP ],
                    SyncPatch={PatchTxID, #{sig=>[], patch=>IncPtr}},
                    {
                     settings:patch(SyncPatch, RealSettings),
                     [SyncPatch|Settings]
                    }
                end,
    NewAddresses=maps:put(From, NewF, Addresses),
    try_process(Rest, SS2, NewAddresses, GetFun,
          savefee(GotFee,
              Acc#{
                settings=>Set2,
                success=>[{TxID, Tx}|Success],
                outbound=>[{TxID, OutTo}|Outbound]
               })
           )
  catch throw:X ->
        try_process(Rest, SetState, Addresses, GetFun,
              Acc#{failed=>[{TxID, X}|Failed]})
  end.

try_process_local([{TxID,
                    #{to:=To, from:=From}=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
          #{success:=Success,
          failed:=Failed,
          emit:=Emit}=Acc) ->
  try
    Verify=try
             %TODO: If it contract issued tx check for minsig
             #{sigverify:=#{valid:=SigValid}}=Tx,
             SigValid>0
           catch _:_ ->
                   false
           end,
    if Verify -> ok;
       true ->
         %error_logger:error_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    EnsureSettings=fun(undefined) -> GetFun(settings);
                      (SettingsReady) -> SettingsReady
                   end,

    RealSettings=EnsureSettings(SetState),
    {NewF, GotFee}=withdraw(maps:get(From, Addresses), Tx, GetFun, RealSettings),
    Addresses1=maps:put(From, NewF, Addresses),
    {NewT, NewEmit, _GasLeft}=deposit(To, maps:get(To, Addresses1), Tx, GetFun, RealSettings),
    NewAddresses=maps:put(To, NewT, Addresses1),

    CI=tx:get_ext(<<"contract_issued">>, Tx),
    Tx1=if CI=={ok, From} ->
             #{extdata:=ED}=Tx,
             Tx#{
               extdata=> maps:with([<<"contract_issued">>], ED),
               sig => #{}
              };
           true ->
             Tx
        end,

    try_process(Rest, SetState, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{
                          success=>[{TxID, Tx1}|Success],
                          emit=>Emit ++ NewEmit
                         }
                       )
               )
  catch error:{badkey,From} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        error:{badkey,To} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_dst_addr_loaded}|Failed]});
        throw:X ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]})
  end.

-spec savefee(GotFee :: {binary(),non_neg_integer(),non_neg_integer()},
              mkblock_acc()) -> mkblock_acc().

savefee({Cur, Fee, Tip}, #{fee:=FeeBal, tip:=TipBal}=Acc) ->
  Acc#{
    fee=>bal:put_cur(Cur, Fee+bal:get_cur(Cur, FeeBal), FeeBal),
    tip=>bal:put_cur(Cur, Tip+bal:get_cur(Cur, TipBal), TipBal)
   }.

deposit(Address, TBal0,
        #{ver:=2}=Tx,
        GetFun, _Settings) ->
  NewT=maps:remove(keep,
                   lists:foldl(
                     fun(#{amount:=Amount, cur:= Cur}, TBal) ->
                         NewTAmount=bal:get_cur(Cur, TBal) + Amount,
                         bal:put_cur( Cur, NewTAmount, TBal)
                     end, TBal0, tx:get_payloads(Tx,transfer))),
  case bal:get(vm, NewT) of
    undefined ->
      {NewT, [], 0};
    VMType ->
      lager:info("Smartcontract ~p", [VMType]),
      {L1, TXs, Gas}=smartcontract:run(VMType, Tx, NewT, 1, GetFun),
      {L1, lists:map(
             fun(#{seq:=Seq}=ETx) ->
                 H=base64:encode(crypto:hash(sha, bal:get(state, TBal0))),
                 BSeq=bin2hex:dbin2hex(<<Seq:64/big>>),
                 EA=(naddress:encode(Address)),
                 TxID= <<EA/binary, BSeq/binary, H/binary>>,
                 {TxID,
                  tx:set_ext( <<"contract_issued">>, Address, ETx)
                 }
             end, TXs), Gas}
  end;

deposit(Address, TBal,
    #{cur:=Cur, amount:=Amount}=Tx,
    GetFun, _Settings) ->
  NewTAmount=bal:get_cur(Cur, TBal) + Amount,
  NewT=maps:remove(keep,
           bal:put_cur( Cur, NewTAmount, TBal)
          ),
  case bal:get(vm, NewT) of
    undefined ->
      {NewT, [], 0};
    VMType ->
      lager:info("Smartcontract ~p", [VMType]),
      {L1, TXs, Gas}=smartcontract:run(VMType, Tx, NewT, 1, GetFun),
      {L1, lists:map(
          fun(#{seq:=Seq}=ETx) ->
              H=base64:encode(crypto:hash(sha, bal:get(state, TBal))),
              BSeq=bin2hex:dbin2hex(<<Seq:64/big>>),
              EA=(naddress:encode(Address)),
              TxID= <<EA/binary, BSeq/binary, H/binary>>,
              {TxID,
               tx:set_ext( <<"contract_issued">>, Address, ETx)
              }
          end, TXs), Gas}
  end.


withdraw(FBal0,
         #{ver:=2, seq:=Seq, t:=Timestamp, from:=From}=Tx,
         GetFun, Settings) ->
  try
    Contract_Issued=tx:get_ext(<<"contract_issued">>, Tx),
    IsContract=is_binary(bal:get(vm, FBal0)) andalso Contract_Issued=={ok, From},

    lager:info("Withdraw ~p ~p", [IsContract, Tx]),
    if Timestamp==0 andalso IsContract ->
         ok;
       is_integer(Timestamp) ->
         case GetFun({valid_timestamp, Timestamp}) of
           true ->
             ok;
           false ->
             throw ('invalid_timestamp')
         end;
       true -> throw ('non_int_timestamp')
    end,
    LD=bal:get(t, FBal0) div 86400000,
    CD=Timestamp div 86400000,
    NoSK=if IsContract -> true;
            true ->
              case settings:get([<<"current">>, <<"nosk">>], Settings) of
                1 -> true;
                _ -> false
              end
         end,
    if NoSK -> ok;
       true ->
         FSK=bal:get_cur(<<"SK">>, FBal0),
         FSKUsed=if CD>LD ->
                      0;
                    true ->
                      bal:get(usk, FBal0)
                 end,
         if FSK < 1 ->
              case GetFun({endless, From, <<"SK">>}) of
                true -> ok;
                false -> throw('no_sk')
              end;
            FSKUsed >= FSK -> throw('sk_limit');
            true -> ok
         end
    end,
    CurFSeq=bal:get(seq, FBal0),
    if CurFSeq < Seq -> ok;
       true ->
         %==== DEBUG CODE
         L=try
             ledger:get(From)
           catch _:_ ->
                   cant_get_ledger
           end,
         lager:error("Bad seq addr ~p, cur ~p tx ~p, ledger ~p",
                     [From, CurFSeq, Seq, L]),
         %==== END DEBU CODE
         throw ('bad_seq')
    end,
    CurFTime=bal:get(t, FBal0),
    if CurFTime < Timestamp -> ok;
       IsContract andalso Timestamp==0 -> ok;
       true -> throw ('bad_timestamp')
    end,

    FBal1=lists:foldl(
            fun(#{amount:=Amount, cur:= Cur}, FBal) ->
                if Amount >= 0 ->
                     ok;
                   true ->
                     throw ('bad_amount')
                end, 
                CurFAmount=bal:get_cur(Cur, FBal),
                NewFAmount=if CurFAmount >= Amount ->
                                CurFAmount - Amount;
                              true ->
                                case GetFun({endless, From, Cur}) of
                                  true ->
                                    CurFAmount - Amount;
                                  false ->
                                    throw ('insufficient_fund')
                                end
                           end,
                bal:mput(
                  Cur,
                  NewFAmount,
                  Seq,
                  Timestamp,
                  FBal,
                  if IsContract ->
                       false;
                     true ->
                       if CD>LD -> reset;
                          true -> true
                       end
                  end
                 )
            end,
            FBal0,
            tx:get_payloads(Tx,transfer)
           ),
    NewBal=maps:remove(keep,FBal1),
    GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
                  settings:get([<<"current">>, <<"fee">>, FeeCur], Settings);
                  ({params, Parameter}) ->
                  settings:get([<<"current">>, <<"fee">>, params, Parameter], Settings)
              end,
    {FeeOK, #{cost:=MinCost}=Fee}=if IsContract ->
                                       {true, #{cost=>0, tip=>0, cur=><<"NONE">>}};
                                     true ->
                                       Rate=tx:rate(Tx, GetFeeFun),
                                       lager:info("Rate ~p", [Rate]),
                                       Rate
                                       %{true, #{cost=>0, tip=>0, cur=><<>>}}
                                  end,
    if FeeOK -> ok;
       true -> throw ({'insufficient_fee', MinCost})
    end,
    #{cost:=FeeCost, tip:=Tip0, cur:=FeeCur}=Fee,
    if FeeCost == 0 ->
         {NewBal, {<<"NONE">>, 0, 0}};
       true ->
         Tip=case GetFeeFun({params, <<"notip">>}) of
               1 -> 0;
               _ -> Tip0
             end,
         FeeAmount=FeeCost+Tip,
         CurFFeeAmount=bal:get_cur(FeeCur, NewBal),
         NewFFeeAmount=if CurFFeeAmount >= FeeAmount ->
                            CurFFeeAmount - FeeAmount;
                          true ->
                            case GetFun({endless, From, FeeCur}) of
                              true ->
                                CurFFeeAmount - FeeAmount;
                              false ->
                                throw ('insufficient_fund_for_fee')
                            end
                       end,
         NewBal2=bal:put_cur(FeeCur,
                             NewFFeeAmount,
                             NewBal
                            ),
         {NewBal2, {FeeCur, FeeCost, Tip}}
    end
  catch error:Ee ->
          S=erlang:get_stacktrace(),
          lager:error("Withdrawal error ~p tx ~p",[Ee,Tx]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),

          throw('unknown_withdrawal_error')
  end;

withdraw(FBal,
     #{cur:=Cur, seq:=Seq, timestamp:=Timestamp, amount:=Amount, from:=From}=Tx,
     GetFun, Settings) ->
  if Amount >= 0 ->
       ok;
     true ->
       throw ('bad_amount')
  end,
  Contract_Issued=tx:get_ext(<<"contract_issued">>, Tx),
  IsContract=is_binary(bal:get(vm, FBal)) andalso Contract_Issued=={ok, From},

  lager:info("Withdraw ~p ~p", [IsContract, Tx]),
  if Timestamp==0 andalso IsContract ->
       ok;
     is_integer(Timestamp) ->
       case GetFun({valid_timestamp, Timestamp}) of
         true ->
           ok;
         false ->
           throw ('invalid_timestamp')
       end;
     true -> throw ('non_int_timestamp')
  end,
  LD=bal:get(t, FBal) div 86400000,
  CD=Timestamp div 86400000,
  NoSK=if IsContract -> true;
          true ->
            case settings:get([<<"current">>, <<"nosk">>], Settings) of
              1 -> true;
              _ -> false
            end
       end,
  if NoSK -> ok;
     true ->
       FSK=bal:get_cur(<<"SK">>, FBal),
       FSKUsed=if CD>LD ->
              0;
            true ->
              bal:get(usk, FBal)
           end,
       if FSK < 1 ->
          case GetFun({endless, From, <<"SK">>}) of
            true -> ok;
            false -> throw('no_sk')
          end;
        FSKUsed >= FSK -> throw('sk_limit');
        true -> ok
       end
  end,
  CurFSeq=bal:get(seq, FBal),
  if CurFSeq < Seq -> ok;
     true ->
       %==== DEBUG CODE
       L=try
           ledger:get(From)
         catch _:_ ->
                 cant_get_ledger
         end,
       lager:error("Bad seq addr ~p, cur ~p tx ~p, ledger ~p",
                   [From, CurFSeq, Seq, L]),
       %==== END DEBU CODE
       throw ('bad_seq')
  end,
  CurFTime=bal:get(t, FBal),
  if CurFTime < Timestamp -> ok;
     IsContract andalso Timestamp==0 -> ok;
     true -> throw ('bad_timestamp')
  end,
  CurFAmount=bal:get_cur(Cur, FBal),
  NewFAmount=if CurFAmount >= Amount ->
            CurFAmount - Amount;
          true ->
            case GetFun({endless, From, Cur}) of
              true ->
                CurFAmount - Amount;
              false ->
                throw ('insufficient_fund')
            end
         end,
  NewBal=maps:remove(keep,
        bal:mput(
          Cur,
          NewFAmount,
          Seq,
          Timestamp,
          FBal,
          if IsContract ->
             false;
           true ->
             if CD>LD -> reset;
              true -> true
             end
          end
         )
         ),
  GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
            settings:get([<<"current">>, <<"fee">>, FeeCur], Settings);
          ({params, Parameter}) ->
            settings:get([<<"current">>, <<"fee">>, params, Parameter], Settings)
        end,
  {FeeOK, #{cost:=MinCost}=Fee}=if IsContract ->
                    {true, #{cost=>0, tip=>0, cur=>Cur}};
                  true ->
                    Rate=tx:rate(Tx, GetFeeFun),
                    lager:info("Rate ~p", [Rate]),
                    Rate
                    %{true, #{cost=>0, tip=>0, cur=><<>>}}
                 end,
  if FeeOK -> ok;
     true -> throw ({'insufficient_fee', MinCost})
  end,
  #{cost:=FeeCost, tip:=Tip0, cur:=FeeCur}=Fee,
  if FeeCost == 0 ->
       {NewBal, {Cur, 0, 0}};
     true ->
       Tip=case GetFeeFun({params, <<"notip">>}) of
           1 -> 0;
           _ -> Tip0
         end,
       FeeAmount=FeeCost+Tip,
       CurFFeeAmount=bal:get_cur(FeeCur, NewBal),
       NewFFeeAmount=if CurFFeeAmount >= FeeAmount ->
               CurFFeeAmount - FeeAmount;
             true ->
               case GetFun({endless, From, FeeCur}) of
                 true ->
                   CurFFeeAmount - FeeAmount;
                 false ->
                   throw ('insufficient_fund_for_fee')
               end
            end,
       NewBal2=bal:put_cur(FeeCur,
                 NewFFeeAmount,
                 NewBal
                ),
       {NewBal2, {FeeCur, FeeCost, Tip}}
  end.

sign(Blk, ED) when is_map(Blk) ->
    PrivKey=nodekey:get_priv(),
    block:sign(Blk, ED, PrivKey).

load_settings(State) ->
    OldSettings=maps:get(settings, State, #{}),
    MyChain=blockchain:chain(),
    AE=blockchain:get_mysettings(allowempty),
    State#{
      settings=>maps:merge(
                  OldSettings,
                  #{ae=>AE, mychain=>MyChain}
                 )
     }.

sort_txs(PreTXL) ->
  Order=fun({_ID,#{hash:=Hash,header:=#{height:=H}}}) ->
            %sort inbound blocks by height
            {H,Hash};
           ({ID,_}) ->
            {0,ID}
        end,
  SortFun=fun(A,B) ->
              OA=Order(A),
              OB=Order(B),
              OA=<OB
          end,
  lists:sort(SortFun,lists:usort(PreTXL)).

generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData) ->
  %file:write_file("tmp/tx.txt", io_lib:format("~p.~n", [PreTXL])),
  _T1=erlang:system_time(),
  _T2=erlang:system_time(),
  TXL=sort_txs(PreTXL),
  XSettings=GetSettings(settings),
  Addrs0=lists:foldl(
           fun(default, Acc) ->
        BinAddr=naddress:construct_private(0, 0),
        maps:put(BinAddr,
             bal:fetch(BinAddr, <<"ANY">>, true, bal:new(), GetAddr),
             Acc);
     (Type, Acc) ->
        case settings:get([<<"current">>, <<"fee">>, params, Type], XSettings) of
          BinAddr when is_binary(BinAddr) ->
            maps:put(BinAddr,
                 bal:fetch(BinAddr, <<"ANY">>, true, bal:new(), GetAddr),
                 Acc);
          _ ->
            Acc
        end
    end, #{}, [<<"feeaddr">>, <<"tipaddr">>, default]),

  Load=fun({_, #{hash:=_, header:=#{}, txs:=Txs}}, {AAcc0, SAcc}) ->
         lager:debug("TXs ~p", [Txs]),
         {
          lists:foldl(
          fun({_, #{to:=T, cur:=Cur}}, AAcc) ->
              TB=bal:fetch(T, Cur, false, maps:get(T, AAcc, #{}), GetAddr),
              maps:put(T, TB, AAcc);
             ({_, #{ver:=2, kind:=generic, to:=T, payload:=P}}, AAcc) ->
              lists:foldl(
                fun(#{cur:=Cur}, AAcc1) ->
                    TB=bal:fetch(T, Cur, false, maps:get(T, AAcc1, #{}), GetAddr),
                    maps:put(T, TB, AAcc1)
                end, AAcc, P)
          end, AAcc0, Txs),
          SAcc};
      ({_, #{patch:=_}}, {AAcc, SAcc}) ->
         {AAcc, SAcc};
      ({_, #{register:=_}}, {AAcc, SAcc}) ->
         {AAcc, SAcc};
      ({_, #{from:=F, portin:=_ToChain}}, {AAcc, SAcc}) ->
         A1=case maps:get(F, AAcc, undefined) of
            undefined ->
              AddrInfo1=GetAddr(F),
              maps:put(F, AddrInfo1#{keep=>false}, AAcc);
            _ ->
              AAcc
          end,
         {A1, SAcc};
      ({_, #{from:=F, portout:=_ToChain}}, {AAcc, SAcc}) ->
         A1=case maps:get(F, AAcc, undefined) of
            undefined ->
              AddrInfo1=GetAddr(F),
              lager:info("Add address for portout ~p", [AddrInfo1]),
              maps:put(F, AddrInfo1#{keep=>false}, AAcc);
            _ ->
              AAcc
          end,
         {A1, SAcc};
      ({_, #{from:=F, deploy:=_}}, {AAcc, SAcc}) ->
         A1=case maps:get(F, AAcc, undefined) of
            undefined ->
              AddrInfo1=GetAddr(F),
              maps:put(F, AddrInfo1#{keep=>false}, AAcc);
            _ ->
              AAcc
          end,
         {A1, SAcc};
      ({_, #{ver:=2, to:=T, from:=F, payload:=P}}=_TX, {AAcc1, SAcc}) ->
           AAcc2=lists:foldl(
                   fun(#{cur:=Cur}, AAcc) ->
                       FB=bal:fetch(F, Cur, true, maps:get(F, AAcc, #{}), GetAddr),
                       TB=bal:fetch(T, Cur, false, maps:get(T, AAcc, #{}), GetAddr),
                       maps:put(F, FB, maps:put(T, TB, AAcc))
                   end, AAcc1, P),
           {AAcc2, SAcc};
      ({_, #{ver:=2, kind:=deploy, from:=F, payload:=P}}=_TX, {AAcc1, SAcc}) ->
           AAcc2=lists:foldl(
                   fun(#{cur:=Cur}, AAcc) ->
                       FB=bal:fetch(F, Cur, true, maps:get(F, AAcc, #{}), GetAddr),
                       maps:put(F, FB, AAcc)
                   end, AAcc1, P),
           {AAcc2, SAcc};
      ({_, #{to:=T, from:=F, cur:=Cur}}, {AAcc, SAcc}) ->
         FB=bal:fetch(F, Cur, true, maps:get(F, AAcc, #{}), GetAddr),
         TB=bal:fetch(T, Cur, false, maps:get(T, AAcc, #{}), GetAddr),
         {maps:put(F, FB, maps:put(T, TB, AAcc)), SAcc};
     ({_,_Any}, {AAcc, SAcc}) ->
           lager:info("Can't load ~p",[_Any]),
         {AAcc, SAcc}
     end,
  {Addrs, _}=lists:foldl(Load, {Addrs0, undefined}, TXL),
  lager:debug("MB Pre Setting ~p", [XSettings]),
  _T3=erlang:system_time(),
  #{failed:=Failed,
    table:=NewBal0,
    success:=Success,
    settings:=Settings,
    outbound:=Outbound,
    pick_block:=PickBlocks,
    fee:=_FeeCollected,
    tip:=_TipCollected,
    emit:=EmitTXs0
   }=try_process(TXL, XSettings, Addrs, GetSettings,
           #{export=>[],
           failed=>[],
           success=>[],
           settings=>[],
           outbound=>[],
           table=>#{},
           emit=>[],
           fee=>bal:new(),
           tip=>bal:new(),
           pick_block=>#{},
           parent=>Parent_Hash,
           height=>Parent_Height+1
          }
          ),
  lager:info("MB Collected fee ~p tip ~p", [_FeeCollected, _TipCollected]),
  if length(Settings)>0 ->
       lager:info("MB Post Setting ~p", [Settings]);
     true -> ok
  end,
  OutChains=lists:foldl(
        fun({_TxID, ChainID}, Acc) ->
            maps:put(ChainID, maps:get(ChainID, Acc, 0)+1, Acc)
        end, #{}, Outbound),
  case maps:size(OutChains)>0 of
    true ->
      lager:info("MB Outbound to ~p", [OutChains]);
    false -> ok
  end,
  if length(Settings)>0 ->
       lager:info("MB Must pick blocks ~p", [maps:keys(PickBlocks)]);
     true -> ok
  end,
  _T4=erlang:system_time(),
  NewBal=cleanup_bals(NewBal0),
  ExtraPatch=maps:fold(
         fun(ToChain, _NoOfTxs, AccExtraPatch) ->
             [ToChain|AccExtraPatch]
         end, [], OutChains),
  if length(ExtraPatch)>0 ->
       lager:info("MB Extra out settings ~p", [ExtraPatch]);
     true -> ok
  end,

  %lager:info("MB NewBal ~p", [NewBal]),

  HedgerHash=ledger_hash(NewBal),
  _T5=erlang:system_time(),
  Blk=block:mkblock(#{
      txs=>Success,
      parent=>Parent_Hash,
      mychain=>GetSettings(mychain),
      height=>Parent_Height+1,
      bals=>NewBal,
      ledger_hash=>HedgerHash,
      settings=>Settings,
      tx_proof=>[ TxID || {TxID, _ToChain} <- Outbound ],
      inbound_blocks=>lists:foldl(
              fun(PickID, Acc) ->
                  [{PickID,
                    proplists:get_value(PickID, TXL)
                   }|Acc]
              end, [], maps:keys(PickBlocks)),
      extdata=>ExtraData
     }),


  % TODO: Remove after testing
  % Verify myself
  % Ensure block may be packed/unapcked correctly
  case block:verify(block:unpack(block:pack(Blk))) of
    {true, _} -> ok;
    false ->
      lager:error("Block is not verifiable after repacking!!!!"),
      file:write_file("tmp/blk_repack_error.txt",
              io_lib:format("~p.~n", [Blk])
               ),

      case block:verify(Blk) of
        {true, _} -> ok;
        false ->
          lager:error("Block is not verifiable at all!!!!")
      end

  end,



  EmitTXs=lists:map(
        fun({TxID, ETx}) ->
            C={TxID,
             tx:unpack(
             tx:sign(
                 tx:set_ext( dep_heig,
                       Parent_Height+1,
                       tx:set_ext( dep_hash,
                             maps:get(hash, Blk),
                             ETx)),
                 nodekey:get_priv())
            )},
            lager:info("Emit ~p", [C]),
            C
        end, EmitTXs0),

  _T6=erlang:system_time(),
  lager:info("Created block ~w ~s: txs: ~w, bals: ~w, LH: ~s, chain ~p",
         [
        Parent_Height+1,
        block:blkid(maps:get(hash, Blk)),
        length(Success),
        maps:size(NewBal),
        bin2hex:dbin2hex(HedgerHash),
        GetSettings(mychain)
         ]),
  lager:debug("BENCHMARK txs       ~w~n", [length(TXL)]),
  lager:debug("BENCHMARK sort tx   ~.6f ~n", [(_T2-_T1)/1000000]),
  lager:debug("BENCHMARK pull addr ~.6f ~n", [(_T3-_T2)/1000000]),
  lager:debug("BENCHMARK process   ~.6f ~n", [(_T4-_T3)/1000000]),
  lager:debug("BENCHMARK filter    ~.6f ~n", [(_T5-_T4)/1000000]),
  lager:debug("BENCHMARK mk block  ~.6f ~n", [(_T6-_T5)/1000000]),
  lager:debug("BENCHMARK total ~.6f ~n", [(_T6-_T1)/1000000]),
  #{block=>Blk#{outbound=>Outbound},
    failed=>Failed,
    emit=>EmitTXs
   }.

addrcheck(Addr) ->
    case naddress:check(Addr) of
        {true, #{type:=public}} ->
            case address_db:lookup(Addr) of
                {ok, Chain} ->
                    {true, {chain, Chain}};
                _ ->
                    unroutable
            end;
        {true, #{type:=private}} ->
            {true, private};
        _ ->
            bad_address
    end.

decode_tpic_txs(TXs) ->
    lists:map(
      fun({TxID, Tx}) ->
              {TxID, tx:unpack(Tx)}
      end, maps:to_list(TXs)).

cleanup_bals(NewBal0) ->
  maps:fold(
    fun(K, V, BA) ->
        case maps:get(keep, V, true) of
          false ->
            BA;
          true ->
            case maps:is_key(ublk, V) of
              false ->
                maps:put(K, V, BA);
              true ->
                C1=bal:changes(V),
                case (maps:size(C1)>0) of
                  true ->
                    maps:put(K,
                             maps:put(lastblk, maps:get(ublk, V), C1),
                             BA);
                  false ->
                    BA
                end
            end
        end
    end, #{}, NewBal0).

-ifdef(TEST).
ledger_hash(NewBal) ->
    {ok, HedgerHash}=case whereis(ledger) of
                undefined ->
                    %there is no ledger. Is it test?
                    {ok, LedgerS1}=ledger:init([test]),
                    {reply, LCResp, _LedgerS2}=ledger:handle_call({check, []}, self(), LedgerS1),
                    LCResp;
                X when is_pid(X) ->
                    ledger:check(maps:to_list(NewBal))
            end,
    HedgerHash.
-else.
ledger_hash(NewBal) ->
    {ok, HedgerHash}=ledger:check(maps:to_list(NewBal)),
    HedgerHash.
-endif.
to_bin(List) when is_list(List) -> list_to_binary(List);
to_bin(Bin) when is_binary(Bin) -> Bin.


