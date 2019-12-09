-module(generate_block).

-export([generate_block/5, generate_block/6]).
-export([return_gas/4, sort_txs/1]).


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
                           GetFun, Settings, free),
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
    Acc#{
      table=>Addresses2,
      emit=>Emit ++ NewEmit,
      new_settings => Settings
    }
  catch _Ec:_Ee ->
          S=erlang:get_stacktrace(),
        lager:error("Can't save fees: ~p:~p", [_Ec, _Ee]),
        lists:foreach(fun(E) ->
                  lager:info("Can't save fee at ~p", [E])
              end, S),
        Acc#{
          table=>Addresses,
          new_settings => Settings
        }
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
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
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
    throw('fixme_portin'),
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
    throw('fixme_portout'),
        Bals=maps:get(From, Addresses),
        A1=maps:remove(keep, Bals),
        Empty=maps:size(A1)==0,
        OffChain=maps:is_key(chain, A1),
        if Empty -> throw('badaddress');
           OffChain -> throw('offchain');
           true -> ok
        end,
        ValidChains=chainsettings:by_path([chains]),
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
    Set1=bal:get(lstore, NewF4),

    Set2=settings:patch({TxID, Tx}, Set1),
    NewF5=bal:put(lstore, Set2, NewF4),

    NewAddresses=maps:put(Owner, NewF5, Addresses),

    try_process(Rest, SetState, NewAddresses, GetFun,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success]}
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest, SetState, Addresses, GetFun,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed]});
        Ec:Ee ->
          S=erlang:get_stacktrace(),
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
        Ec:Ee ->
          S=erlang:get_stacktrace(),
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
    A4=erlang:function_exported(VM,deploy,4),
    A6=erlang:function_exported(VM,deploy,6),

    State0=maps:get(state, Tx, <<>>),
    Bal=maps:get(Owner, Addresses),
    {NewF, GasF, GotFee, {GCur,GAmount,GRate}=Gas}=withdraw(Bal, Tx, GetFun, SetState, []),


    try

      NewF1=bal:put(vm, VMType, NewF),
      NewF2=bal:put(code, Code, NewF1),
      NewF3=case maps:find("view", TxExt) of
              error -> NewF2;
              {ok, View} ->
                bal:put(view, View, NewF2)
            end,
      lager:info("Deploy contract ~s for ~s gas ~w",
                 [VM, naddress:encode(Owner), {GCur,GAmount,GRate}]),
      lager:info("A4 ~p A6 ~p",[A4,A6]),
      IGas=GAmount*GRate,
      Left=fun(GL) ->
               lager:info("VM run gas ~p -> ~p",[IGas,GL]),
               {GCur, GL div GRate, GRate}
           end,
      {St1,GasLeft}=if A4 ->
                         case erlang:apply(VM, deploy, [Tx, Bal, IGas, GetFun]) of
                           {ok, #{null:="exec",
                                  "err":=Err}} ->
                             try
                               AErr=erlang:list_to_existing_atom(Err),
                               throw(AErr)
                             catch error:badarg ->
                                     throw(Err)
                             end;
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft }} ->
                             {St2, Left(IGasLeft)};
                           {error, Error} ->
                             throw(Error);
                           _Any ->
                             lager:error("Deploy error ~p",[_Any]),
                             throw(other_error)
                         end;
                       A6 ->
                         case erlang:apply(VM, deploy, [Owner, Bal, Code, State0, 1, GetFun]) of
                           {ok, NewS} ->
                             {NewS, Left(0)};
                           {error, Error} ->
                             throw({'deploy_error', Error});
                           _Any ->
                             lager:error("Deploy error ~p",[_Any]),
                             throw({'deploy_error', other})
                         end
                    end,
      NewF4=maps:remove(keep,
                        bal:put(state, St1, NewF3)
                       ),

      NewAddresses=case GasLeft of
                     {_, 0, _} ->
                       maps:put(Owner, NewF4, Addresses);
                     {_, IGL, _} when IGL < 0 ->
                       throw('insufficient_gas');
                     {_, IGL, _} when IGL > 0 ->
                       XBal1=return_gas(Tx, GasLeft, SetState, NewF4),
                       maps:put(Owner, XBal1, Addresses)
                   end,

      %    NewAddresses=maps:put(Owner, NewF3, Addresses),

      try_process(Rest, SetState, NewAddresses, GetFun,
                  savegas(Gas, GasLeft,
                          savefee(GotFee,
                                  Acc#{success=> [{TxID, Tx}|Success]}
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
        Ec:Ee ->
          S=erlang:get_stacktrace(),
          lager:info("Contract deploy failed ~p:~p", [Ec,Ee]),
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
    case bal:get(vm, Bal) of
      VM when is_binary(VM) ->
        ok;
      _ ->
        throw('not_deployed')
    end,

    {NewF, _GasF, GotFee, Gas}=withdraw(Bal, Tx, GetFun, SetState, []),

    NewF1=maps:remove(keep,
                      bal:put(view, NewView, NewF)
                     ),
    lager:info("F1 ~p",[maps:without([code,state],NewF1)]),

    NewF2=return_gas(Tx, Gas, SetState, NewF1),
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
        Ec:Ee ->
          S=erlang:get_stacktrace(),
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
    lager:info("try process register tx [~p]: ~p", [NewBAddr, NewTx]),
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
  lager:notice("Deprecated register method"),
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
      {NewT, NewEmit, GasLeft}=deposit(To, maps:get(To, Addresses), Tx, GetFun, RealSettings, Gas),
      Addresses2=maps:put(To, NewT, Addresses),

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
      {NewT, NewEmit, GasLeft}=deposit(To, maps:get(To, Addresses1), Tx, GetFun, RealSettings, Gas),
      lager:info("Local gas ~p -> ~p f ~p t ~p",[Gas, GasLeft, From, To]),
      Addresses2=maps:put(To, NewT, Addresses1),

      NewAddresses=case GasLeft of
                     {_, 0, _} ->
                       Addresses2;
                     {_, IGL, _} when IGL < 0 ->
                       throw('insufficient_gas');
                     {_, IGL, _} when IGL > 0 ->
                       Bal0=maps:get(From, Addresses2),
                       Bal1=return_gas(Tx, GasLeft, RealSettings, Bal0),
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
                                  Acc#{
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
                  Acc#{failed=>[{TxID, X}|Failed]})
  end.

savegas({Cur, Amount1, Rate1}, all, Acc) ->
  savegas({Cur, Amount1, Rate1}, {Cur, 0, Rate1}, Acc);

savegas({Cur, Amount1, _}, {Cur, Amount2, _},
        #{fee:=FeeBal}=Acc) ->
  lager:info("save gas ~s ~w ~w",[Cur,Amount1, Amount2]),
  if Amount1-Amount2 > 0 ->
       Acc#{
         fee=>bal:put_cur(Cur, Amount1-Amount2 +
                          bal:get_cur(Cur, FeeBal), FeeBal)
        };
     true ->
       Acc
  end.

-spec savefee(GotFee :: {binary(),non_neg_integer(),non_neg_integer()},
              mkblock_acc()) -> mkblock_acc().

savefee({Cur, Fee, Tip}, #{fee:=FeeBal, tip:=TipBal}=Acc) ->
  Acc#{
    fee=>bal:put_cur(Cur, Fee+bal:get_cur(Cur, FeeBal), FeeBal),
    tip=>bal:put_cur(Cur, Tip+bal:get_cur(Cur, TipBal), TipBal)
   }.

gas_plus_int({Cur,Amount, Rate}, Int, false) ->
  {Cur, Amount+(Int/Rate), Rate};

gas_plus_int({Cur,Amount, Rate}, Int, true) ->
  {Cur, trunc(Amount+(Int/Rate)), Rate}.

is_gas_left({_,Amount,_Rate}) ->
  Amount>0.

deposit(Address, TBal0, #{ver:=2}=Tx, GetFun, Settings, GasLimit) ->
  NewT=maps:remove(keep,
                   lists:foldl(
                     fun(#{amount:=Amount, cur:= Cur}, TBal) ->
                         NewTAmount=bal:get_cur(Cur, TBal) + Amount,
                         bal:put_cur( Cur, NewTAmount, TBal)
                     end, TBal0, tx:get_payloads(Tx,transfer))),
  case bal:get(vm, NewT) of
    undefined ->
      {NewT, [], GasLimit};
    VMType ->
      FreeGas=case settings:get([<<"current">>, <<"freegas">>], Settings) of
                N when is_integer(N), N>0 -> N;
                _ -> 0
              end,
      lager:info("Smartcontract ~p gas ~p free gas ~p", [VMType, GasLimit, FreeGas]),
      {L1, TXs, GasLeft} =
            if FreeGas > 0 ->
                 GasWithFree=gas_plus_int(GasLimit,FreeGas,false),
                 lager:info("Run with free gas ~p+~p=~p",
                            [GasLimit,FreeGas,GasWithFree]),
                 {L1x,TXsx,GasLeftx} =
                       smartcontract:run(VMType, Tx, NewT,
                                         GasWithFree,
                                         GetFun),
                 TakenFree=gas_plus_int(GasLeftx,-FreeGas,true),
                 case is_gas_left(TakenFree) of
                   true ->
                     lager:info("Gas left ~p, take back free gas and return ~p",
                                [GasLeftx,TakenFree]),
                     {L1x,TXsx,TakenFree};
                   false ->
                     lager:info("Gas left ~p, return nothing",[GasLeftx]),
                     {L1x,TXsx,{<<"NONE">>,0,1}}
                 end;
               true ->
                 smartcontract:run(VMType, Tx, NewT, GasLimit, GetFun)
            end,
      {L1, lists:map(
             fun(#{seq:=Seq}=ETx) ->
                 H=base64:encode(crypto:hash(sha, bal:get(state, TBal0))),
                 BSeq=bin2hex:dbin2hex(<<Seq:64/big>>),
                 EA=(naddress:encode(Address)),
                 TxID= <<EA/binary, BSeq/binary, H/binary>>,
                 {TxID,
                  tx:set_ext( <<"contract_issued">>, Address, ETx)
                 }
             end, TXs), GasLeft}
  end;

deposit(Address, TBal,
    #{cur:=Cur, amount:=Amount}=Tx,
    GetFun, _Settings, GasLimit) ->
  NewTAmount=bal:get_cur(Cur, TBal) + Amount,
  NewT=maps:remove(keep,
           bal:put_cur( Cur, NewTAmount, TBal)
          ),
  case bal:get(vm, NewT) of
    undefined ->
      {NewT, [], GasLimit};
    VMType ->
      lager:info("Smartcontract ~p", [VMType]),
      {L1, TXs, Gas}=smartcontract:run(VMType, Tx, NewT, GasLimit, GetFun),
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
         GetFun, Settings, Opts) ->
  try
    Contract_Issued=tx:get_ext(<<"contract_issued">>, Tx),
    IsContract=is_binary(bal:get(vm, FBal0)) andalso Contract_Issued=={ok, From},

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
    LD=bal:get(t, FBal0) div 86400000,
    CD=Timestamp div 86400000,
    if IsContract -> ok;
       true ->
         NoSK=settings:get([<<"current">>, <<"nosk">>], Settings)==1,
         if NoSK -> ok;
            true ->
              FSK=bal:get_cur(<<"SK">>, FBal0),
              FSKUsed=if CD>LD ->
                           0;
                         true ->
                           bal:get(usk, FBal0)
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

    lager:info("Fee ~p Gas ~p", [GotFee,GotGas]),

    TakeMoney=fun(#{amount:=Amount, cur:= Cur}, FBal) ->
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
                bal:put_cur(Cur,
                            NewFAmount,
                            FBal)
               
            end,
    ToTransfer=tx:get_payloads(Tx,transfer),

    FBal1=maps:remove(keep,
                      bal:mput(
                        Seq,
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
     GetFun, Settings, _Opts) ->
  lager:notice("Deprecated withdraw"),
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
                     bal:put_cur(
                       Cur,
                       NewFAmount,
                       bal:mput(
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
       {NewBal, FBal, {Cur, 0, 0}, {<<"NONE">>,0,1}};
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
       {NewBal2, FBal, {FeeCur, FeeCost, Tip} ,{<<"NONE">>,0,1}}
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

  Load=fun({_, #{hash:=_, header:=#{}, txs:=Txs}}, AAcc0) ->
           lager:debug("TXs ~p", [Txs]),
            lists:foldl(
              fun({_, #{to:=T, cur:=_}}, AAcc) ->
                  TB=bal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
                  maps:put(T, TB, AAcc);
                 ({_, #{ver:=2, kind:=generic, to:=T, payload:=_}}, AAcc) ->
                  TB=bal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
                  maps:put(T, TB, AAcc)
              end, AAcc0, Txs);
          ({_, #{patch:=_}}, AAcc) -> AAcc;
          ({_, #{register:=_}}, AAcc) -> AAcc;
%          ({_, #{from:=F, portin:=_ToChain}}, SAcc) ->
%           case maps:get(F, AAcc, undefined) of
%                undefined ->
%                  AddrInfo1=GetAddr(F),
%                  maps:put(F, AddrInfo1#{keep=>false}, AAcc);
%                _ ->
%                  AAcc
%              end;
%          ({_, #{from:=F, portout:=_ToChain}}, {AAcc, SAcc}) ->
%           A1=case maps:get(F, AAcc, undefined) of
%                undefined ->
%                  AddrInfo1=GetAddr(F),
%                  lager:info("Add address for portout ~p", [AddrInfo1]),
%                  maps:put(F, AddrInfo1#{keep=>false}, AAcc);
%                _ ->
%                  AAcc
%              end,
%           {A1, SAcc};
%          ({_, #{from:=F, deploy:=_}}, AAcc) ->
%           case maps:get(F, AAcc, undefined) of
%                undefined ->
%                  AddrInfo1=GetAddr(F),
%                  maps:put(F, AddrInfo1#{keep=>false}, AAcc);
%                _ ->
%                  AAcc
%              end;
          ({_TxID, #{ver:=2, to:=T, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=bal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           TB=bal:fetch(T, <<"ANY">>, false, maps:get(T, AAcc, #{}), GetAddr),
           maps:put(F, FB, maps:put(T, TB, AAcc));
          ({_TxID, #{ver:=2, kind:=register}}=_TX, AAcc) ->
            AAcc;
          ({_TxID, #{ver:=2, kind:=deploy, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=bal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_TxID, #{ver:=2, kind:=tstore, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=bal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_TxID, #{ver:=2, kind:=lstore, from:=F, payload:=_}}=_TX, AAcc) ->
           FB=bal:fetch(F, <<"ANY">>, true, maps:get(F, AAcc, #{}), GetAddr),
           maps:put(F, FB, AAcc);
          ({_, #{to:=T, from:=F, cur:=Cur}}, AAcc) ->
           FB=bal:fetch(F, Cur, true, maps:get(F, AAcc, #{}), GetAddr),
           TB=bal:fetch(T, Cur, false, maps:get(T, AAcc, #{}), GetAddr),
           maps:put(F, FB, maps:put(T, TB, AAcc));
          ({_,_Any}, AAcc) ->
           lager:info("Can't load address for tx ~p",[_Any]),
           AAcc
       end,
  Addrs=lists:foldl(Load, Addrs0, TXL),
  lager:debug("MB Pre Setting ~p", [XSettings]),
  _T3=erlang:system_time(),
  Entropy=proplists:get_value(entropy, Options, <<>>),
  MeanTime=proplists:get_value(mean_time, Options, 0),
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
                   failed=>[],
                   success=>[],
                   settings=>[],
                   outbound=>[],
                   table=>#{},
                   emit=>[],
                   fee=>bal:new(),
                   tip=>bal:new(),
                   pick_block=>#{},
                   entropy=>Entropy,
                   mean_time=>MeanTime,
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
  lager:debug("Bals before clean ~p",[NewBal0]),
  NewBal=cleanup_bals(NewBal0),
  lager:debug("Bals after clean ~p",[NewBal]),
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
  Blk=block:mkblock2(#{
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
  lager:info("Created block ~w ~s: txs: ~w, bals: ~w, LH: ~s, chain ~p temp ~p",
             [
              Parent_Height+1,
              block:blkid(maps:get(hash, Blk)),
              length(Success),
              maps:size(NewBal),
              bin2hex:dbin2hex(LedgerHash),
              GetSettings(mychain),
              proplists:get_value(temporary,Options)
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
                     C1=bal:changes(V),
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

-ifdef(TEST).
ledger_hash(NewBal, undefined) ->
  {ok, HedgerHash}=case whereis(ledger) of
                     undefined ->
                       %there is no ledger. Is it test?
                       {ok, LedgerS1}=ledger:init([test]),
                       {reply, LCResp, _LedgerS2}=ledger:handle_call({check, []}, self(), LedgerS1),
                       LCResp;
                     X when is_pid(X) ->
                       ledger:check(maps:to_list(NewBal))
                   end,
  HedgerHash;

ledger_hash(NewBal, Pid) ->
  {ok, HedgerHash}=ledger:check(Pid,maps:to_list(NewBal)),
  HedgerHash.

-else.
ledger_hash(NewBal, undefined) ->
  {ok, HedgerHash}=ledger:check(maps:to_list(NewBal)),
  HedgerHash;

ledger_hash(NewBal, Pid) ->
  {ok, HedgerHash}=ledger:check(Pid,maps:to_list(NewBal)),
  HedgerHash.

-endif.
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

return_gas(_Tx, {<<"NONE">>, _GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  Bal0;

return_gas(_Tx, {GCur, GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  lager:debug("return_gas ~p left ~b",[GCur, GAmount]),
  if(GAmount > 0) ->
      B1=bal:get_cur(GCur,Bal0),
      bal:put_cur(GCur, B1+GAmount, Bal0);
    true ->
      Bal0
  end.


settings_hash(NewSettings) when is_map(NewSettings) ->
  maphash:hash(NewSettings).
