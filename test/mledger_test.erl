-module(mledger_test).
-include_lib("eunit/include/eunit.hrl").

mledger_test() ->
  Addr= <<128,1,64,0,2,0,0,1>>,
  Test=fun(_) ->
           Bals=#{Addr =>
                  #{amount => #{<<"FTT">> => 100,<<"SK">> => 10,<<"TST">> => 26},
                    state => #{ <<0>> => <<1>>, <<1>> => <<>> },
                    lstore=><<129,196,6,101,120,105,115,116,115,0>>,
                    seq => 555,
                    changes => [state, seq]
                   }
                 },

           L0=mledger:get(Addr),

           {ok, LedgerHash0}=mledger:apply_patch([],check),
           io:format("LH0 ~p~n", [LedgerHash0]),
           Patch=mledger:bals2patch(maps:to_list(Bals)),
           {ok, LedgerHash}=mledger:apply_patch(Patch,{commit,2}),
           io:format("LH1 ~p~n", [LedgerHash]),
           {ok, LedgerHash2}=mledger:apply_patch([],check),
           io:format("LH2 ~p~n", [LedgerHash2]),
           L1=mledger:get(Addr),

           io:format("~p~n",[Bals]),

           io:format("0 ~p~n", [L0]),
           io:format("1 ~p~n", [L1]),
           %io:format("L ~p~n", [mledger:get_vers(Addr)]),
           [
            ?assertEqual([], [])
           ]
       end,
  Ledger=[
          {Addr,
           #{amount => #{
               <<"FTT">> => 110,
               <<"SK">> => 10,
               <<"TST">> => 26
              },
             seq => 1,
             state => #{ <<0>> => <<0>>, <<1>> => <<1>>, <<2>> => <<1>> },
             t => 1512047425350,
             lastblk => <<0:64>>,
             lstore=><<129,196,6,101,120,105,115,116,115,1>>
            }
          }
         ],
  mledger:deploy4test(Ledger, Test).

