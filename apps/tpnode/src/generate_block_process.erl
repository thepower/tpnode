-module(generate_block_process).
-include("include/tplog.hrl").
-export([try_process/2]).
-export([return_gas/3, aalloc/1, complete_tx/3]).

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

-spec try_process([{_,_}], mkblock_acc()) -> mkblock_acc().
try_process([], #{
                  settings:=Settings,
                  parent:=ParentHash,
                  height:=MyHeight,
                  new_settings:=SetState,
                  outbound:=Outbound
                 }=Acc) ->
  OutChains = lists:usort([Chain || {_, Chain} <- Outbound]),
  {SS2, Set2}=lists:foldl(
                fun(OutTo, {SS, Set}) ->
                    PatchTxID= <<"out", (xchain:pack_chid(OutTo))/binary>>,
                    ChainPath=[<<"current">>, <<"outward">>,
                               xchain:pack_chid(OutTo)],
                    SyncSet=settings:get(ChainPath, SS),
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
                            #{<<"t">> => <<"set">>, <<"p">> => ChainPath ++ [<<"parent">>], <<"v">> => ParentHash },
                            #{<<"t">> => <<"set">>, <<"p">> => ChainPath ++ [<<"height">>], <<"v">> => MyHeight }
                            |PCP ],
                    SyncPatch={PatchTxID, #{sig=>[], ver=>2, kind=>patch, patches=>IncPtr}},
                    {
                     settings:patch(SyncPatch, SS),
                     [SyncPatch|Set]
                    }
                end, {SetState, Settings}, OutChains),

  ?LOG_DEBUG("try_process finish"),
  Acc#{settings=>Set2, set_state=>SS2};

%process inbound block
try_process([{BlID, #{ hash:=BHash,
                       txs:=TxList,
                       header:=#{chain:=ChID,height:=BHeight} }=Blk}|Rest],
            #{
              new_settings:=SetState,
              get_settings:=GetFun,
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
    ?LOG_INFO("SyncState ~p", [ChainLastHei]),

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
    SyncPatch={PatchTxID, #{sig=>[], ver=>2, kind=>patch, patches=>IncPtr}},
    if P==undefined ->
         ?LOG_NOTICE("Old block without settings"),
         try_process([ {TxID,
                        Tx#{
                          origin_block_hash=>BHash,
                          origin_block_height=>BHeight,
                          origin_block=>BlID,
                          origin_chain=>ChID
                         }
                       } || {TxID, Tx} <- TxList ] ++ Rest,
                     Acc#{
                       settings=>[SyncPatch|lists:keydelete(PatchTxID, 1, Settings)]
                      });
       true ->
         IWS=settings:get([<<"current">>,<<"outward">>,xchain:pack_chid(MyChain)],settings:patch(P,#{})),
         case IWS of
           #{<<"pre_hash">> := <<0,0,0,0,0,0,0,0>>,<<"pre_height">> := 0} ->
             ?LOG_DEBUG("New inbound block from ~b with patch ~p",[ChID,IWS]),
             ok;
           #{<<"pre_hash">> := ChainLastHash,<<"pre_height">> := ChainLastHei} ->
             ?LOG_DEBUG("New inbound block from ~b with patch ~p",[ChID,IWS]),
             ok;
           #{<<"pre_hash">> := NeedHash ,<<"pre_height">> := PH} when PH>ChainLastHei ->
             ?LOG_DEBUG("New inbound block from ~b with patch ~p, skipped_block",[ChID,IWS]),
             throw({'block_skipped',NeedHash});
           #{<<"pre_hash">> := _ ,<<"pre_height">> := PH} when PH<ChainLastHei ->
             ?LOG_DEBUG("New inbound block from ~b with patch ~p, overdue",[ChID,IWS]),
             throw({'overdue',BHash});
           #{<<"pre_parent">> := _,<<"pre_height">> := LastHei} when LastHei==ChainLastHei;
                                                                     ChainLastHei==0 ->
             ?LOG_NOTICE("New inbound block with no hash, looking for parent from ~b with patch ~p",[ChID,IWS]),
             ?LOG_NOTICE("Disable this after sync all chains!!!!"),
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
                     Acc#{
                       settings => [SyncPatch|lists:keydelete(PatchTxID, 1, Settings)],
                       new_settings => SS1
                      })
    end
  catch throw:Ee ->
          ?LOG_INFO("Fail to process inbound ~p ~p", [BlID, Ee]),
          try_process(Rest, Acc#{
                              failed=>[{BlID, Ee}|Failed],
                              last => failed
                             });
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("Fail to process inbound block ~p ~p:~p",
                     [BlID, Ec, Ee]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          try_process(Rest, Acc#{
                              failed=>[{BlID, unknown}|Failed],
                              last => failed
                             })
  end;

try_process([{TxID, #{ver:=2,
                      kind:=patch,
                      patches:=[_|_]=_LPatch,
                      sigverify:=#{
                                   pubkeys:=[_|_]=PubKeys,
                                   source:=Src
                                  }
                     }=Tx} |Rest],
            #{failed:=Failed,
              new_settings:=SetState, %Addresses, GetFun,
              settings:=Settings}=Acc) ->
  try
    case Src of
      nodekeys ->
        NeedSig=chainsettings:get(patchsig,SetState),
        if(length(PubKeys)<NeedSig) ->
            throw({patchsig, NeedSig});
          true ->
            ok
        end;
      patchkeys ->
        case settings:get([<<"current">>,<<"patchkeys">>,<<"required">>],SetState) of
          NeedSig when is_integer(NeedSig), NeedSig>0 ->
            if(length(PubKeys)<NeedSig) ->
                throw({patchkeys_needsig, NeedSig});
              true ->
                ok
            end;
          true ->
            throw({patchkeys_needsig, undefined})
        end
    end,

    SS1=settings:patch({TxID, Tx}, SetState),
    ?LOG_INFO("Success Patch ~p against settings ~p", [_LPatch, SetState]),
    try_process(Rest, Acc#{
                        new_settings => SS1,
                        settings=>[{TxID, Tx}|Settings],
                        last => ok
                       }
               )
  catch throw:Ee ->
          ?LOG_INFO("Fail to Patch ~p ~p",
                     [_LPatch, Ee]),
          try_process(Rest, Acc#{
                              failed=>[{TxID, Ee}|Failed],
                              last => failed
                             });
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("Fail to Patch ~p ~p:~p against settings ~p",
                     [_LPatch, Ec, Ee, SetState]),
          ?LOG_INFO("at ~p", [S]),
          try_process(Rest, Acc#{
                              failed=>[{TxID, Tx}|Failed],
                              last => failed
                             })
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=lstore,
                      from:=Owner,
                      patches:=_
                     }=Tx} |Rest],
            #{failed:=Failed,
              table:=Addresses,
              new_settings:=SetState,
              get_settings:=GetFun,
              success:=Success}=Acc) ->
  ?LOG_INFO("Processing local ls =====[ ~s ]=======",[TxID]),
  try
    Verify=try
             #{sigverify:=#{valid:=SigValid}}=Tx,
             SigValid>0
           catch _:_ ->
                   false
           end,
    if Verify -> ok;
       true ->
         %error_?LOG_ERROR_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    Bal=maps:get(Owner, Addresses),
    {NewF, _GasF, GotFee, _Gas}=withdraw(Bal, Tx, GetFun, SetState, [nogas,notransfer]),

    NewF4=maps:remove(keep, NewF),
    Set1=mbal:get(lstore, NewF4),
    Set2=settings:patch({TxID, Tx}, Set1),
    NewF5=mbal:put(lstore, Set2, NewF4),

    NewAddresses=maps:put(Owner, NewF5, Addresses),

    try_process(Rest,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success],
                             table=>NewAddresses,
                             last => ok
                            }
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                           last => failed
                          });
        throw:X:S ->
          io:format("~s Throw  ~p at ~p/~p~n",[TxID,X,hd(S),hd(tl(S))]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, fmterr(X)}|Failed],
                           last => failed});
        error:X:S ->
          io:format("~s Error ~p at ~p/~p~n",[TxID,X,hd(S),hd(tl(S))]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, fmterr(X)}|Failed],
                           last => failed});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("LStore failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          try_process(Rest,
                      Acc#{failed=>[{TxID, other}|Failed],
                           last => failed})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=tstore,
                      from:=Owner,
                      txext:=#{}
                     }=Tx} |Rest],
            #{failed:=Failed,
              table:=Addresses,
              new_settings:=SetState,
              get_settings:=GetFun,
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
         %error_?LOG_ERROR_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    Bal=maps:get(Owner, Addresses),
    {NewF, _GasF, GotFee, _Gas}=withdraw(Bal, Tx, GetFun, SetState, [nogas,notransfer]),

    NewF4=maps:remove(keep, NewF),

    NewAddresses=maps:put(Owner, NewF4, Addresses),

    try_process(Rest,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success],
                            table => NewAddresses,
                            last => ok}
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                           last => failed});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("TStore failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          try_process(Rest,
                      Acc#{failed=>[{TxID, other}|Failed],
                           last => failed})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=deploy,
                      from:=Owner,
                      txext:=#{"code":=Code,"vm":=VMType0}=TxExt
                     }=Tx} |Rest],
            #{failed:=Failed,
              aalloc:=AAlloc,
              table:=Addresses,
              new_settings:=SetState,
              get_settings:=GetFun,
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
         %error_?LOG_ERROR_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    VMType=to_bin(VMType0),
    VM=try
         VMName= <<"contract_", VMType/binary>>,
         ?LOG_INFO("VM ~s",[VMName]),
         erlang:binary_to_existing_atom(VMName, utf8)
       catch error:badarg ->
               throw('unknown_vm')
       end,
    code:ensure_loaded(VM),
    A5=erlang:function_exported(VM,deploy,5),

    %State0=maps:get(state, Tx, <<>>),
    Bal=maps:get(Owner, Addresses),
    {NewF, GasF, GotFee, {GCur,GAmount,GRate={GNum,GDen}}=Gas}=withdraw(Bal, Tx, GetFun, SetState, []),

    try
      NewF1=mbal:put(vm, VMType, NewF),
      NewF2=mbal:put(code, Code, NewF1),
      NewF3=case maps:find("view", TxExt) of
              error -> NewF2;
              {ok, View} ->
                mbal:put(view, View, NewF2)
            end,
      ?LOG_INFO("Deploy contract ~s for ~s gas ~w",
                 [VM, naddress:encode(Owner), Gas]),
      IGas=(GAmount*GNum) div GDen,
      Left=fun(GL) ->
               ?LOG_INFO("VM run gas ~p -> ~p",[IGas,GL]),
               {GCur, (GL*GDen) div GNum, GRate}
           end,
      OpaqueState=#{aalloc=>AAlloc,
                    created=>[],
                    changed=>[],
                    get_addr=>GetAddr,
                    global_acc=>Acc,
                    log=>[],
                    entropy=>maps:get(entropy,Acc,<<>>),
                    mean_time=>maps:get(mean_time,Acc,0)
                   },
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
                             ?LOG_INFO("Deploy does not returned opaque state"),
                             {St2, Left(IGasLeft), Code1, OpaqueState};
                           {ok, #{null:="exec", "state":=St2, "gas":=IGasLeft }} ->
                             ?LOG_INFO("Deploy does not returned opaque state"),
                             {St2, Left(IGasLeft), undefined, OpaqueState};
                           {error, Error} ->
                             throw(Error);
                           _Any ->
                             ?LOG_ERROR("Deploy error ~p",[_Any]),
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

      try_process(Rest,
                  savegas(Gas, GasLeft,
                          savefee(GotFee,
                                  Acc#{
                                    success => [{TxID, Tx}|Success],
                                    table   => NewAddresses,
                                    aalloc  => AAlloc2,
                                    last => failed
                                   }
                                 )
                         ))
    catch throw:insufficient_gas=ThrowReason ->
            NewAddressesG=maps:put(Owner, GasF, Addresses),
            try_process(Rest,
                        savegas(Gas, all,
                                savefee(GotFee,
                                        Acc#{failed=> [{TxID, ThrowReason}|Failed],
                                             table => NewAddressesG,
                                             last => ok
                                            }
                                       )
                               ))
    end
  catch error:{badkey,Owner} ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                           last => failed});
        throw:X ->
          ?LOG_INFO("Contract deploy failed ~p", [X]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          %io:format("DEPLOY ERROR ~p:~p~n",[Ec,Ee]),
          ?LOG_INFO("Contract deploy failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            %io:format("@ ~p~n", [SE])
                            ?LOG_INFO("@ ~p~n", [SE])
                        end, S),
          try_process(Rest,
                      Acc#{failed=>[{TxID, other}|Failed],
                           last => failed})
  end;

try_process([{TxID, #{
                      ver:=2,
                      kind:=chkey,
                      from:=Owner,
                      t:=Timestamp,
                      seq:=Seq,
                      keys:=[NewKey|_]
                     }=Tx} |Rest],
            #{failed:=Failed,
              table:=Addresses,
              get_settings:=GetFun,
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
         throw('unverified')
    end,
    Bal=maps:get(Owner, Addresses),

    case GetFun({valid_timestamp, Timestamp}) of
      true ->
        ok;
      false ->
        throw ('invalid_timestamp')
    end,
    CurFSeq=mbal:get(seq, Bal),
    if CurFSeq < Seq -> ok;
       true ->
         ?LOG_ERROR("Bad seq addr ~p, cur ~p tx ~p",
                     [Owner, CurFSeq, Seq]),
         throw ('bad_seq')
    end,
    CurFTime=mbal:get(t, Bal),
    if CurFTime < Timestamp -> ok;
       true -> throw ('bad_timestamp')
    end,

    NewF2=mbal:put(seq, Seq,
                   mbal:put(t, Timestamp,
                            mbal:put(pubkey, NewKey, Bal)
                           )),
    NewAddresses=maps:put(Owner, NewF2, Addresses),

    try_process(Rest,
                Acc#{success=> [{TxID, Tx}|Success],
                     table => NewAddresses,
                     last => ok
                    }
               )
  catch error:{badkey,Owner} ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                           last => failed});
        throw:X ->
          ?LOG_INFO("Contract deploy failed ~p", [X]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("Contract deploy failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          try_process(Rest,
                      Acc#{failed=>[{TxID, other}|Failed],
                           last => failed})
  end;


try_process([{TxID, #{
                      ver:=2,
                      kind:=deploy,
                      from:=Owner,
                      txext:=#{"view":=NewView}
                     }=Tx} |Rest],
%            SetState, Addresses, GetFun,
            #{failed:=Failed,
              table:=Addresses,
              new_settings:=SetState,
              get_settings:=GetFun,
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
         %error_?LOG_ERROR_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    Bal=maps:get(Owner, Addresses),

    {NewF, _GasF, GotFee, Gas}=withdraw(Bal, Tx, GetFun, SetState, []),

    NewF1=maps:remove(keep,
                      mbal:put(view, NewView, NewF)
                     ),

    NewF2=return_gas(Gas, SetState, NewF1),
    NewAddresses=maps:put(Owner, NewF2, Addresses),

    try_process(Rest,
                savefee(GotFee,
                        Acc#{success=> [{TxID, Tx}|Success],
                            table => NewAddresses,
                            last => ok
                            }
                       )
               )
  catch error:{badkey,Owner} ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                           last => failed});
        throw:X ->
          ?LOG_INFO("Contract deploy failed ~p", [X]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed});
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          ?LOG_INFO("Contract deploy failed ~p:~p", [Ec,Ee]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          try_process(Rest,
                      Acc#{failed=>[{TxID, other}|Failed],
                           last => failed})
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
            #{failed:=Failed,
              table:=Addresses,
              new_settings:=SetState,
              %get_settings:=GetFun,
              aalloc:=AAl,
              success:=Success,
              settings:=_Settings }=Acc) ->
  ?LOG_NOTICE("Ensure verified"),
  try
    %TODO: multisig fix here
    RegSettings=settings:get([<<"current">>, <<"register">>], SetState),
    Diff=maps:get(<<"diff">>,RegSettings,0),
    Inv=maps:get(<<"invite">>,RegSettings,0),
    ?LOG_INFO("Expected diff ~p ~p",[Diff,Inv]),
    ?LOG_INFO("tx ~p",[Tx]),

    if Inv=/=0 ->
         Invite=maps:get(inv,Tx,<<>>),
         Invites=maps:get(<<"invites">>,RegSettings,[]),
         HI=case Inv of
              1 ->
                crypto:hash(md5,Invite);
              2 ->
                crypto:hash(sha256,Invite);
              _ ->
                throw('bad_invite_mode')
            end,
         InvFound=lists:member(HI,Invites),
         ?LOG_INFO("Inv ~p ~p",[Invite,InvFound]),
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

    ?LOG_INFO("Alloc address ~p ~s for key ~s",
               [NewBAddr,
                naddress:encode(NewBAddr),
                hex:encode(PubKey)
               ]),

    NewF=mbal:put(pubkey, PubKey, mbal:new()),
    NewAddresses=maps:put(NewBAddr, NewF, Addresses),
    NewTx=maps:remove(inv,tx:set_ext(<<"addr">>,NewBAddr,Tx)),
    ?LOG_INFO("try process register tx [~p]: ~p", [NewBAddr, NewTx]),
    try_process(Rest,
                Acc#{success => [{TxID, NewTx}|Success],
                     table  => NewAddresses,
                     aalloc => AAl1,
                     last => ok
                    })
  catch throw:X ->
          ?LOG_INFO("Address alloc fail ~p", [X]),
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed})
  end;

try_process([{TxID, #{from:=From, to:=To}=Tx} |Rest],
%            SetState, Addresses, GetFun,
            #{failed:=Failed,
              %table:=Addresses,
              new_settings:=SetState,
              get_settings:=GetFun
             }=Acc) ->
  MyChain=GetFun(mychain),
  FAddr=addrcheck(From, SetState, MyChain),
  TAddr=addrcheck(To, SetState, MyChain),
  case {FAddr, TAddr} of
    {{true, {chain, MyChain}}, {true, {chain, MyChain}}} ->
      try_process_local([{TxID, Tx}|Rest], Acc);
    {{true, {chain, MyChain}}, {true, {chain, OtherChain}}} ->
      try_process_outbound([{TxID, Tx#{
                                     outbound=>OtherChain
                                    }}|Rest],
                           Acc);
    {{true, {chain, _FromChain}}, {true, {chain, MyChain}}} ->
      try_process_inbound([{TxID,
                            maps:remove(outbound, Tx)}|Rest],
                          Acc);
    {{true, private}, {true, private}}  -> %pvt
      try_process_local([{TxID, Tx}|Rest], Acc);
    {{true, private}, {true, {chain, MyChain}}}  -> %local from pvt
      try_process_local([{TxID, Tx}|Rest], Acc);
    {{true, {chain, MyChain}}, {true, private}}  -> %local to pvt
      try_process_local([{TxID, Tx}|Rest], Acc);
    {{true, {chain, _}}, false} ->
      ?LOG_INFO("TX ~s dst addr error ~p", [TxID, TAddr]),
      try_process(Rest,
                  Acc#{failed=>[{TxID, 'bad_dst_addr'}|Failed],
                       last => failed});
    _ ->
      ?LOG_INFO("TX ~s addr error ~p -> ~p", [TxID, FAddr, TAddr]),
      try_process(Rest,
                  Acc#{failed=>[{TxID, 'bad_src_or_dst_addr'}|Failed],
                       last => failed})
  end;

try_process([{TxID, UnknownTx} |Rest],
            #{failed:=Failed}=Acc) ->
  ?LOG_INFO("Unknown TX ~p type ~p", [TxID, UnknownTx]),
  try_process(Rest, Acc#{failed=>[{TxID, 'unknown_type'}|Failed],
                         last => failed}).

try_process_inbound([{TxID,
                      #{ver:=2,
                        kind:=generic,
                        from:=From,
                        to:=To,
                        t:=T,
                        origin_block:=OriginBlock,
                        origin_block_height:=OriginHeight,
                        origin_block_hash:=OriginHash,
                        origin_chain:=ChID
                       }=Tx}
                     |Rest],
                    #{success:=Success,
                      failed:=Failed,
                      table:=Addresses,
                      new_settings:=SetState,
                      emit:=Emit,
                      outbound:=Outbound,
                      pick_block:=PickBlock}=Acc) ->
  ?LOG_INFO("Check signature once again"),
  try
    Gas=case tx:get_ext(<<"xc_gas">>, Tx) of
          undefined -> {<<"NONE">>,0,{1,1}};
          {ok, [GasCur, GasAmount]} ->
            case to_gas(#{amount=>GasAmount,cur=>GasCur},SetState) of
              {ok, G} ->
                G;
              _ ->
                {<<"NONE">>,0,{1,1}}
            end
        end,

    try
      ?LOG_INFO("Orig Block ~p", [OriginBlock]),
      {NewAddresses, NewEmit, GasLeft, Acc1, AddEd}=deposit(TxID, To, Addresses, Tx, Gas, Acc),
      %Addresses2=maps:put(To, NewT, Addresses),

      RetGas=case GasLeft of
               {_, 0, _} ->
                 false;
               {_, IGL, _} when IGL < 0 ->
                 throw('insufficient_gas');
               {Token, IGL, _} when IGL > 50 ->
                 %TODO: take this minimal return limit from somewhere
                 ?LOG_INFO("Return gas ~p to sender ~p",[{Token,IGL},From]),
                 {Token, IGL};
               _ ->
                 false
             end,
      %io:format("RetGas ~p to address ~p chain ~p~n",[RetGas, From, ChID]),

      TxExt=maps:get(extdata,Tx,#{}),
      NewExt=maps:merge(
               TxExt#{
                 <<"orig_bhei">>=>OriginHeight,
                 <<"orig_bhash">>=>OriginHash,
                 <<"orig_chain">>=>ChID
                }, maps:from_list(AddEd)
              ),
      FixTX=maps:without(
              [origin_block,origin_block_height, origin_block_hash, origin_chain],
              Tx#{extdata=>NewExt}
             ),


    case RetGas of
      false ->
         try_process(Rest,
                     savegas(Gas, all,
                             Acc1#{success=>[{TxID, FixTX}|Success],
                                   emit => Emit ++ NewEmit,
                                   table => NewAddresses,
                                   pick_block=>maps:put(OriginBlock, 1, PickBlock),
                                   last => ok
                                  })
                    );
      {Tkn, Amount} ->
         TxID2= <<TxID/binary, ":ret">>,
         Tx2=tx:construct_tx(
               #{kind=>generic,
                 ver=>2,
                 from=>To,
                 to=>From,
                 payload=>[
                           #{purpose=>transfer, cur=>Tkn, amount=>Amount }
                          ],
                 txext=>#{<<"xc_retgas">> => true},
                 seq=>0,
                 t=>T
                }),

         try_process(Rest,
                     savegas(Gas, GasLeft,
                             Acc1#{success=>[{TxID, FixTX},{TxID2, Tx2}|Success],
                                   emit => Emit ++ NewEmit,
                                   table => NewAddresses,
                                   outbound=>[{TxID2, ChID}|Outbound],
                                   pick_block=>maps:put(OriginBlock, 1, PickBlock),
                                   last => ok
                                  })
                    )
    end

    catch
      throw:insufficient_gas ->
        try_process(Rest,
                    savegas(Gas, all,
                            Acc#{failed=>[{TxID, insufficient_gas}|Failed],
                                 last => failed
                                }
                           )
                   )
    end
  catch
    throw:X ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed})
  end.

%try_process_inbound([{TxID,
%                      #{cur:=Cur, amount:=Amount, to:=To,
%                        origin_block:=OriginBlock,
%                        origin_block_height:=OriginHeight,
%                        origin_block_hash:=OriginHash,
%                        origin_chain:=ChID
%                       }=Tx}
%                     |Rest],
%                    #{success:=Success,
%                      table:=Addresses,
%                      failed:=Failed,
%                      pick_block:=PickBlock}=Acc) ->
%  TBal=maps:get(To, Addresses),
%  try
%    ?LOG_DEBUG("Orig Block ~p", [OriginBlock]),
%    if Amount >= 0 -> ok;
%       true -> throw ('bad_amount')
%    end,
%    NewTAmount=mbal:get_cur(Cur, TBal) + Amount,
%    NewT=maps:remove(keep,
%                     mbal:put_cur(
%                       Cur,
%                       NewTAmount,
%                       TBal)
%                    ),
%    NewAddresses=maps:put(To, NewT, Addresses),
%    TxExt=maps:get(extdata,Tx,#{}),
%    NewExt=TxExt#{
%             <<"orig_bhei">>=>OriginHeight,
%             <<"orig_bhash">>=>OriginHash,
%             <<"orig_chain">>=>ChID
%            },
%    FixTX=maps:without(
%            [origin_block,origin_block_height, origin_block_hash, origin_chain],
%            Tx#{extdata=>NewExt}
%           ),
%    try_process(Rest,
%                Acc#{success=>[{TxID, FixTX}|Success],
%                     table => NewAddresses,
%                     pick_block=>maps:put(OriginBlock, 1, PickBlock),
%                     last => ok
%                    })
%  catch throw:X ->
%          try_process(Rest,
%                      Acc#{failed=>[{TxID, X}|Failed],
%                           last => failed})
%  end.

try_process_outbound([{TxID,
                       #{
                         ver:=2,
                         outbound:=OutTo,
                         to:=To,
                         from:=From
                        }=Tx}
                      |Rest],
                     #{failed:=Failed,
                       success:=Success,
                       outbound:=Outbound,
                       table:=Addresses,
                       get_settings:=GetFun,
                       new_settings:=SetState
                      }=Acc) ->
  ?LOG_INFO("Processing outbound ==[ ~s ]=======",[TxID]),
  ?LOG_NOTICE("TODO:Check signature once again"),
  ?LOG_INFO("outbound to chain ~p ~p", [OutTo, To]),
  FBal=maps:get(From, Addresses),

  try
    {NewF, _GasF, GotFee, GotGas}=withdraw(FBal, Tx, GetFun, SetState, []),
    ?LOG_INFO("Got gas ~p",[GotGas]),

    NewAddresses=maps:put(From, NewF, Addresses),
    Tx1=case GotGas of
          {_,0,_} -> tx:del_ext(<<"xc_gas">>, Tx);
          {GasCur, GasAmount, _} ->
            tx:set_ext(<<"xc_gas">>, [GasCur, GasAmount], Tx)
        end,
    try_process(Rest,
                savefee(GotFee,
                        Acc#{
                          table => NewAddresses,
                          success=>[{TxID, Tx1}|Success],
                          outbound=>[{TxID, OutTo}|Outbound],
                          last => ok
                         })
               )
  catch throw:X ->
          try_process(Rest,
                      Acc#{failed=>[{TxID, X}|Failed],
                           last => failed})
  end.

try_process_local([{TxID,
                    #{to:=To, from:=From}=Tx}
                   |Rest]=TXL,
                  #{
                    table:=Addresses,
                    get_settings:=GetFun,
                    new_settings:=SetState,
                    failed:=Failed}=Acc) ->
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
         %error_?LOG_ERROR_msg("Unverified ~p",[Tx]),
         throw('unverified')
    end,

    Ext=maps:get(txext,Tx,#{}),
    BSponsor=maps:get(<<"sponsor">>,Ext,undefined),
    ?LOG_INFO("Processing local =====[ ~s ]=======",[TxID]),
    Sponsor=case BSponsor of
              [<<SpAddr:8/binary>>] ->
                MyChain=GetFun(mychain),
                {true,{chain,SChain}}=addrcheck(SpAddr, SetState, MyChain),
                if(SChain==MyChain) ->
                    SpAddr;
                  true ->
                    false
                end;
              undefined -> false;
              Other ->
                ?LOG_ERROR("Invalid sponsor ~p",[Other]),
                throw('invalid_sponsor')
            end,
    RSp=if is_binary(Sponsor) ->
         case maps:is_key(Sponsor, Addresses) of
           false ->
             {false,no_loaded};
           true ->
             SPAcc=maps:get(Sponsor, Addresses),
             IsSponsor=ask_if_sponsor(SPAcc),
             case IsSponsor of
               {true, {Token, Amount}} ->
                 case to_gas(#{amount=>Amount, cur=>Token}, SetState) of
                   {ok, {_Tkn,TknAm,{Num,Den}}} ->
                     ?LOG_NOTICE("fixme: save gas here"),
                     ask_if_wants_to_pay(SPAcc, Tx, (TknAm*Num) div Den);
                   _ ->
                     {false, invalid_gas_specified}
                 end;
               _ ->
                 {false, no_sponsor}
             end
         end;
       true ->
         false
    end,
    case RSp of
      {ok, SPData} ->
        ?LOG_INFO("sponsoring ~p from ~p",[SPData,Sponsor]);
      {false,N} when is_binary(Sponsor) ->
        ?LOG_NOTICE("not sponsoring from ~p: ~p",[Sponsor,N]);
      _ ->
        ok
    end,

    {Addresses1,GasF,GasAddr,GotFee,Gas}=case RSp of
                 {ok, SPData1} ->
                   OrigF=maps:get(From, Addresses),
                   {NewF1, _GasF1, _GotFee1, _Gas1}=withdraw(OrigF, Tx, GetFun, SetState, []),
                   Addresses_tmp=maps:put(From, NewF1, Addresses),

                   OrigF2=maps:get(Sponsor, Addresses_tmp),
                   {NewF2, GasF2, GotFee2, Gas2}=withdraw(OrigF2,
                                                          Tx#{payload=>SPData1},
                                                          GetFun,
                                                          SetState,
                                                          [sponsor,notransfer]),
                   {maps:put(Sponsor, NewF2, Addresses_tmp),
                    GasF2, Sponsor, GotFee2, Gas2};
                 _ ->
                   OrigF=maps:get(From, Addresses),
                   {NewF, GasF1, GotFee1, Gas1}=withdraw(OrigF, Tx, GetFun, SetState, []),
                   {maps:put(From, NewF, Addresses),GasF1,From,GotFee1,Gas1}
               end,

    try
      {Addresses2, NewEmit, GasLeft, Acc1, AddEd}=deposit(TxID, To, Addresses1,
                                                   Tx, Gas, Acc),
      ?LOG_INFO("Local gas ~p -> ~p f ~p t ~p",[Gas, GasLeft, From, To]),

      NewAddresses=case GasLeft of
                     {_, 0, _} ->
                       Addresses2;
                     {_, IGL, _} when IGL < 0 ->
                       throw('insufficient_gas');
                     {_, IGL, _} when IGL > 0 ->
                       Bal0=maps:get(From, Addresses2),
                       Bal1=return_gas(GasLeft, SetState, Bal0),
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
      Tx2=lists:foldl(
            fun({K,V},A) ->
                tx:set_ext( K, V, A)
            end, Tx1, AddEd),

      #{success:=Success, emit:=Emit} = Acc1,

      Acc2=Acc1#{
        success=>[{TxID, Tx2}|Success],
        table => NewAddresses,
        emit=>Emit ++ NewEmit
       },
      Acc3=savegas(Gas, GasLeft, savefee(GotFee, Acc2)),

      try_process(Rest, Acc3#{last => ok})
    catch
      throw:insufficient_gas ->
        AddressesWoGas=maps:put(GasAddr, GasF, Addresses),
        try_process(Rest,
                    savegas(Gas, all,
                            savefee(GotFee,
                                    Acc#{failed=>[{TxID, insufficient_gas}|Failed],
                                         table => AddressesWoGas,
                                         last => failed
                                        }
                                   )
                           )
                   )
    end
  catch
    error:{badkey,From} ->
      try_process(Rest,
                  Acc#{failed=>[{TxID, no_src_addr_loaded}|Failed],
                       last => failed});
    error:{badkey,To} ->
      %try_process(Rest,
      %            Acc#{failed=>[{TxID, no_dst_addr_loaded}|Failed]});
      Load=maps:get(loadaddr, Acc),
      try_process(TXL, Acc#{table=>Load({TxID,Tx}, Addresses)});
    throw:X:S ->
      io:format("~s throw ~p at ~p/~p~n",[TxID,X,hd(S),hd(tl(S))]),
      try_process(Rest,
                  Acc#{failed=>[{TxID, fmterr(X)}|Failed],
                       last => failed});
    error:X:S ->
      io:format("~s Error ~p at ~p/~p~n",[TxID,X,hd(S),hd(tl(S))]),
      try_process(Rest,
                  Acc#{failed=>[{TxID, fmterr(X)}|Failed],
                       last => failed})
  end.

savegas({Cur, Amount1, Rate1}, all, Acc) ->
  savegas({Cur, Amount1, Rate1}, {Cur, 0, Rate1}, Acc);

savegas({Cur, Amount1, _}, {Cur, Amount2, _}, #{fee:=FeeBal}=Acc) ->
  %io:format("save gas ~s ~w-~w=~w ~n",[Cur,Amount1, Amount2,Amount1-Amount2]),
  ?LOG_INFO("save gas ~s ~w ~w",[Cur,Amount1, Amount2]),
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
  %io:format("save fee  ~s ~w ~w~n",[Cur,Fee,Tip]),
  Acc#{
    fee=>mbal:put_cur(Cur, Fee+mbal:get_cur(Cur, FeeBal), FeeBal),
    tip=>mbal:put_cur(Cur, Tip+mbal:get_cur(Cur, TipBal), TipBal)
   }.

gas_plus_int({Cur,Amount, {R1,R2}}, Int, true) ->
  {Cur, trunc(Amount+((Int*R1) div R2)), {R1,R2}}.

is_gas_left({_,Amount,_Rate}) ->
  Amount>0.

deposit(TxID, Address, Addresses0, #{ver:=2}=Tx, GasLimit,
        #{
          aalloc:=AAlloc,
          get_addr:=GetAddr,
          get_settings:=GetFun,
          new_settings:=SetState,
          log:=Logs
         }=Acc) ->
  TBal0=maps:get(Address,Addresses0),
  NewT=maps:remove(keep,
                   lists:foldl(
                     fun(#{amount:=Amount, cur:= Cur}, TBal) ->
                         NewTAmount=mbal:get_cur(Cur, TBal) + Amount,
                         mbal:put_cur( Cur, NewTAmount, TBal)
                     end, TBal0, tx:get_payloads(Tx,transfer))),
  Addresses=maps:put(Address,NewT,Addresses0),
  case {maps:is_key(norun,Tx),mbal:get(vm, NewT)} of
    {true,_} ->
      {Addresses, [], GasLimit, Acc#{table=>Addresses}, []};
    {_,undefined} ->
      {Addresses, [], GasLimit, Acc#{table=>Addresses}, []};
    {false,VMType} ->
      FreeGas=case settings:get([<<"current">>, <<"freegas">>], SetState) of
                N when is_integer(N), N>0 -> N;
                _ -> 0
              end,
      ?LOG_INFO("Smartcontract ~p gas ~p free gas ~p", [VMType, GasLimit, FreeGas]),
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
      OpaqueState=#{aalloc=>AAlloc,
                    created=>[],
                    changed=>[],
                    get_addr=>GetAddr1,
                    global_acc=>Acc#{table=>Addresses},
                    entropy=>maps:get(entropy,Acc,<<>>),
                    mean_time=>maps:get(mean_time,Acc,0),
                    log=>[]
                   },

      GetFun1 = fun ({settings, Path}) ->
                      settings:get(Path, SetState);
                    ({lstore,ReqAddr,Path}) ->
                      UBal=case maps:is_key(ReqAddr,Addresses) of
                             true ->
                               maps:get(ReqAddr, Addresses);
                             false ->
                               GetAddr(ReqAddr)
                           end,
                      LStore=mbal:get(lstore,UBal),
                      settings:get(Path, LStore);
                    ({addr,ReqAddr,code}) ->
                      case maps:is_key(ReqAddr,Addresses) of
                        true ->
                          mbal:get(code,maps:get(ReqAddr, Addresses));
                        false ->
                          mbal:get(code,GetAddr(ReqAddr))
                      end;
                    ({addr,ReqAddr,storage,Key}=Request) ->
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
           ?LOG_INFO("Run with free gas ~p+~p=~p",
                      [GasLimit,FreeGas,GasWithFree]),
           {L1x,TXsx,GasLeftx,OpaqueState2a} =
           smartcontract:run(VMType, Tx, NewT, GasWithFree, GetFun1, OpaqueState),

           TakenFree=gas_plus_int(GasLeftx,-FreeGas,true),
           case is_gas_left(TakenFree) of
             true ->
               ?LOG_INFO("Gas left ~p, take back free gas and return ~p",
                          [GasLeftx,TakenFree]),
               {L1x,TXsx,TakenFree,OpaqueState2a};
             false ->
               ?LOG_INFO("Gas left ~p, return nothing",[GasLeftx]),
               {L1x,TXsx,{<<"NONE">>,0,{1,1}},OpaqueState2a}
           end;
         true ->
           smartcontract:run(VMType, Tx, NewT, GasLimit, GetFun1, OpaqueState)
      end,
      %io:format("Gas1 ~p left ~p free ~p~n",[GasLimit,GasLeft,FreeGas]),
      %io:format("<> Opaque2 ~p~n",[OpaqueState2]),
      true=is_list(LedgerPatches),

      #{aalloc:=AAlloc2,
        created:=Created,
        changed:=Changes,
        global_acc:=Acc2,
        log:=EmitLog0
       }=OpaqueState2,

      EmitLog = [ msgpack:pack([TxID|LL]) || LL <- EmitLog0 ],
      #{table:=Addresses1}=Acc2,
      EmitTxs=lists:map(
                fun(ETxBody) ->
                   complete_tx(ETxBody, Address, Acc2)
                end, TXs),
      Addresses2=lists:foldl(
                   fun(Addr1,AddrAcc) ->
                       %io:format("Put ~p into ~p~n",[maps:get(Addr1,OpaqueState2,undefined), Addr1]),
                       maps:put(Addr1,maps:get(Addr1,OpaqueState2,#{}),AddrAcc)
                   end, Addresses1, Created),
      Addresses3=lists:foldl(
                   fun({{Addr1,mergestate},Data},AddrAcc) ->
                       %io:format("Merge state for ~p~n",[Addr1]),
                       MBal0=case maps:is_key(Addr1,AddrAcc) of
                              true ->
                                maps:get(Addr1,AddrAcc);
                              false ->
                                 GetAddr(Addr1)
                            end,
                       MBal1=mbal:put(mergestate,Data,MBal0),
                       maps:put(Addr1,MBal1,AddrAcc);
                      (_Any,AddrAcc) ->
                        ?LOG_NOTICE("Ignore patch from VM ~p",[_Any]),
                        %io:format("ignore patch ~p~n",[_Any]),
                        AddrAcc
                   end, Addresses2, Changes),
      LToPatch=maps:get(Address, Addresses3),
      Addresses4=maps:put(Address, mbal:patch(LedgerPatches,LToPatch), Addresses3),
      AddED=case maps:get("return",OpaqueState2,undefined) of
         <<Int:256/big>> when Int < 16#10000000000000000 ->
           [{<<"retval">>, Int}];
         <<Bin:32/big>> ->
           [{<<"retval">>, Bin}];
         RetVal when is_binary(RetVal) ->
           [{<<"retval">>, <<"other">>}];
         undefined ->
           case maps:get("revert",OpaqueState2,undefined) of
             <<16#08C379A0:32/big,
               16#20:256/big,
               Len:256/big,
               Str:Len/binary,_/binary>> when 32>=Len ->
               [{<<"revert">>, Str}];
             Revert when is_binary(Revert) ->
               [{<<"revert">>, <<"other">>}];
             undefined ->
               []
           end
       end,
      {Addresses4,
       EmitTxs,
       GasLeft,
       Acc2#{aalloc=>AAlloc2, log=>EmitLog++Logs},
       AddED
      }
  end.

withdraw(FBal0,
         #{ver:=2, seq:=Seq, t:=Timestamp, from:=From}=Tx,
         GetFun, Settings, Opts) ->
  try
    Sponsor = lists:member(sponsor,Opts),
    Contract_Issued=tx:get_ext(<<"contract_issued">>, Tx),
    IsContract=is_binary(mbal:get(vm, FBal0)) andalso Contract_Issued=={ok, From},

    ?LOG_INFO("Withdraw ~p ~p", [IsContract, maps:without([body,sig],Tx)]),
    if Timestamp==0 andalso IsContract ->
         ok;
       Sponsor==true -> ok;
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
       Sponsor==true -> ok;
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
              ?LOG_DEBUG("usk ~p SK ~p",[FSKUsed,FSK]),
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
       Sponsor==true -> ok;
       Seq==0 andalso IsContract -> ok;
       true ->
         %==== DEBUG CODE
         L=try
             mledger:get(From)
           catch _:_ ->
                   cant_get_ledger
           end,
         ?LOG_ERROR("Bad seq addr ~p, cur ~p tx ~p, ledger ~p",
                     [From, CurFSeq, Seq, L]),
         %==== END DEBU CODE
         throw ('bad_seq')
    end,
    CurFTime=mbal:get(t, FBal0),
    if CurFTime < Timestamp -> ok;
       IsContract andalso Timestamp==0 -> ok;
       Sponsor==true -> ok;
       true -> throw ('bad_timestamp')
    end,

    NoTakeFee = lists:member(nofee,Opts),
    {ForFee,GotFee}=if IsContract ->
                         {[],{<<"NONE">>,0,1}};
                       NoTakeFee ->
                         {[],{<<"NONE">>,0,1}};
                       true ->
                         GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
                                       settings:get([
                                                     <<"current">>,
                                                     <<"fee">>,
                                                     FeeCur], Settings);
                                       ({params, Parameter}) ->
                                       settings:get([<<"current">>,
                                                     <<"fee">>,
                                                     <<"params">>,
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
                         {[], {<<"NONE">>,0,{1,1}}};
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
                           end, {[], {<<"NONE">>,0,{1,1}}},
                           tx:get_payloads(Tx,gas)
                          )
                     end,
    ?LOG_INFO("Fee ~p Gas ~p", [GotFee,GotGas]),

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
                      if Sponsor==true -> FBal0;
                         true ->
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
                            )
                      end),
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
          ?LOG_ERROR("Withdrawal error ~p tx ~p",[Ee,Tx]),
          lists:foreach(fun(SE) ->
                            ?LOG_ERROR("@ ~p", [SE])
                        end, S),
          throw('unknown_withdrawal_error')
  end.


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
to_bin(List) when is_list(List) -> list_to_binary(List);
to_bin(Bin) when is_binary(Bin) -> Bin.

to_gas(#{amount:=A, cur:=C}, Settings) ->
  Path=[<<"current">>, <<"gas">>, C],
  case settings:get(Path, Settings) of
    #{<<"tokens">> := T, <<"gas">> := G} when is_integer(T),
                                              is_integer(G) ->
      {ok, {C, A, {G,T}}};
    I when is_integer(I) ->
      {ok, {C, A, {I,1}}};
    _ ->
      error
  end.

return_gas({<<"NONE">>, _GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  Bal0;

return_gas({GCur, GAmount, _GRate}=_GasLeft, _Settings, Bal0) ->
  %io:format("return_gas ~p left ~b~n",[GCur, GAmount]),
  if(GAmount > 0) ->
      B1=mbal:get_cur(GCur,Bal0),
      mbal:put_cur(GCur, B1+GAmount, Bal0);
    true ->
      Bal0
  end.

addrcheck(Addr, Set, OC) ->
  case naddress:check(Addr) of
    {true, #{type:=public}} ->
      case address_db:lookup(Addr) of
        {ok, Chain} when Chain==OC->
              {true, {chain, Chain}};
        {ok, Chain} ->
          Valid=maps:get(<<"chains">>,Set,[]),
          case lists:member(Chain,Valid) of
            true ->
              {true, {chain, Chain}};
            false ->
              unroutable
          end;
        _ ->
          unroutable
      end;
    {true, #{type:=private}} ->
      {true, private};
    _ ->
      bad_address
  end.

complete_tx(ETxBody,
            Address,
            #{height:=Hei, parent:=Parent} = _Acc) ->
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
  }.

ask_if_sponsor(#{vm:= <<"evm">>, code:= Code}) ->
  contract_evm:ask_if_sponsor(Code);
ask_if_sponsor(_) ->
  false.

ask_if_wants_to_pay(#{vm:= <<"evm">>, code:= Code},Tx,G) ->
  contract_evm:ask_if_wants_to_pay(Code, Tx, G);
ask_if_wants_to_pay(_,_,G) ->
  {[],G}.

