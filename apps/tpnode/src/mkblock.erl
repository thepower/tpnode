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
       preptxm=>#{},
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
                     null:=<<"lag">>,
                     <<"lbh">>:=LBH
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  lager:debug("MB Node ~s tells I lagging, his h=~w", [Origin, LBH]),
  {noreply, State};


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
                    }=Msg}, State)  ->
  TXs=decode_tpic_txs(TPICTXs),
  if TXs==[] -> ok;
     true ->
       lager:info("Got txs from ~s: ~p",
            [
             chainsettings:is_our_node(Origin),
             TXs
            ])
  end,
  case maps:find(<<"lastblk">>,Msg) of
    error ->
      handle_cast({prepare, Origin, TXs, undefined}, State);
    {ok, Bin} ->
      PreBlk=block:unpack(Bin),
      MS=chainsettings:get_val(minsig),

      {_, _, HeiHas}=hei_and_has(PreBlk),
      CheckFun=fun(PubKey,_) ->
                   chainsettings:is_our_node(PubKey) =/= false
               end,
      case block:verify(PreBlk, [hdronly, {checksig, CheckFun}]) of
        {true, {Sigs,_}} when length(Sigs) >= MS ->
          % valid block, enough sigs
          lager:info("Got blk from peer ~p",[PreBlk]),
          handle_cast({prepare, Origin, TXs, HeiHas}, State);
        {true, _ } ->
          % valid block, not enough sigs
          {noreply, State};
        false ->
          % invalid block
          {noreply, State}
      end
  end;

handle_cast({prepare, Node, Txs, HeiHash}, #{preptxm:=PreTXM}=State) ->
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
       MarkTx =
         fun({TxID, TxB0}) ->
           % get transaction body from storage
           TxB =
             try
               case TxB0 of
                 {TxID, null} ->
                   case txstorage:get_tx(TxID) of
                     {ok, {TxID, TxBody, _Nodes}} ->
                       {TxID, TxBody}; % got tx body from txstorage
                     _ ->
                       {TxID, null} % error
                   end;
                 _OtherTx ->
                   _OtherTx  % transaction with body or invalid transaction
               end
             catch _Ec0:_Ee0 ->
               utils:print_error("Error", _Ec0, _Ee0, erlang:get_stacktrace()),
               TxB0
             end,

           TxB1 =
             try
               case TxB of
                 #{patch:=_} ->
                   VerFun =
                     fun(PubKey) ->
                       NodeID = chainsettings:is_our_node(PubKey),
                       is_binary(NodeID)
                     end,
                   {ok, Tx1} = settings:verify(TxB, VerFun),
                   tx:set_ext(origin, Origin, Tx1);

                 #{hash:=_,
                   header:=_,
                   sign:=_} ->

                   %do nothing with inbound block
                   TxB;

                 _ ->
                   {ok, Tx1} = tx:verify(TxB, [{maxsize, txpool:get_max_tx_size()}]),
                   tx:set_ext(origin, Origin, Tx1)
               end
             catch
               throw:no_transaction ->
                 null;
               _Ec:_Ee ->
                 utils:print_error("Error", _Ec, _Ee, erlang:get_stacktrace()),
                 file:write_file(
                   "tmp/mkblk_badsig_" ++ binary_to_list(nodekey:node_id()),
                   io_lib:format("~p.~n", [TxB])
                 ),
                 TxB
             end,
           case TxB1 of
             null ->
               false;
             _ ->
               {true, {TxID, TxB1}}
           end
         end,

         Tx2Put=lists:filtermap(MarkTx, Txs),
       {noreply,
        State#{
          preptxm=> maps:put(HeiHash,
                             maps:get(HeiHash,PreTXM, []) ++ Tx2Put,
                            PreTXM)
         }
       }
  end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("MB unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(process,
            #{settings:=#{mychain:=MyChain, nodename:=NodeName}=MySet, preptxm:=PreTXM}=State) ->
  BestHeiHash=case lists:sort(maps:keys(PreTXM)) of
             [undefined] -> undefined;
             [undefined,H0|_] -> H0;
             [H0|_] -> H0;
             [] -> undefined
           end,
  lager:info("pick txs parent block ~p",[BestHeiHash]),
  PreTXL0=maps:get(BestHeiHash, PreTXM, []),
  PreTXL1=lists:foldl(
            fun({TxID, TXB}, Acc) ->
                case maps:is_key(TxID, Acc) of
                  true ->
                    TXB1=tx:mergesig(TXB,
                                     maps:get(TxID, Acc)),
                    {ok, Tx1} = tx:verify(TXB1, [ {maxsize, txpool:get_max_tx_size()} ]),
                    maps:put(TxID, Tx1, Acc);
                  false ->
                    maps:put(TxID, TXB, Acc)
                end
            end, #{}, PreTXL0),
  PreTXL=lists:keysort(1, maps:to_list(PreTXL1)),

  stout:log(mkblock_process, [ {node, nodekey:node_name()} ]),

  AE=maps:get(ae, MySet, 0),
  B=blockchain:last_meta(),
  lager:info("Got blk from our blockchain ~p",[B]),

  {PHeight, PHash, PHeiHash}=hei_and_has(B),
  PTmp=maps:get(temporary,B,false),

  lager:info("-------[MAKE BLOCK h=~w tmp=~p]-------",[PHeight,PTmp]),
  lager:info("Pre ~p",[PreTXL0]),

  PreNodes=try
             PreSig=maps:get(presig, State, #{}),
             BK=maps:fold(
                  fun(_, {BH, _}, Acc) when BH =/= PHash ->
                      Acc;
                     (Node1, {_BH, Nodes2}, Acc) ->
                      [{Node1, Nodes2}|Acc]
                  end, [], PreSig),
             lists:sort(bron_kerbosch:max_clique(BK))
           catch
             Ec:Ee ->
               utils:print_error("Can't calc xsig", Ec, Ee, erlang:get_stacktrace()),
               []
           end,

  try
    if BestHeiHash == undefined -> ok;
       BestHeiHash == PHeiHash -> ok;
       true ->
         gen_server:cast(chainkeeper, are_we_synced),
         throw({'unsync',BestHeiHash,PHeiHash})
    end,
    T1=erlang:system_time(),
    lager:debug("MB pre nodes ~p", [PreNodes]),

    FindBlock=fun FB(H, N) ->
                  case blockchain:rel(H, self) of
                    undefined ->
                      undefined;
                    #{header:=#{parent:=P}}=Blk ->
                      if N==0 ->
                           block:minify(Blk);
                         true ->
                           FB(P, N-1)
                      end
                  end
              end,

    PropsFun=fun(mychain) ->
                 MyChain;
                (settings) ->
                 chainsettings:by_path([]);
                ({valid_timestamp, TS}) ->
                 abs(os:system_time(millisecond)-TS)<3600000;
                ({endless, From, Cur}) ->
                 EndlessPath=[<<"current">>, <<"endless">>, From, Cur],
                 chainsettings:by_path(EndlessPath)==true;
                ({get_block, Back}) when 32>=Back ->
                 FindBlock(last, Back)
             end,
    AddrFun=fun({Addr, _Cur}) ->
                case ledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  not_found -> bal:new()
                end;
               (Addr) ->
                case ledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  not_found -> bal:new()
                end
            end,

    NoTMP=maps:get(notmp, MySet, 0),

    Temporary = if AE==0 andalso PreTXL==[] ->
                     if(NoTMP=/=0) -> throw(empty);
                       true ->
                         if is_integer(PTmp) ->
                              PTmp+1;
                            true ->
                              1
                         end
                     end;
                   true ->
                     false
                end,
    GB=generate_block:generate_block(PreTXL,
                                     {PHeight, PHash},
                                     PropsFun,
                                     AddrFun,
                                     [ {<<"prevnodes">>, PreNodes} ],
                                     [ {temporary, Temporary} ]
                                    ),
    #{block:=Block, failed:=Failed, emit:=EmitTXs}=GB,
    T2=erlang:system_time(),

    case application:get_env(tpnode,mkblock_debug) of
      undefined ->
        ok;
      {ok, true} ->
        stout:log(mkblock_debug,
                  [
                   {node_name,NodeName},
                   {height, PHeight},
                   {phash, PHash},
                   {pretxl, PreTXL},
                   {fail, Failed},
                   {block, Block},
                   {temporary, Temporary}
                  ]);
      Any ->
        lager:notice("What does mkblock_debug=~p means?",[Any])
    end,
    Timestamp=os:system_time(millisecond),
    ED=[
        {timestamp, Timestamp},
        {createduration, T2-T1}
       ],
    SignedBlock=blocksign(Block, ED),
    #{header:=#{height:=NewH}}=Block,
    %cast whole block to my local blockvote
    stout:log(mkblock_done,
              [
               {node_name,NodeName},
               {height, PHeight},
               {block_hdr, maps:with([hash,header,sign,temporary], SignedBlock)}
              ]),

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
    lager:debug("MB My sign ~p emit ~p",
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
         Push=gen_server:call(txpool, {push_etx, EmitTXs}),
         stout:log(push_etx,
                   [
                    {node_name,NodeName},
                    {txs, EmitTXs},
                    {res, Push}
                   ]),
         lager:info("Inject TXs ~p", [Push])
    end,
    {noreply, State#{preptxm=>#{},
                     presig=>#{}
                    }}
    catch throw:empty ->
            lager:info("Skip empty block"),
            {noreply, State#{preptxm=>#{},
                         presig=>#{}}};
          throw:Other ->
            lager:info("Skip ~p",[Other]),
            {noreply, State#{preptxm=>#{},
                             presig=>#{}}}
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

blocksign(Blk, ED) when is_map(Blk) ->
  case nodekey:get_privs() of
    [K0] ->
      block:sign(Blk, ED, K0);
    [K0|Extra] ->
      %Ability to sign mutiple times for smart developers of smarcontracts only!!!!!
      %NEVER USE ON NETWORK CONNECTED NODE!!!
      block:sign(
        lists:foldl(
          fun(ExtraKey,Acc) ->
              ED2=[ {timestamp, proplists:get_value(timestamp, ED)+
                     trunc(-100+rand:uniform()*200)},
                    {createduration, proplists:get_value(createduration, ED)+
                     trunc(-250000000+rand:uniform()*500000000)}
                  ],
              block:sign(Acc, ED2, ExtraKey)
          end, Blk, Extra), ED, K0)
  end.

%blocksign(Blk, ED) when is_map(Blk) ->
%  PrivKey=nodekey:get_priv(),
%  block:sign(Blk, ED, PrivKey).

%% ------------------------------------------------------------------

load_settings(State) ->
    OldSettings=maps:get(settings, State, #{}),
    MyChain=blockchain:chain(),
    AE=chainsettings:get_val(<<"allowempty">>),
    NodeName=nodekey:node_name(),
    State#{
      settings=>
      maps:merge(
        OldSettings,
        #{ae=>AE, mychain=>MyChain, nodename=>NodeName}
      )
    }.

%% ------------------------------------------------------------------

decode_tpic_txs(TXs) ->
  lists:map(
    fun
      % get pre synced transaction body from txstorage
      ({TxID, null}) ->
        TxBody =
          case txstorage:get_tx(TxID) of
            {ok, {TxID, Tx, _Nodes}} ->
              Tx;
            error ->
              lager:error("can't get body for tx ~p", [TxID]),
              null
          end,
        {TxID, TxBody};
      
      % unpack transaction body
      ({TxID, Tx}) ->
        Unpacked = tx:unpack(Tx),
%%      lager:info("debug tx unpack: ~p", [Unpacked]),
        {TxID, Unpacked}
    end,
    maps:to_list(TXs)
  ).

hei_and_has(B) ->
  PTmp=maps:get(temporary,B,false),

  case PTmp of false ->
                 lager:info("Prev block is permanent, make child"),
                 #{header:=#{height:=Last_Height1}, hash:=Last_Hash1}=B,
                 {Last_Height1,
                  Last_Hash1,
                  <<(bnot Last_Height1):64/big,Last_Hash1/binary>>};
               X when is_integer(X) ->
                 lager:info("Prev block is temporary, make replacement"),
                 #{header:=#{height:=Last_Height1, parent:=Last_Hash1}}=B,
                 {Last_Height1-1,
                  Last_Hash1,
                  <<(bnot Last_Height1-1):64/big,Last_Hash1/binary>>}
  end.


