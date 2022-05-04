-module(generate_block).

-export([generate_block/5, generate_block/6]).
-export([return_gas/3, sort_txs/1, txfind/2, aalloc/1]).

-define(MAX(A,B), if A>B -> A; true -> B end).

-type mkblock_acc() :: #{'emit':=[{_,_}],
                         'export':=list(),
                         'failed':=[{_,_}],
                         'fee':=mbal:bal(),
                         'tip':=mbal:bal(),
                         'height':=number(),
                         'outbound':=[{_,_}],
                         'parent':=binary(),
                         'table':=map(),
                         'pick_block':=#{_=>1},
                         'settings':=[{_,_}],
                         'success':=[{_,_}]
                        }.

getaddr([], _GetFun, Fallback) ->
  Fallback;

getaddr([E|Rest], GetFun, Fallback) ->
  case GetFun(E) of
    B when is_binary(B) ->
      B;
    _ ->
      getaddr(Rest, GetFun, Fallback)
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

finish_processing(GetFun, Acc0) ->
  Acc1=process_delayed_txs(GetFun, Acc0),
  Acc2=cleanup_delayed(GetFun, Acc1),
  case Acc2 of
    #{aalloc:={Allocated,{_CG,_CB,CA}},
      new_settings:=SetState,
      settings:=Settings} when Allocated>0 ->
      IncAddr=#{<<"t">> => <<"set">>,
                <<"p">> => [<<"current">>, <<"allocblock">>, <<"last">>],
                <<"v">> => CA},
      AAlloc={<<"aalloc">>, #{sig=>[], patch=>[IncAddr]}},
      SS1=settings:patch(AAlloc, SetState),

      Acc2#{new_settings=>SS1,
            table=>maps:map(
                     fun(_,V) ->
                         mbal:uchanges(V)
                     end,
                     maps:get(table,Acc2,#{})
                    ),
            settings=>replace_set(AAlloc, Settings)
           };
    _Any ->
      Acc2
  end.

cleanup_delayed(_GetFun, #{delayed:=DTX, new_settings:=NS, settings:=Sets} = Acc) ->
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

process_delayed_txs(_GetFun, #{emit:=[]}=Acc) ->
  Acc;

process_delayed_txs(_GetFun, #{emit:=Emit, settings:=Settings, parent:=P,
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

txfind([],_TxID) ->
  false;

txfind([[_H,_P,TxID]=R|_],TxID) ->
  R;

txfind([_|Rest],TxID) ->
  txfind(Rest,TxID).


-spec try_process([{_,_}], map(), map(), fun(), mkblock_acc()) -> mkblock_acc().
try_process([], Settings, Addresses, GetFun,
            #{fee:=FeeBal, tip:=TipBal, emit:=Emit}=Acc) ->
  lager:info("try_process finish"),
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
    finish_processing(GetFun,
                      Acc#{
                        table=>Addresses2,
                        emit=>Emit ++ NewEmit,
                        new_settings => Settings
                       })
  catch _Ec:_Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:error("Can't save fees: ~p:~p", [_Ec, _Ee]),
          lists:foreach(fun(E) ->
                            lager:info("Can't save fee at ~p", [E])
                        end, S),
          finish_processing(GetFun,
                            Acc#{
                              table=>Addresses,
                              new_settings => Settings
                             }
                           )
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
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:info("Fail to process inbound block ~p ~p:~p",
                     [BlID, Ec, Ee]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{BlID, unknown}|Failed]
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
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                     [_LPatch, Ec, Ee, SetState]),
          lager:info("at ~p", [S]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{
                        failed=>[{TxID, Tx}|Failed]
                       })
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=lstore,
                      from:=Owner,
                      patches:=_
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success}=Acc) ->
  try
    Verify=try
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

    Bal=maps:get(Owner, Addresses),
    {NewF, _GasF, GotFee, _Gas}=withdraw(Bal, Tx, GetFun, SetState, [nogas,notransfer]),

    NewF4=maps:remove(keep, NewF),
    Set1=mbal:get(lstore, NewF4),

    Set2=settings:patch({TxID, Tx}, Set1),
    NewF5=mbal:put(lstore, Set2, NewF4),

    NewAddresses=maps:put(Owner, NewF5, Addresses),

    try_process(Rest, SetState, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success]}
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:info("LStore failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, other}|Failed]})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=tstore,
                      from:=Owner,
                      txext:=#{}
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success}=Acc) ->
  try
    Verify=try
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

    Bal=maps:get(Owner, Addresses),
    {NewF, _GasF, GotFee, _Gas}=withdraw(Bal, Tx, GetFun, SetState, [nogas,notransfer]),

    NewF4=maps:remove(keep, NewF),

    NewAddresses=maps:put(Owner, NewF4, Addresses),

    try_process(Rest, SetState, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success]}
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:info("TStore failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, other}|Failed]})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=deploy,
                      from:=Owner,
                      txext:=#{"code":=Code,"vm":=VMType0}=TxExt
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              aalloc:=AAlloc,
              get_addr:=GetAddr,
              success:=Success}=Acc) ->
  try
    Verify=try
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
    code:ensure_loaded(VM),
    A5=erlang:function_exported(VM,deploy,5),

    %State0=maps:get(state, Tx, <<>>),
    Bal=maps:get(Owner, Addresses),
    {NewF, GasF, GotFee, {GCur,GAmount,GRate}=Gas}=withdraw(Bal, Tx, GetFun, SetState, []),


    try

      NewF1=mbal:put(vm, VMType, NewF),
      NewF2=mbal:put(code, Code, NewF1),
      NewF3=case maps:find("view", TxExt) of
              error -> NewF2;
              {ok, View} ->
                mbal:put(view, View, NewF2)
            end,
      lager:info("Deploy contract ~s for ~s gas ~w",
                 [VM, naddress:encode(Owner), Gas]),
      IGas=GAmount*GRate,
      Left=fun(GL) ->
               lager:info("VM run gas ~p -> ~p",[IGas,GL]),
               {GCur, GL div GRate, GRate}
           end,
      OpaqueState=#{aalloc=>AAlloc,created=>[],changed=>[],get_addr=>GetAddr},
      {St1,GasLeft,NewCode,OpaqueState2}=if A5 ->
                         case erlang:apply(VM, deploy,
                                           [Tx,
                                            mbal:msgpack_state(Bal),
                                            IGas,
                                            GetFun,
                                            OpaqueState]) of
                           {ok, #{null:="exec",
                                  "err":=Err}, _Opaque} ->
                             try
                               AErr=erlang:list_to_existing_atom(Err),
                               throw(AErr)
                             catch error:badarg ->
                                     throw(Err)
                             end;
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft, "code":=Code1 }, Opaque} ->
                             {St2, Left(IGasLeft), Code1, Opaque};
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft }, Opaque} ->
                             {St2, Left(IGasLeft), undefined, Opaque};
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft, "code":=Code1 }} ->
                             logger:info("Deploy does not returned opaque state"),
                             {St2, Left(IGasLeft), Code1, OpaqueState};
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft }} ->
                             logger:info("Deploy does not returned opaque state"),
                             {St2, Left(IGasLeft), undefined, OpaqueState};
                           {error, Error} ->
                             throw(Error);
                           _Any ->
                             lager:error("Deploy error ~p",[_Any]),
                             throw(other_error)
                         end
                    end,
      #{aalloc:=AAlloc2}=OpaqueState2,

      St1Dec = if is_binary(St1) ->
                    {ok, St1Dec1}=msgpack:unpack(St1),
                    St1Dec1;
                  is_map(St1) ->
                    St1
               end,
      AppliedState=mbal:put(mergestate, St1Dec, NewF3),
      NewF4=maps:remove(keep,
                        if NewCode==undefined ->
                             AppliedState;
                           true ->
                             mbal:put(code,NewCode, AppliedState)
                        end),

      NewAddresses=case GasLeft of
                     {_, 0, _} ->
                       maps:put(Owner, NewF4, Addresses);
                     {_, IGL, _} when IGL < 0 ->
                       throw('insufficient_gas');
                     {_, IGL, _} when IGL > 0 ->
                       XBal1=return_gas(GasLeft, SetState, NewF4),
                       maps:put(Owner, XBal1, Addresses)
                   end,

      %    NewAddresses=maps:put(Owner, NewF3, Addresses),

      try_process(Rest, SetState, NewAddresses, GetFun,
                  savegas(Gas, GasLeft,
                          savefee(GotFee,
                                  Acc#{
                                    success=> [{TxID, Tx}|Success],
                                    aalloc=>AAlloc2
                                   }
                                 )
                         ))
    catch throw:insufficient_gas=ThrowReason ->
            NewAddressesG=maps:put(Owner, GasF, Addresses),
            try_process(Rest, SetState, NewAddressesG, GetFun,
                        savegas(Gas, all,
                                savefee(GotFee,
                                        Acc#{failed=> [{TxID, ThrowReason}|Failed]}
                                       )
                               ))
    end
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        throw:X ->
          lager:info("Contract deploy failed ~p", [X]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          %io:format("DEPLOY ERROR ~p:~p~n",[Ec,Ee]),
          lager:info("Contract deploy failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            %io:format("@ ~p~n", [SE])
                            lager:info("@ ~p~n", [SE])
                        end, S),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, other}|Failed]})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=deploy,
                      from:=Owner,
                      txext:=#{"view":=NewView}
                     }=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success}=Acc) ->
  try
    Verify=try
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

    Bal=maps:get(Owner, Addresses),
    case mbal:get(vm, Bal) of
      VM when is_binary(VM) ->
        ok;
      _ ->
        throw('not_deployed')
    end,

    {NewF, _GasF, GotFee, Gas}=withdraw(Bal, Tx, GetFun, SetState, []),

    NewF1=maps:remove(keep,
                      mbal:put(view, NewView, NewF)
                     ),
    lager:info("F1 ~p",[maps:without([code,state],NewF1)]),

    NewF2=return_gas(Gas, SetState, NewF1),
    lager:info("F2 ~p",[maps:without([code,state],NewF2)]),
    NewAddresses=maps:put(Owner, NewF2, Addresses),

    try_process(Rest, SetState, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success]}
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        throw:X ->
          lager:info("Contract deploy failed ~p", [X]),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, X}|Failed]});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:info("Contract deploy failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, other}|Failed]})
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
              aalloc:=AAl,
              success:=Success,
              settings:=_Settings }=Acc) ->
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

    {ok, NewBAddr, AAl1} = aalloc(AAl),

    lager:info("Alloc address ~p ~s for key ~s",
               [NewBAddr,
                naddress:encode(NewBAddr),
                hex:encode(PubKey)
               ]),

    NewF=mbal:put(pubkey, PubKey, mbal:new()),
    NewAddresses=maps:put(NewBAddr, NewF, Addresses),
    NewTx=maps:remove(inv,tx:set_ext(<<"addr">>,NewBAddr,Tx)),
    lager:info("try process register tx [~p]: ~p", [NewBAddr, NewTx]),
    try_process(Rest, SetState, NewAddresses, GetFun,
                Acc#{success=> [{TxID, NewTx}|Success],
                     aalloc=>AAl1
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
                        from:=From,
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

    Gas=case tx:get_ext(<<"xc_gas">>, Tx) of
          undefined -> {<<"NONE">>,0,1};
          {ok, [GasCur, GasAmount]} ->
            case to_gas(#{amount=>GasAmount,cur=>GasCur},SetState) of
              {ok, G} ->
                G;
              _ ->
                {<<"NONE">>,0,1}
            end
        end,

    lager:info("Orig Block ~p", [OriginBlock]),
    {Addresses2, NewEmit, GasLeft, Acc1}=deposit(To, Addresses, Tx, GetFun, RealSettings, Gas, Acc),
    %Addresses2=maps:put(To, NewT, Addresses),

    NewAddresses=case GasLeft of
                   {_, 0, _} ->
                     Addresses2;
                   {_, IGL, _} when IGL < 0 ->
                     throw('insufficient_gas');
                   {_, IGL, _} when IGL > 0 ->
                     lager:notice("Return gas ~p to sender",[From]),
                     Addresses2
                 end,

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
                Acc1#{success=>[{TxID, FixTX}|Success],
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
    NewTAmount=mbal:get_cur(Cur, TBal) + Amount,
    NewT=maps:remove(keep,
                     mbal:put_cur(
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
  lager:info("Processing outbound ==[ ~s ]=======",[TxID]),
  lager:notice("TODO:Check signature once again"),
  lager:info("outbound to chain ~p ~p", [OutTo, To]),
  FBal=maps:get(From, Addresses),
  EnsureSettings=fun(undefined) -> GetFun(settings);
                    (SettingsReady) -> SettingsReady
                 end,

  try
    RealSettings=EnsureSettings(SetState),
    {NewF, _GasF, GotFee, GotGas}=withdraw(FBal, Tx, GetFun, RealSettings, []),
    lager:info("Got gas ~p",[GotGas]),

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
    Tx1=case GotGas of
          {_,0,_} -> tx:del_ext(<<"xc_gas">>, Tx);
          {GasCur, GasAmount, _} ->
            tx:set_ext(<<"xc_gas">>, [GasCur, GasAmount], Tx)
        end,
    try_process(Rest, SS2, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{
                          settings=>Set2,
                          success=>[{TxID, Tx1}|Success],
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
    lager:info("Processing local =====[ ~s ]=======",[TxID]),
    OrigF=maps:get(From, Addresses),
    {NewF, GasF, GotFee, Gas}=withdraw(OrigF, Tx, GetFun, RealSettings, []),
    try
      Addresses1=maps:put(From, NewF, Addresses),
      {Addresses2, NewEmit, GasLeft, Acc1}=deposit(To, Addresses1,
                                                   Tx, GetFun,
                                                   RealSettings, Gas, Acc),
      lager:info("Local gas ~p -> ~p f ~p t ~p",[Gas, GasLeft, From, To]),
      %Addresses2=maps:put(To, NewT, Addresses1),

      NewAddresses=case GasLeft of
                     {_, 0, _} ->
                       Addresses2;
                     {_, IGL, _} when IGL < 0 ->
                       throw('insufficient_gas');
                     {_, IGL, _} when IGL > 0 ->
                       Bal0=maps:get(From, Addresses2),
                       Bal1=return_gas(GasLeft, RealSettings, Bal0),
                       maps:put(From, Bal1, Addresses2)
                   end,

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
                  savegas(Gas, GasLeft,
                          savefee(GotFee,
                                  Acc1#{
                                    success=>[{TxID, Tx1}|Success],
                                    emit=>Emit ++ NewEmit
                                   }
                                 )
                         )
                 )
    catch
      throw:insufficient_gas ->
        AddressesWoGas=maps:put(From, GasF, Addresses),
        try_process(Rest, SetState, AddressesWoGas, GetFun,
                    savegas(Gas, all,
                            savefee(GotFee,
                                    Acc#{failed=>[{TxID, insufficient_gas}|Failed]}
                                   )
                           )
                   )
    end
  catch
    error:{badkey,From} ->
      try_process(Rest, SetState, Addresses, GetFun,
                  Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
    error:{badkey,To} ->
      try_process(Rest, SetState, Addresses, GetFun,
                  Acc#{failed=>[{TxID, no_dst_addr_loaded}|Failed]});
    throw:X ->
      try_process(Rest, SetState, Addresses, GetFun,
                  Acc#{failed=>[{TxID, fmterr(X)}|Failed]});
    error:X:S ->
      io:format("Error ~p at ~p/~p~n",[X,hd(S),hd(tl(S))]),
      try_process(Rest, SetState, Addresses, GetFun,
                  Acc#{failed=>[{TxID, fmterr(X)}|Failed]})
  end.

savegas({Cur, Amount1, Rate1}, all, Acc) ->
  savegas({Cur, Amount1, Rate1}, {Cur, 0, Rate1}, Acc);

savegas({Cur, Amount1, _}, {Cur, Amount2, _}, #{fee:=FeeBal}=Acc) ->
  io:format("save gas ~s ~w-~w=~w ~n",[Cur,Amount1, Amount2,Amount1-Amount2]),
  lager:info("save gas ~s ~w ~w",[Cur,Amount1, Amount2]),
  if Amount1-Amount2 > 0 ->
       Acc#{
         fee=>mbal:put_cur(Cur, Amount1-Amount2 +
                           mbal:get_cur(Cur, FeeBal), FeeBal)
        };
     true ->
       Acc
  end.

-spec savefee(GotFee :: {binary(),non_neg_integer(),non_neg_integer()},
              mkblock_acc()) -> mkblock_acc().

savefee({Cur, Fee, Tip}, #{fee:=FeeBal, tip:=TipBal}=Acc) ->
  io:format("save fee  ~s ~w ~w~n",[Cur,Fee,Tip]),
  Acc#{
    fee=>mbal:put_cur(Cur, Fee+mbal:get_cur(Cur, FeeBal), FeeBal),
    tip=>mbal:put_cur(Cur, Tip+mbal:get_cur(Cur, TipBal), TipBal)
   }.

gas_plus_int({Cur,Amount, Rate}, Int, false) ->
  {Cur, Amount+(Int/Rate), Rate};

gas_plus_int({Cur,Amount, Rate}, Int, true) ->
  {Cur, trunc(Amount+(Int/Rate)), Rate}.

is_gas_left({_,Amount,_Rate}) ->
  Amount>0.

deposit(Address, Addresses0, #{ver:=2}=Tx, GetFun, Settings, GasLimit,
        #{height:=Hei,parent:=Parent,aalloc:=AAlloc,get_addr:=GetAddr}=Acc) ->
  TBal0=maps:get(Address,Addresses0),
  NewT=maps:remove(keep,
                   lists:foldl(
                     fun(#{amount:=Amount, cur:= Cur}, TBal) ->
                         NewTAmount=mbal:get_cur(Cur, TBal) + Amount,
                         mbal:put_cur( Cur, NewTAmount, TBal)
                     end, TBal0, tx:get_payloads(Tx,transfer))),
  Addresses=maps:put(Address,NewT,Addresses0),
  case mbal:get(vm, NewT) of
    undefined ->
      {Addresses, [], GasLimit, Acc};
    VMType ->
      FreeGas=case settings:get([<<"current">>, <<"freegas">>], Settings) of
                N when is_integer(N), N>0 -> N;
                _ -> 0
              end,
      lager:info("Smartcontract ~p gas ~p free gas ~p", [VMType, GasLimit, FreeGas]),
      GetAddr1=fun({storage,BAddr,BKey}=Q) ->
                   case maps:get(BAddr,Addresses,undefined) of
                     undefined ->
                       GetAddr(Q);
                     #{state:=#{BKey:=BVal}} ->
                       BVal;
                     _ ->
                       GetAddr(Q)
                   end
               end,
      OpaqueState=#{aalloc=>AAlloc,created=>[],changed=>[],get_addr=>GetAddr1},

      GetFun1 = fun({addr,ReqAddr,code}) ->
                    io:format("Request code for address ~p~n",[ReqAddr]),
                    case maps:is_key(ReqAddr,Addresses) of
                      true ->
                        mbal:get(code,maps:get(ReqAddr, Addresses));
                      false ->
                        mbal:get(code,GetAddr(ReqAddr))
                    end;
                   ({addr,ReqAddr,storage,Key}=Request) ->
                    io:format("Request storage key ~p address ~p~n",[Key,ReqAddr]),
                    case maps:is_key(ReqAddr,Addresses) of
                      true ->
                        AddrStor=mbal:get(state,maps:get(ReqAddr, Addresses)),
                        maps:get(Key,AddrStor,<<>>);
                      false ->
                        GetFun(Request)
                    end;
                  (Other) ->
                   GetFun(Other)
               end,

      {LedgerPatches, TXs, GasLeft, OpaqueState2} =
      if FreeGas > 0 ->
           GasWithFree=gas_plus_int(GasLimit,FreeGas,true),
           lager:info("Run with free gas ~p+~p=~p",
                      [GasLimit,FreeGas,GasWithFree]),
           {L1x,TXsx,GasLeftx,OpaqueState2a} =
           smartcontract:run(VMType, Tx, NewT,
                             GasWithFree,
                             GetFun1,
                             OpaqueState),

           TakenFree=gas_plus_int(GasLeftx,-FreeGas,true),
           case is_gas_left(TakenFree) of
             true ->
               lager:info("Gas left ~p, take back free gas and return ~p",
                          [GasLeftx,TakenFree]),
               {L1x,TXsx,TakenFree,OpaqueState2a};
             false ->
               lager:info("Gas left ~p, return nothing",[GasLeftx]),
               {L1x,TXsx,{<<"NONE">>,0,1},OpaqueState2a}
           end;
         true ->
           smartcontract:run(VMType, Tx, NewT, GasLimit, GetFun1, OpaqueState)
      end,
      io:format("Gas1 ~p left ~p~n",[GasLimit,GasLeft]),
      io:format("Opaque2 ~p~n",[OpaqueState2]),

      #{aalloc:=AAlloc2,created:=Created,changed:=Changes}=OpaqueState2,
      EmitTxs=lists:map(
                fun(ETxBody) ->
                    Template=#{
                               "f"=>Address,
                               "s"=>0,
                               "t"=>0,
                               "p"=>[],
                               "ev"=>[]},
                    #{from:=TxFrom,seq:=_Seq}=ETx=tx:complete_tx(ETxBody,Template),

                    if(TxFrom=/=Address) ->
                        throw('emit_wrong_from');
                      true ->
                        ok
                    end,
                    H=base64:encode(crypto:hash(sha, [Parent,ETxBody])),
                    BinId=binary:encode_unsigned(Hei),
                    BSeq=hex:encode(<<(size(BinId)):8,BinId/binary>>),
                    EA=hex:encode(Address),
                    TxID= <<EA/binary, BSeq/binary, H/binary>>,
                    {TxID,
                     tx:set_ext( <<"contract_issued">>, Address, ETx)
                    }
                end, TXs),
      Addresses2=lists:foldl(
                   fun(Addr1,AddrAcc) ->
                       io:format("Put ~p into ~p~n",[maps:get(Addr1,OpaqueState2,undefined), Addr1]),
                       maps:put(Addr1,maps:get(Addr1,OpaqueState2,#{}),AddrAcc)
                   end, Addresses, Created),
      Addresses3=lists:foldl(
                   fun({{Addr1,mergestate},Data},AddrAcc) ->
                       io:format("Merge state for ~p~n",[Addr1]),
                       MBal0=case maps:is_key(Addr1,AddrAcc) of
                              true ->
                                maps:get(Addr1,AddrAcc);
                              false ->
                                 GetAddr(Addr1)
                            end,
                       MBal1=mbal:put(mergestate,Data,MBal0),
                       maps:put(Addr1,MBal1,AddrAcc);
                      (_Any,AddrAcc) ->
                        lager:notice("Ignore patch from VM ~p",[_Any]),
                        io:format("ignore patch ~p~n",[_Any]),
                        AddrAcc
                   end, Addresses2, Changes),
                       LToPatch=maps:get(Address, Addresses3),
      Addresses4=maps:put(Address, mbal:patch(LedgerPatches,LToPatch), Addresses3),
      {Addresses4, EmitTxs, GasLeft, Acc#{aalloc=>AAlloc2}}
  end.

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

withdraw(FBal0,
         #{ver:=2, seq:=Seq, t:=Timestamp, from:=From}=Tx,
         GetFun, Settings, Opts) ->
  try
    Contract_Issued=tx:get_ext(<<"contract_issued">>, Tx),
    IsContract=is_binary(mbal:get(vm, FBal0)) andalso Contract_Issued=={ok, From},

    lager:info("Withdraw ~p ~p", [IsContract, maps:without([body,sig],Tx)]),
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
    LD=mbal:get(t, FBal0) div 86400000,
    CD=Timestamp div 86400000,
    if IsContract -> ok;
       true ->
         NoSK=settings:get([<<"current">>, <<"nosk">>], Settings)==1,
         if NoSK -> ok;
            true ->
              FSK=mbal:get_cur(<<"SK">>, FBal0),
              FSKUsed=if CD>LD ->
                           0;
                         true ->
                           mbal:get(usk, FBal0)
                      end,
              lager:debug("usk ~p SK ~p",[FSKUsed,FSK]),
              if FSK < 1 ->
                   case GetFun({endless, From, <<"SK">>}) of
                     true -> ok;
                     false -> throw('no_sk')
                   end;
                 FSKUsed >= FSK -> throw('sk_limit');
                 true -> ok
              end
         end
    end,
    CurFSeq=mbal:get(seq, FBal0),
    if CurFSeq < Seq -> ok;
       Seq==0 andalso IsContract -> ok;
       true ->
         %==== DEBUG CODE
         L=try
             mledger:get(From)
           catch _:_ ->
                   cant_get_ledger
           end,
         lager:error("Bad seq addr ~p, cur ~p tx ~p, ledger ~p",
                     [From, CurFSeq, Seq, L]),
         %==== END DEBU CODE
         throw ('bad_seq')
    end,
    CurFTime=mbal:get(t, FBal0),
    if CurFTime < Timestamp -> ok;
       IsContract andalso Timestamp==0 -> ok;
       true -> throw ('bad_timestamp')
    end,

    NoTakeFee = lists:member(nofee,Opts),
    {ForFee,GotFee}=if IsContract ->
                         {[],{<<"NONE">>,0,0}};
                       NoTakeFee ->
                         {[],{<<"NONE">>,0,0}};
                       true ->
                         GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
                                       settings:get([
                                                     <<"current">>,
                                                     <<"fee">>,
                                                     FeeCur], Settings);
                                       ({params, Parameter}) ->
                                       settings:get([<<"current">>,
                                                     <<"fee">>,
                                                     params,
                                                     Parameter], Settings)
                                   end,
                         {FeeOK,Rate}=tx:rate(Tx, GetFeeFun),
                         if FeeOK -> ok;
                            true ->
                              #{cost:=MinCost}=Rate,
                              throw ({'insufficient_fee', MinCost})
                         end,
                         #{cost:=FeeCost, cur:=FeeCur}=Rate,
                         {[#{amount=>FeeCost, cur=>FeeCur}],{FeeCur,FeeCost,0}}
                    end,

    TakeGas = not lists:member(nogas,Opts),
    {ForGas,GotGas}= case TakeGas of
                       false ->
                         {[], {<<"NONE">>,0,1}};
                       true ->
                         lists:foldl(
                           fun(Payload, {[],{<<"NONE">>,0,_}}=Acc) ->
                               case to_gas(Payload,Settings) of
                                 {ok, G} ->
                                   {[Payload], G};
                                 _ ->
                                   Acc
                               end;
                              (_,Res) -> Res
                           end, {[], {<<"NONE">>,0,1}},
                           tx:get_payloads(Tx,gas)
                          )
                     end,
    io:format("Fee ~p Gas ~p~n", [GotFee,GotGas]),
    lager:info("Fee ~p Gas ~p", [GotFee,GotGas]),

    TakeMoney=fun(#{amount:=Amount, cur:= Cur}, FBal) ->
                  if Amount >= 0 ->
                       ok;
                     true ->
                       throw ('bad_amount')
                  end,
                  CurFAmount=mbal:get_cur(Cur, FBal),
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
                  mbal:put_cur(Cur,
                               NewFAmount,
                               FBal)

              end,
    ToTransfer=tx:get_payloads(Tx,transfer),

    FBal1=maps:remove(keep,
                      mbal:mput(
                        ?MAX(Seq,CurFSeq),
                        Timestamp,
                        FBal0,
                        if IsContract ->
                             false;
                           true ->
                             if CD>LD -> reset;
                                true -> true
                             end
                        end
                       )),
    FBalAfterGas=lists:foldl(TakeMoney,
                             FBal1,
                             ForGas++ForFee
                            ),

    NoTakeTransfer = lists:member(notransfer,Opts),
    NewBal=if NoTakeTransfer ->
                FBalAfterGas;
              true ->
                lists:foldl(TakeMoney,
                            FBalAfterGas,
                            ToTransfer
                           )
           end,

    {NewBal, FBalAfterGas, GotFee, GotGas}
  catch error:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:error("Withdrawal error ~p tx ~p",[Ee,Tx]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          throw('unknown_withdrawal_error')
  end.

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
   }=try_process(TXL, XSettings, Addrs, GetSettings,
                 #{export=>[],
                   delayed=>Delayed,
                   failed=>[],
                   success=>[],
                   settings=>[],
                   outbound=>[],
                   table=>#{},
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

to_bin(List) when is_list(List) -> list_to_binary(List);
to_bin(Bin) when is_binary(Bin) -> Bin.

to_gas(#{amount:=A, cur:=C}, Settings) ->
  Path=[<<"current">>, <<"gas">>, C],
  case settings:get(Path, Settings) of
    I when is_integer(I) ->
      {ok, {C, A, I}};
    _ ->
      error
  end.

return_gas({<<"NONE">>, _GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  Bal0;

return_gas({GCur, GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  io:format("return_gas ~p left ~b~n",[GCur, GAmount]),
  if(GAmount > 0) ->
      B1=mbal:get_cur(GCur,Bal0),
      mbal:put_cur(GCur, B1+GAmount, Bal0);
    true ->
      Bal0
  end.

settings_hash(NewSettings) when is_map(NewSettings) ->
  maphash:hash(NewSettings).

replace_set({Key,_}=New,Settings) ->
  [New|lists:keydelete(Key, 1, Settings)].

aalloc({_,{_CG,_CB, CA}}) when CA>=16#FFFFFE ->
  throw(unallocable);

aalloc({N,{CG,CB,CA}}) ->
    NewBAddr=naddress:construct_public(CG, CB, CA+1),
    {ok, NewBAddr, {N+1, {CG,CB,CA+1}}};

aalloc({_N,unallocable}) ->
  throw(unallocable).

fmterr(X) when is_atom(X) ->
  X;

fmterr({X,N}) when is_atom(X), is_integer(N) ->
  {X,N};

fmterr(X) ->
  iolist_to_binary(io_lib:format("~p",[X],[{chars_limit, 80}])).

