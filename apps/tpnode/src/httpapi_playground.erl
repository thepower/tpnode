-module(httpapi_playground).
-export([h/3]).
-import(tpnode_httpapi,[answer/1, answer/2]).

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};

h(<<"GET">>, [<<"tx">>,<<"construct">>], _Req) ->
  answer(#{
    result => <<"ok">>,
    text => <<"POST here tx">>,
    example => #{
      kind => generic,
      from => naddress:encode(naddress:construct_public(1,2,3)),
      payload =>
      [#{amount => 10,cur => <<"TEST">>,purpose => transfer},
       #{amount => 1,cur => <<"TEST">>,purpose => srcfee}],
      seq => 1,
      t => 1512450000,
      to => naddress:encode(naddress:construct_public(1,2,3)),
      txext => #{
        message=><<"preved12345678901234567890123456789123456789">>
       },
      ver => 2
     }
   });

h(<<"POST">>, [<<"tx">>,<<"validate">>], Req) ->
  #{<<"tx">>:=B64Tx}=apixiom:bodyjs(Req),
  Bin=case B64Tx of
        <<"0x",Hex/binary>> -> hex:decode(Hex);
        _ -> base64:decode(B64Tx)
      end,
  Res0=#{
    dcontainer => tx_visualizer:show(Bin)
   },

  Res1=try
         {ok,#{"body":=Body}}=msgpack:unpack(Bin),
         Res0#{
           dtx => tx_visualizer:show(Body)
          }
  catch Ec:Ee ->
          Res0#{
            dtx_error=>iolist_to_binary(io_lib:format("body can't be parsed ~p:~p",[Ec,Ee]))
           }
       end,
  Res2=try
         #{body:=_}=Tx=tx:unpack(Bin),
         Res1#{
           tx=>Tx
          }
       catch Ec1:Ee1 ->
               Res1#{
                 tx_error=><<"transaction can't be parsed">>,
                 ec=>Ec1,
                 ee=>iolist_to_binary(io_lib:format("~p",[Ee1]))
                }
       end,
  BinPacker=tpnode_httpapi:packer(Req,hex),
  Res3=try
        T=maps:get(tx,Res2),
        case tx:verify(T, ['nocheck_ledger']) of
          {ok, V} -> 
            Res2#{
              verify=>tpnode_httpapi:prettify_tx(V,BinPacker)
             };
          {error, Any} -> 
            Res2#{
              verify_error=>true,
              verify=>tpnode_httpapi:prettify_tx(Any,BinPacker)
             }
        end
      catch _:_ ->
              Res2#{
                verify_error=><<"transaction can't be verified">> 
               }
      end,
  Res=maps:put(tx,tpnode_httpapi:prettify_tx(maps:get(tx,Res3,#{}),BinPacker),Res3),
  EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
          Conf1=jsx_config:list_to_config(Conf),
          jsx_parser:resume([{Type, hex:encode(Str)}|Tokens],
                            State, Handler, Stack, Conf1)
      end,
  maps:fold(
    fun(K,V,_) ->
        logger:info("~s Res ~p",[K,V]),
        logger:info("~s Res ~s",[K,jsx:encode(V)])
    end, [], Res),
  tpnode_httpapi:answer(Res,
         #{jsx=>[ strict, {error_handler, EHF} ]}
        );

h(<<"POST">>, [<<"tx">>,<<"construct">>], Req) ->
  Body=apixiom:bodyjs(Req),
  Packer=fun(Bin) -> base64:encode(Bin) end,
  try
    Body1=maps:fold(
            fun(<<"from">>,Addr,Acc) ->
                maps:put(from,naddress:decode(Addr),Acc);
               (<<"to">>,Addr,Acc) ->
                maps:put(to,naddress:decode(Addr),Acc);
               (<<"kind">>,Kind,Acc) ->
                case lists:member(Kind,[<<"generic">>,<<"register">>]) of
                  true ->
                    maps:put(kind,erlang:binary_to_atom(Kind,utf8),Acc);
                  false ->
                    throw({tx,<<"Bad kind">>})
                end;
               (<<"payload">>,Val,Acc) ->
                maps:put(payload,
                         lists:map(
                           fun(Purpose) ->
                               maps:fold(
                                 fun(<<"purpose">>,V,A) ->
                                     maps:put(purpose,b2a(V,
                                                          [
                                                           <<"srcfee">>,
                                                           <<"transfer">>
                                                          ]
                                                         ),A);
                                    (K,V,A) ->
                                     maps:put(b2a(K),V,A)
                                 end,#{}, Purpose)
                           end, Val),Acc);
               (Key,Val,Acc) ->
                maps:put(b2a(Key),Val,Acc)
            end, #{}, Body),
    #{body:=TxBody}=Tx=tx:construct_tx(Body1),
  answer(#{
    result => <<"ok">>,
    dtx =>tx_visualizer:show(TxBody),
    tx=>tpnode_httpapi:prettify_tx(
          Tx,
          Packer),
    ptx=>base64:encode(tx:pack(Tx))
   })
  catch throw:{tx,Reason} ->
          answer(#{
            result => <<"error">>,
            reason => Reason
           })
  end;

h(<<"GET">>, [<<"miner">>, TAddr], _Req) ->
  answer(
    #{
    result => <<"ok">>,
    mined => naddress:mine(binary_to_integer(TAddr))
   }).

b2a(Bin) ->
  Known=[
         <<"seq">>,
         <<"t">>,
         <<"amount">>,
         <<"register">>,
         <<"generic">>,
         <<"cur">>,
         <<"ver">>
        ],
  b2a(Bin,Known).

b2a(Bin,Known) ->
  case lists:member(Bin,Known) of
    true ->
      erlang:binary_to_atom(Bin,utf8);
    false ->
      Bin
  end.


