-module(mkblock_wasm_tests).

-include_lib("eunit/include/eunit.hrl").

extcontract_template(OurChain, TxList, Ledger, CheckFun) ->
  Test=fun(LedgerPID) ->
           GetSettings=fun(mychain) -> OurChain;
                          (settings) ->
                           #{
                             chains => [OurChain],
                             keys =>
                             #{
                               <<"node1">> => crypto:hash(sha256, <<"node1">>),
                               <<"node2">> => crypto:hash(sha256, <<"node2">>),
                               <<"node3">> => crypto:hash(sha256, <<"node3">>)
                              },
                             nodechain =>
                             #{
                               <<"node1">> => OurChain,
                               <<"node2">> => OurChain,
                               <<"node3">> => OurChain
                              },
                             <<"current">> => #{
                                 chain => #{
                                   blocktime => 5, 
                                   minsig => 2, 
                                   <<"allowempty">> => 0
                                  },
                                 <<"gas">> => #{
                                     <<"FTT">> => 10,
                                     <<"SK">> => 1000
                                    },
                                 <<"fee">> => #{
                                     params=>#{
                                       <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>>,
                                       <<"tipaddr">> => <<160, 0, 0, 0, 0, 0, 0, 2>>
                                      },
                                     <<"TST">> => #{
                                         <<"base">> => 2,
                                         <<"baseextra">> => 64,
                                         <<"kb">> => 20
                                        },
                                     <<"FTT">> => #{
                                         <<"base">> => 1,
                                         <<"baseextra">> => 64,
                                         <<"kb">> => 10
                                        }
                                    },
                                 <<"rewards">>=>#{
                                     <<"c1n1">>=><<128, 1, 64, 0, OurChain, 0, 0, 101>>,
                                     <<"c1n2">>=><<128, 1, 64, 0, OurChain, 0, 0, 102>>,
                                     <<"c1n3">>=><<128, 1, 64, 0, OurChain, 0, 0, 103>>,
                                     <<"node1">>=><<128, 1, 64, 0, OurChain, 0, 0, 101>>,
                                     <<"node2">>=><<128, 1, 64, 0, OurChain, 0, 0, 102>>,
                                     <<"node3">>=><<128, 1, 64, 0, OurChain, 0, 0, 103>>
                                    }
                                }
                            };
                          ({endless, _Address, _Cur}) ->
                           false;
                          ({valid_timestamp, TS}) ->
                           abs(os:system_time(millisecond)-TS)<3600000
                           orelse
                           abs(os:system_time(millisecond)-(TS-86400000))<3600000;
                          ({get_block, Back}) when 20>=Back ->
                           FindBlock=fun FB(H, N) ->
                           case gen_server:call(blockchain, {get_block, H}) of
                             undefined ->
                               undefined;
                             #{header:=#{parent:=P}}=Blk ->
                               if N==0 ->
                                    maps:without([bals, txs], Blk);
                                  true ->
                                    FB(P, N-1)
                               end
                           end
                       end,
           FindBlock(last, Back);
          (Other) ->
           error({bad_setting, Other})
       end,
  GetAddr=fun(Addr) ->
              case ledger:get(LedgerPID, Addr) of
                #{amount:=_}=Bal -> Bal;
                not_found -> bal:new()
              end
          end,

  ParentHash=crypto:hash(sha256, <<"parent">>),


  CheckFun(generate_block:generate_block(
             TxList
             ,
             {1, ParentHash},
             GetSettings,
             GetAddr,
             [],
             [{ledger_pid, LedgerPID}]))
  end,
  ledger:deploy4test(Ledger, Test).


extcontract_test() ->
  case catch vm:run(fun(Pid)->Pid ! {ping,self()} end,"wasm",2,[]) of
    {'EXIT', _} ->
      [];
    {error, noworkers} ->
      [];
    {ok, pong} ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Addr2=naddress:construct_public(1, OurChain, 3),
      Addr3=naddress:construct_public(1, OurChain, 5),
      {ok, Code}=file:read_file("./examples/testcontract.wasm"),
      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>deploy,
              from=>Addr1,
              seq=>2,
              t=>os:system_time(millisecond),
              payload=>[
                        #{purpose=>srcfee, amount=>200, cur=><<"FTT">>},
                        #{purpose=>gas, amount=>500, cur=><<"FTT">>}
                       ],
              call=>#{function=>"init",args=>[16]},
              txext=>#{ "code"=> Code,
                        "vm" => "wasm"
                      }
             }), Pvt1),
      TX4=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr2,
              to=>Addr1,
              cur=><<"FTT">>,
              call=>#{function=>"dec",args=>[1]},
              payload=>[
                        #{purpose=>transfer, amount=>1, cur=><<"FTT">>},
                        #{purpose=>transfer, amount=>3, cur=><<"TST">>},
                        #{purpose=>gas, amount=>10, cur=><<"TST">>}, %wont be used
                        #{purpose=>gas, amount=>3, cur=><<"SK">>}, %will be used 1
                        #{purpose=>gas, amount=>10, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>2,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TX5=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr3,
              to=>Addr1,
              cur=><<"FTT">>,
              call=>#{function=>"expensive",args=>[1]},
              payload=>[
                        #{purpose=>gas, amount=>1, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>1, cur=><<"FTT">>}
                       ],
              seq=>2,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TxList=[
              {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)},
              {<<"4testexec">>, maps:put(sigverify,#{valid=>1},TX4)},
              {<<"5willfail">>, maps:put(sigverify,#{valid=>1},TX5)}
             ],
      TestFun=fun(#{block:=Block,
                    emit:=Emit,
                    failed:=Failed}) ->
                  Success=proplists:get_keys(maps:get(txs, Block)),
                  NewCallerLedger=maps:get(amount,
                                           maps:get(
                                             Addr2,
                                             maps:get(bals, Block)
                                            )
                                          ),
                  NewSCLedger=maps:get(
                                Addr1,
                                maps:get(bals, Block)
                               ),
                  %{ Emit, NewCallerLedger }
                  io:format("Emit ~p~n",[Emit]),
                  io:format("NCL  ~p~n",[NewCallerLedger]),
                  Fee=maps:get(amount,
                               maps:get(
                                 <<160, 0, 0, 0, 0, 0, 0, 1>>,
                                 maps:get(bals, Block)
                                )
                              ),
                  io:format("Fee  ~p~n",[Fee]),
                  {ok,ContractState}=msgpack:unpack(maps:get(state, NewSCLedger)),
                  io:format("St ~s~n",[hex:encode(
                                         maps:get(<<1,1,1,1,1,1,1,1,
                                                    1,1,1,1,1,1,1,1,
                                                    1,1,1,1,1,1,1,1,
                                                    1,1,1,1,1,1,1,1>>,ContractState))]),
                  [
                   ?assertMatch([{<<"5willfail">>,insufficient_gas}],Failed),
                   ?assertMatch([<<"4testexec">>,<<"3testdeploy">>],Success),
                   ?assertMatch(<<15:256/big>>,maps:get(<<1,1,1,1,1,1,1,1,
                                                          1,1,1,1,1,1,1,1,
                                                          1,1,1,1,1,1,1,1,
                                                          1,1,1,1,1,1,1,1>>,ContractState)),
                   ?assertMatch(#{<<"TST">>:=29, <<"FTT">>:=676},maps:get(amount, NewSCLedger)),
                   ?assertMatch(#{<<"SK">>:=2, <<"FTT">>:=328},Fee)
                  ]
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {Addr2,
               #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {Addr3,
               #{amount => #{ <<"FTT">> => 10, <<"SK">> => 2, <<"TST">> => 26 }}
              }
             ],
      extcontract_template(OurChain, TxList, Ledger, TestFun)
  end.

