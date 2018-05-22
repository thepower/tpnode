-module(genesis).
-export([genesis/0, new/1, settings/0]).

genesis() ->
    {ok, [Genesis]}=file:consult(application:get_env(tpnode,genesis,"genesis.txt")),
    Genesis.

new(HPrivKey) ->
    PrivKeys=case HPrivKey of
               [E|_] when is_list(E) ->
                 [ hex:parse(E1) || E1 <- HPrivKey];
               [E|_] when is_binary(E) ->
                 [ hex:parse(E1) || E1 <- HPrivKey];
               E1 when is_list(E1) ->
                 [hex:parse(E1)];
               E1 when is_binary(E1) ->
                 [hex:parse(E1)]
             end,
    Set0=case PrivKeys of 
           [_] ->
             settings();
           [_,_|_] ->
             settings(
               lists:map(
                 fun(Priv) ->
                     Pub=tpecdsa:calc_pub(Priv,true),
                     <<Ni:8/binary,_/binary>>=nodekey:node_id(Pub),
                     {<<"node_",Ni/binary>>,Pub}
                 end, PrivKeys)
              )
         end,
    Patch=lists:foldl(
            fun(PrivKey, Acc) ->
                settings:sign(Acc, PrivKey)
            end, Set0, PrivKeys),
    
    Blk0=block:mkblock(
           #{ parent=><<0, 0, 0, 0, 0, 0, 0, 0>>,
              height=>0,
              txs=>[],
              bals=>#{},
              settings=>[
                         {
                          bin2hex:dbin2hex(crypto:hash(md5,settings:mp(Set0))),
                          Patch
                         }
                        ],
              sign=>[]
            }),
    Genesis=lists:foldl(
              fun(PrivKey, Acc) ->
                  block:sign(
                    Acc,
                    [{timestamp, os:system_time(millisecond)}],
                    PrivKey)
              end, Blk0, PrivKeys),
    file:write_file("genesis.txt", io_lib:format("~p.~n", [Genesis])),
    {ok, Genesis}.

settings() ->
  settings(
    [
    {<<"nodeb1">>,base64:decode("AganOY4DcSMZ078U9tR9+p0PkwDzwnoKZH2SWl7Io9Xb")},
    {<<"nodeb2">>,base64:decode("AzHXdEk2GymQDUy30Q/uPefemnQloXGfAiWCpoywM7eq")},
    {<<"nodeb3">>,base64:decode("AujH2xsSnOCVJ5mtVy7MQPcCfNEEnKghX0P9V+E+Vfo/")}
    ]
   ).

settings(Keys) ->
  lists:foldl(
    fun({Name,Key},Acc) ->
        [ #{t=>set, p=>[keys,Name], v=>Key} | Acc]
    end, 
    [
     #{t=>set, p=>[<<"current">>,chain, patchsigs], v=>2},
     #{t=>set, p=>[<<"current">>,chain, minsig], v=>2},
     #{t=>set, p=>[<<"current">>,chain, blocktime], v=>2},
     #{t=>set, p=>[<<"current">>,chain, <<"allowempty">>], v=>0},
     #{t=>set, p=>[chains], v=>[1,2,3,4]},
     #{t=>set, p=>[nodechain], v=>
       lists:foldl(fun({NN,_},Acc) ->
                       maps:put(NN,4,Acc)
                   end, #{}, Keys)
      }
    ],
    Keys).

