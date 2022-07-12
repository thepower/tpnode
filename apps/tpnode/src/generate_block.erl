-module(generate_block).

-export([generate_block/5, generate_block/6]).



generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData) ->
  generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData, []).

generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData, Options) ->
  LedgerPid=proplists:get_value(ledger_pid,Options),
  %file:write_file("tmp/tx.txt", io_lib:format("~p.~n", [PreTXL])),
  _T1=erlang:system_time(),
  _T2=erlang:system_time(),
  TXL=sort_txs(PreTXL),
  XSettings=GetSettings(settings),
  Addrs0=lists:foldl(
           fun(default, Acc) ->
               BinAddr=naddress:construct_private(0, 0),
               maps:put(BinAddr,
                        mbal:fetch(BinAddr, <<"ANY">>, true, mbal:new(), GetAddr),
                        Acc);
              (Type, Acc) ->
               case settings:get([<<"current">>, <<"fee">>, params, Type], XSettings) of
                 BinAddr when is_binary(BinAddr) ->
                   maps:put(BinAddr,
                            mbal:fetch(BinAddr, <<"ANY">>, true, mbal:new(), GetAddr),
                            Acc);
                 _ ->
                   Acc
               end
           end, #{}, [<<"feeaddr">>, <<"tipaddr">>, default]),

  Load=fun({_, #{hash:=Hash, header:=#{}, txs:=Txs}}, AAcc0) ->
           lists:foldl(
             fun({TxID, #{to:=T, cur:=_}}, AAcc) ->
                 logger:notice("Deprecated transaction ~p in inbound block ~p",[TxID,Hash]),
                 TB=mbal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
                 maps:put(T, TB, AAcc);
                ({_, #{ver:=2, kind:=generic, to:=T, payload:=_}}, AAcc) ->
                 TB=mbal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
                 maps:put(T, TB, AAcc)
             end, AAcc0, Txs);
          ({_TxID, #{ver:=2, kind:=patches}}=_TX, AAcc) ->
           AAcc;
          ({_TxID, #{ver:=2, to:=T, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=mbal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           TB=mbal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
           maps:put(F, FB, maps:put(T, TB, AAcc));
          ({_TxID, #{ver:=2, kind:=register}}=_TX, AAcc) ->
           AAcc;
          ({_TxID, #{ver:=2, kind:=deploy, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=mbal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_TxID, #{ver:=2, kind:=tstore, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=mbal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_TxID, #{ver:=2, kind:=lstore, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=mbal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_, #{to:=T, from:=F, cur:=Cur}}, AAcc) ->
           FB=mbal:fetch(F, Cur, true, maps:get(F, AAcc, #{}), GetAddr),
           TB=mbal:fetch(T, Cur, false, maps:get(T, AAcc, #{}), GetAddr),
           maps:put(F, FB, maps:put(T, TB, AAcc));
          ({_,_Any}, AAcc) ->
           lager:info("Can't load address for tx ~p",[_Any]),
           AAcc
       end,
  Addrs=lists:foldl(Load, Addrs0, TXL),
  lager:debug("Bals Loaded ~p",[Addrs]),
  lager:debug("MB Pre Setting ~p", [XSettings]),
  _T3=erlang:system_time(),
  Entropy=proplists:get_value(entropy, Options, <<>>),
  MeanTime=proplists:get_value(mean_time, Options, 0),
  Delayed=lists:foldl(
            fun({TxID,#{not_before:=NBT}},Acc) ->
                [{TxID,NBT}|Acc];
               (_,Acc) ->
                Acc
            end, [], TXL),

  AAlloc=case settings:get([<<"current">>, <<"allocblock">>], XSettings) of
                 #{<<"block">> := CurBlk,
                   <<"group">> := CurGrp,
                   <<"last">> := CurAddr} ->
                   {CurGrp, CurBlk, CurAddr};
                 _ ->
                   unallocable
               end,

  GBInit=#{export=>[],
           table => Addrs,
           new_settings=> XSettings,
           get_settings => GetSettings,
           loadaddr=>Load,
           delayed=>Delayed,
           failed=>[],
           success=>[],
           settings=>[],
           outbound=>[],
           emit=>[],
           aalloc=>{0,AAlloc},
           fee=>mbal:new(),
           tip=>mbal:new(),
           pick_block=>#{},
           entropy=>Entropy,
           mean_time=>MeanTime,
           parent=>Parent_Hash,
           height=>Parent_Height+1,
           get_addr=>GetAddr
          },
  #{failed:=Failed,
    table:=NewBal0,
    success:=Success,
    settings:=Settings,
    outbound:=Outbound,
    pick_block:=PickBlocks,
    fee:=_FeeCollected,
    tip:=_TipCollected,
    emit:=EmitTXs0,
    new_settings := NewSettings
   }=finish_processing(generate_block_process:try_process(TXL, GBInit)),
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
  lager:debug("Bals before clean ~p",[NewBal0]),
  NewBal=maps:map(
           fun(_,Bal) ->
               mbal:prepare(Bal)
           end,
           cleanup_bals(NewBal0)
          ),
  lager:debug("Bals after clean and prepare ~p",[NewBal]),
  ExtraPatch=maps:fold(
               fun(ToChain, _NoOfTxs, AccExtraPatch) ->
                   [ToChain|AccExtraPatch]
               end, [], OutChains),
  if length(ExtraPatch)>0 ->
       lager:info("MB Extra out settings ~p", [ExtraPatch]);
     true -> ok
  end,

  %lager:info("MB NewBal ~p", [NewBal]),

  LedgerHash = ledger_hash(NewBal, LedgerPid),
  SettingsHash = settings_hash(NewSettings),
  _T5=erlang:system_time(),
  Roots=[
         {entropy, Entropy},
         {mean_time, <<MeanTime:64/big>>}
        ],
  BlkData=#{
            txs=>Success,
            parent=>Parent_Hash,
            mychain=>GetSettings(mychain),
            height=>Parent_Height+1,
            bals=>NewBal,
            failed=>Failed,
            temporary=>proplists:get_value(temporary,Options),
            retry=>proplists:get_value(retry,Options),
            ledger_hash=>LedgerHash,
            settings_hash=>SettingsHash,
            settings=>Settings,
            extra_roots=>Roots,
            etxs => EmitTXs0,
            tx_proof=>[ TxID || {TxID, _ToChain} <- Outbound ],
            inbound_blocks=>lists:foldl(
                              fun(PickID, Acc) ->
                                  [{PickID,
                                    proplists:get_value(PickID, TXL)
                                   }|Acc]
                              end, [], maps:keys(PickBlocks)),
            extdata=>ExtraData
           },
  Blk=block:mkblock2(BlkData),
  lager:info("BLK ~p",[BlkData]),

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
  lager:info("Created block ~w ~s: txs: ~w, bals: ~w, LH: ~s, chain ~p temp ~p",
             [
              Parent_Height+1,
              block:blkid(maps:get(hash, Blk)),
              length(Success),
              maps:size(NewBal),
              hex:encode(LedgerHash),
              GetSettings(mychain),
              proplists:get_value(temporary,Options)
             ]),
  lager:info("Hdr ~p",[maps:get(header,Blk)]),
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


cleanup_bals(NewBal0) ->
  maps:fold(
    fun(K, V, BA) ->
        lager:debug("Bal cleanup ~p ~p",[K,V]),
        case maps:get(keep, V, true) of
          false ->
            BA;
          true ->
            Item=case maps:is_key(ublk, V) of
                   false ->
                     maps:put(K, V, BA);
                   true ->
                     C1=mbal:changes(V),
                     case (maps:size(C1)>0) of
                       true ->
                         maps:put(K,
                                  maps:put(lastblk,
                                           maps:get(ublk, V),
                                           C1),
                                  BA);
                       false ->
                         BA
                     end
                 end,
            maps:remove(changes,Item)
        end
    end, #{}, NewBal0).

ledger_hash(NewBal, undefined) ->
  {ok, LedgerHash}=mledger:apply_patch(mledger:bals2patch(maps:to_list(NewBal)),check),
  LedgerHash;

ledger_hash(NewBal, _Pid) ->
  ledger_hash(NewBal, undefined).

settings_hash(NewSettings) when is_map(NewSettings) ->
  maphash:hash(NewSettings).

sort_txs(PreTXL) ->
  Order=fun({_ID,#{hash:=Hash,header:=#{height:=H}}}=TX) ->
            {{H,Hash},TX};
           ({ID,_}=TX) ->
            NID=try
                  {ok, _, T} = txpool:decode_txid(ID),
                  T
                catch _:_ ->
                        ID
                end,
            {{0,NID},TX}
        end,
  [ T || {_,T} <-
         lists:keysort(1, lists:map(Order, lists:usort(PreTXL)) )
  ].

save_fee(#{fee:=FeeBal,
           tip:=TipBal,
           emit:=Emit,
           new_settings:=Settings,
           get_settings:=GetFun,
           table:=Addresses}=Acc) ->
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
                                deposit_fee(CBal, Addr, FAcc, TXL, GetFun, Settings,Acc)
                            end,
                            {Addresses, []},
                            [ {tip, TipBal}, {fee, FeeBal} ]
                           ),
    if NewEmit==[] -> ok;
       true ->
         lager:info("NewEmit ~p", [NewEmit])
    end,
    Acc#{
      table=>Addresses2,
      emit=>Emit ++ NewEmit
     }
  catch _Ec:_Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:error("Can't save fees: ~p:~p", [_Ec, _Ee]),
          lists:foreach(fun(E) ->
                            lager:info("Can't save fee at ~p", [E])
                        end, S),
          Acc
  end.

getaddr([], _GetFun, Fallback) ->
  Fallback;

getaddr([E|Rest], GetFun, Fallback) ->
  case GetFun(E) of
    B when is_binary(B) ->
      B;
    _ ->
      getaddr(Rest, GetFun, Fallback)
  end.

replace_set({Key,_}=New,Settings) ->
  [New|lists:keydelete(Key, 1, Settings)].

%this is only for depositing gathered fees
depositf(Address, TBal, #{cur:=Cur, amount:=Amount}=Tx, GetFun, _Settings, GasLimit, Acc) ->
  NewTAmount=mbal:get_cur(Cur, TBal) + Amount,
  NewT=maps:remove(keep,
                   mbal:put_cur( Cur, NewTAmount, TBal)
                  ),
  case mbal:get(vm, NewT) of
    undefined ->
      {NewT, [], GasLimit, Acc};
    VMType ->
      lager:info("Smartcontract ~p", [VMType]),
      {L1, TXs, Gas, _}=smartcontract:run(VMType, Tx, NewT, GasLimit, GetFun, #{}),
      {L1, lists:map(
             fun(#{seq:=Seq}=ETx) ->
                 H=base64:encode(crypto:hash(sha, mbal:get(state, TBal))),
                 BSeq=hex:encode(<<Seq:64/big>>),
                 EA=(naddress:encode(Address)),
                 TxID= <<EA/binary, BSeq/binary, H/binary>>,
                 {TxID,
                  tx:set_ext( <<"contract_issued">>, Address, ETx)
                 }
             end, TXs), Gas, Acc}
  end.


deposit_fee(#{amount:=Amounts}, Addr, Addresses, TXL, GetFun, Settings, GAcc) ->
  TBal=maps:get(Addr, Addresses, mbal:new()),
  {TBal2, TXL2}=maps:fold(
                  fun(Cur, Summ, {Acc, TxAcc}) ->
                      {NewT, NewTXL, _, _}=depositf(Addr, Acc,
                                                #{cur=>Cur,
                                                  amount=>Summ,
                                                  to=>Addr},
                                                GetFun, Settings, free, GAcc),
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

update_aalloc(#{
                aalloc:={Allocated,{_CG,_CB,CA}},
                new_settings:=SetState,
                table:=Addresses,
                settings:=Settings}=Acc) when Allocated>0 ->
  IncAddr=#{<<"t">> => <<"set">>,
            <<"p">> => [<<"current">>, <<"allocblock">>, <<"last">>],
            <<"v">> => CA},
  AAlloc={<<"aalloc">>, #{sig=>[], patch=>[IncAddr]}},
  SS1=settings:patch(AAlloc, SetState),

  Acc#{new_settings=>SS1,
       table=>maps:map(
                fun(_,V) ->
                    mbal:uchanges(V)
                end,
                Addresses
               ),
       settings=>replace_set(AAlloc, Settings)
      };

update_aalloc(Acc) ->
  Acc.


finish_processing(Acc0) ->
  Acc1=save_fee(Acc0),
  Acc2=process_delayed_txs(Acc1),
  Acc3=cleanup_delayed(Acc2),
  update_aalloc(Acc3).

txfind([],_TxID) ->
  false;

txfind([[_H,_P,TxID]=R|_],TxID) ->
  R;

txfind([_|Rest],TxID) ->
  txfind(Rest,TxID).

cleanup_delayed(#{delayed:=DTX, new_settings:=NS, settings:=Sets} = Acc) ->
  lager:info("Delayed ~p",[DTX]),
  ToDel=lists:foldl(
          fun({TxID,DT},Acc1) ->
              case settings:get([<<"current">>, <<"delaytx">>, DT], NS) of
                L when is_list(L) ->
                  case txfind(L,TxID) of
                    false ->
                      Acc1;
                    [_,_,_]=Found ->
                      [#{<<"p">>=>[<<"current">>,<<"delaytx">>,DT],
                         <<"t">>=><<"list_del">>,
                         <<"v">>=>Found}|Acc1]
                  end;
                _ -> Acc1
              end
          end, [], DTX),
  if(ToDel==[]) ->
      Acc;
    true ->
      lager:info("Delayed clean ~p",[ToDel]),
      Cleanup=[#{<<"p">>=>[<<"current">>,<<"delaytx">>],
                 <<"t">>=><<"lists_cleanup">>,
                 <<"v">>=><<"empty_list">>}],
      DelPatch={<<"cleanjob">>, #{sig=>[], patch=>ToDel++Cleanup}},
      lager:info("Patches ~p~n",[ToDel]),
      Acc#{
        settings=>[DelPatch|Sets]
       }
  end.

process_delayed_txs(#{emit:=[]}=Acc) ->
  Acc;

process_delayed_txs(#{emit:=Emit, settings:=Settings, parent:=P,
                      height:=H}=Acc) ->
  lager:info("process_delayed_txs"),
  {NewEmit,ToSet}=lists:foldl(
                    fun({TxID,#{not_before:=DT}=Tx},{AccEm,AccTos}) ->
                        {
                         [{TxID, tx:set_ext(<<"auto">>,0,Tx)}|AccEm],
                         [{TxID,DT}|AccTos]
                        };
                       ({TxID,#{kind:=notify}=Tx},{AccEm,AccTos}) ->
                        {
                         [{TxID, tx:set_ext(<<"auto">>,0,Tx)}|AccEm],
                         AccTos
                        };
                       ({TxID,Tx},{AccEm,AccTos}) ->
                        {
                         [{TxID, tx:set_ext(<<"auto">>,1,Tx)}|AccEm],
                         AccTos
                        }
                    end, {[],[]}, Emit),

  case length(ToSet) of
    0 ->
      Acc#{
        emit=>NewEmit
       };
    _ ->
      Patches=[#{<<"p">> => [<<"current">>,<<"delaytx">>,Timestamp],
                 <<"t">> => <<"list_add">>,<<"v">> => [H,P,TxID]} || {TxID, Timestamp} <- ToSet ],
      SyncPatch={<<"delayjob">>, #{sig=>[], patch=>Patches}},

      lager:info("Emit ~p~n",[NewEmit]),
      lager:info("Patches ~p~n",[Patches]),

      Acc#{
        emit=>NewEmit,
        settings=>[SyncPatch|Settings]
       }
  end.

