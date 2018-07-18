-module(httpapi_playground).
-export([h/3]).
-import(tpnode_httpapi,[answer/1]).

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


