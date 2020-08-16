-module(lstore_test).
-include_lib("eunit/include/eunit.hrl").

lstore_test() ->
  Addr= <<128,1,64,0,2,0,0,1>>,
  Test=fun(_) ->
           GetSettings=
           fun(mychain) ->
               2;
              (settings) ->
               #{
                 chains => [2],
                 globals => #{<<"patchsigs">> => 2},
                 keys =>
                 #{ <<"node1">> => crypto:hash(sha256, <<"node1">>),
                    <<"node2">> => crypto:hash(sha256, <<"node2">>),
                    <<"node3">> => crypto:hash(sha256, <<"node3">>),
                    <<"node4">> => crypto:hash(sha256, <<"node4">>)
                  },
                 nodechain => #{<<"node1">> => 0,
                                <<"node2">> => 0,
                                <<"node3">> => 0},
                 <<"current">> => #{
                     <<"allocblock">> =>
                     #{<<"block">> => 2, <<"group">> => 10, <<"last">> => 0}
                    }
                };
              ({valid_timestamp, TS}) ->
               abs(os:system_time(millisecond)-TS)<3600000
               orelse
               abs(os:system_time(millisecond)-(TS-86400000))<3600000;
              ({endless, _Address, _Cur}) ->
               false;
              (Other) ->
               error({bad_setting, Other})
           end,
           GetAddr=fun mledger:get/1,
           ParentHash=crypto:hash(sha256, <<"parent">>),

           Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
                   240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
           T1=#{
             kind => generic,
             t => os:system_time(millisecond),
             seq => 10,
             from => Addr,
             to => <<128,1,64,0,2,0,0,2>>,
             ver => 2,
             payload => [
                         #{cur=><<"FTT">>,
                           amount=>10,
                           purpose=>transfer
                          }
                        ]
            },
           T2=#{
             kind => lstore,
             t => os:system_time(millisecond)+1,
             seq => 11,
             from => Addr,
             ver => 2,
             payload => [ ],
             patches => [
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"b">>], <<"v">>=>$b},
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"c">>], <<"v">>=>$c},
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"array">>], <<"v">>=>[1,2,3]}
                        ]
            },
           TXConstructed1=tx:sign(tx:construct_tx(T1),Pvt1),
           TXConstructed2=tx:sign(tx:construct_tx(T2),Pvt1),
           {ok,TX1}=tx:verify(TXConstructed1,[nocheck_ledger]),
           {ok,TX2}=tx:verify(TXConstructed2,[nocheck_ledger]),
           #{block:=Block,
             failed:=Failed}=generate_block:generate_block(
                               [{<<"tx1">>, TX1},
                                {<<"tx2">>, TX2}
                               ],
                               {1, ParentHash},
                               GetSettings,
                               GetAddr,
                               []),

           io:format("~p~n", [Block]),
           [
            ?assertEqual([], Failed),
            ?assertMatch(#{
               bals:=#{<<128, 1, 64, 0, 2, 0, 0, 1>>:=_}
              }, Block)
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
             t => 1512047425350,
             lastblk => <<0:64>>,
             lstore=><<129,196,6,101,120,105,115,116,115,1>>,
             changes=>[amount]
            }
          },
          {<<160,0,0,0,0,0,0,0>>,
           #{amount => #{
               <<"FTT">> => 100,
               <<"TST">> => 100
              },
             lastblk => <<0:64>>,
             changes=>[amount]
            }
          }
         ],
  mledger:deploy4test(Ledger, Test).

