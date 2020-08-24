-module(mkblock_cont_tests).

-include_lib("eunit/include/eunit.hrl").

ledgersum(Ledger) when is_list(Ledger) ->
  lists:foldl(
    fun({_Addr, #{amount:=A}},Acc) ->
        maps:fold(
          fun(Cur, Val, Ac1) ->
              maps:put(Cur,maps:get(Cur,Ac1,0)+Val,Ac1)
          end, Acc, A)
    end, #{}, Ledger);

ledgersum(Ledger) when is_map(Ledger) ->
  maps:fold(
    fun(_Addr, #{amount:=A},Acc) ->
        maps:fold(
          fun(Cur, Val, Ac1) ->
              maps:put(Cur,maps:get(Cur,Ac1,0)+Val,Ac1)
          end, Acc, A)
    end, #{}, Ledger).

allocport() ->
  {ok,S}=gen_tcp:listen(0,[]),
  {ok,{_,CPort}}=inet:sockname(S),
  gen_tcp:close(S),
  CPort.

extcontract_template(OurChain, TxList, Ledger, CheckFun, Workers) ->
  Servers=case whereis(tpnode_vmsrv) of 
            undefined ->
              Port=allocport(),
              application:ensure_all_started(ranch),
              {ok, Pid1} = tpnode_vmsrv:start_link(),
              {ok, Pid2} = ranch_listener_sup:start_link(
                             {vm_listener,Port},
                             10,
                             ranch_tcp,
                             [{port,Port},{max_connections,128}],
                             tpnode_vmproto,[]),
              timer:sleep(300),
              [fun()->gen_server:stop(Pid1) end,
               fun()->exit(Pid2,normal) end
               | [ 
                  begin
                    SPid=vm_erltest:run("127.0.0.1",Port),
                    fun()->SPid ! stop end
                  end || _ <- lists:seq(1,Workers) ] 
              ];
            _ -> 
              VMPort=application:get_env(tpnode,vmport,50050),
              [ 
               begin
                 SPid=vm_erltest:run("127.0.0.1",VMPort),
                 fun()->SPid ! stop end
               end || _ <- lists:seq(1,Workers) ]
          end,
  timer:sleep(200),
  try
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
                             case blockchain:rel(H, self) of
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
                case mledger:get(Addr) of
                  #{amount:=_}=Bal -> Bal;
                  undefined -> mbal:new()
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

  mledger:deploy4test(Ledger, Test)

after
  lists:foreach(
    fun(TermFun) ->
        TermFun()
    end, Servers)
  end.

extcontract_baddeploy1_test() ->
  OurChain=150,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr1=naddress:construct_public(1, OurChain, 1),
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX3=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>Addr1,
          seq=>2,
          t=>os:system_time(millisecond),
          payload=>[
                    #{purpose=>gas, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>20, cur=><<"FTT">>}
                   ],
          call=>#{function=>"init",args=>[1024]},
          txext=>#{ "code"=> Code,
                    "vm" => "erltest"
                  }
         }), Pvt1),
  TxList=[ {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)} ],
  Ledger=[ {Addr1, #{amount => #{ <<"FTT">> => 100, <<"SK">> => 100 }} } ],
  TestFun=fun(#{block:=Block,
                emit:=_Emit,
                failed:=Failed}) ->
              Fee=maps:get(amount,
                           maps:get(
                             <<160, 0, 0, 0, 0, 0, 0, 1>>,
                             maps:get(bals, Block)
                            )
                          ),
              Sum1=ledgersum(Ledger),
              Sum2=ledgersum(maps:get(bals, Block)),
              [
               ?assertEqual(Sum1,Sum2),
               ?assertMatch([{<<"3testdeploy">>,noworkers}],Failed),
               ?assertEqual(#{},Fee)
              ]
          end,
  extcontract_template(OurChain, TxList, Ledger, TestFun, 0).


extcontract_baddeploy2_test() ->
  OurChain=150,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr1=naddress:construct_public(1, OurChain, 1),
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX3=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>Addr1,
          seq=>2,
          t=>os:system_time(millisecond),
          payload=>[
                    #{purpose=>gas, amount=>6, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>14, cur=><<"FTT">>}
                   ],
          call=>#{function=>"expensive",args=>[1024]},
          txext=>#{ "code"=> Code,
                    "vm" => "erltest"
                  }
         }), Pvt1),
  TxList=[ {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)} ],
  Ledger=[ {Addr1, #{amount => #{ <<"FTT">> => 100, <<"SK">> => 100 }} } ],
  TestFun=fun(#{block:=#{bals:=Bals}=Block,
                failed:=Failed}) ->
%              io:format("Fail ~p~n",[Failed]),
              Fee=maps:get(amount,
                           maps:get(
                             <<160, 0, 0, 0, 0, 0, 0, 1>>,
                             maps:get(bals, Block)
                            )
                          ),
%              io:format("Bals ~p~n",[ maps:map( fun(_,#{amount:=V}) -> V end, Bals)]),
%              io:format("~p~n",[maps:get(Addr1,Bals)]),
              Sum1=ledgersum(Ledger),
              Sum2=ledgersum(Bals),
              [
               ?assertEqual(Sum1,Sum2),
               ?assertMatch([{<<"3testdeploy">>,insufficient_gas}],Failed),
               ?assertEqual(#{<<"FTT">>=>20},Fee)
              ]
          end,
  extcontract_template(OurChain, TxList, Ledger, TestFun, 1).


extcontract_deploy_test() ->
  OurChain=150,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr1=naddress:construct_public(1, OurChain, 1),
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX3=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>Addr1,
          seq=>2,
          t=>os:system_time(millisecond),
          payload=>[
                    #{purpose=>gas, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>20, cur=><<"FTT">>}
                   ],
          call=>#{function=>"init",args=>[512]},
          txext=>#{ "code"=> Code,
                    "vm" => "erltest"
                  }
         }), Pvt1),
  TxList=[
          {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)}
         ],
  Ledger=[
          {Addr1,
           #{amount => #{ <<"FTT">> => 100, <<"SK">> => 100 }}
          }
         ],
  TestFun=fun(#{block:=#{bals:=Bals}=Block,
                failed:=_Failed}) ->
%              Success=proplists:get_keys(maps:get(txs, Block)),
              NewSCLedger=maps:get(
                            Addr1,
                            maps:get(bals, Block)
                           ),
              Fee=maps:get(amount,
                           maps:get(
                             <<160, 0, 0, 0, 0, 0, 0, 1>>,
                             maps:get(bals, Block)
                            )
                          ),
%              io:format("Fee  ~p~n",[Fee]),
%              io:format("Bals ~p~n",[ maps:map( fun(_,#{amount:=V}) -> V end, Bals)]),
              Sum1=ledgersum(Ledger),
              Sum2=ledgersum(Bals),
              [
               ?assertEqual(Sum1,Sum2),
               ?assertMatch(<<512:64/big>>,maps:get(state, NewSCLedger)),
               ?assertMatch(#{<<"FTT">>:=100-15},maps:get(amount, NewSCLedger)),
               ?assertMatch(#{<<"FTT">>:=15},Fee)
              ]
          end,
  extcontract_template(OurChain, TxList, Ledger, TestFun, 1).

extcontract_test() ->
  OurChain=150,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr1=naddress:construct_public(1, OurChain, 1),
  Addr2=naddress:construct_public(1, OurChain, 3),
  Addr3=naddress:construct_public(1, OurChain, 5),
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX3=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>Addr1,
          seq=>2,
          t=>os:system_time(millisecond),
          payload=>[
                    #{purpose=>gas, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>20, cur=><<"FTT">>}
                   ],
          call=>#{function=>"init",args=>[1024]},
          txext=>#{ "code"=> Code,
                    "vm" => "erltest"
                  }
         }), Pvt1),
  TX4=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>generic,
          from=>Addr2,
          to=>Addr1,
          cur=><<"FTT">>,
          call=>#{function=>"dec",args=>[512]},
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
          call=>#{function=>"expensive",args=>[512]},
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
  Ledger=[
          {Addr1,
           #{amount => #{ <<"FTT">> => 100, <<"SK">> => 3, <<"TST">> => 26 }}
          },
          {Addr2,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
          },
          {Addr3,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 2, <<"TST">> => 26 }}
          }
         ],  
  TestFun=fun(#{block:=#{bals:=Bals}=Block,
                %emit:=Emit,
                failed:=Failed}) ->
              Success=proplists:get_keys(maps:get(txs, Block)),
              NewSCLedger=maps:get(
                            Addr1,
                            maps:get(bals, Block)
                           ),
              Fee=maps:get(amount,
                           maps:get(
                             <<160, 0, 0, 0, 0, 0, 0, 1>>,
                             maps:get(bals, Block)
                            )
                          ),
              io:format("Fee  ~p~n",[Fee]),
              Sum1=ledgersum(Ledger),
              Sum2=ledgersum(Bals),
              [
               ?assertEqual(Sum1,Sum2),
               ?assertMatch([{<<"5willfail">>,insufficient_gas}],Failed),
               ?assertMatch([<<"4testexec">>,<<"3testdeploy">>],Success),
               ?assertMatch(<<512:64/big>>,maps:get(state, NewSCLedger)),
               ?assertMatch(#{<<"SK">>:=1, <<"FTT">>:=18},Fee)
              ]
          end,

  extcontract_template(OurChain, TxList, Ledger, TestFun, 1).

xchain_test_callingblock() ->
  Chain1=1,
  Chain2=20,
  Addr1=naddress:construct_public(1, Chain1, 1),
  Addr2=naddress:construct_public(1, Chain2, 3),
  Addr3=naddress:construct_public(1, Chain2, 5),
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  TX4=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>generic,
          from=>Addr2,
          to=>Addr1,
          cur=><<"FTT">>,
          call=>#{function=>"dec",args=>[512]},
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
          call=>#{function=>"expensive",args=>[256]},
          payload=>[
                    #{purpose=>gas, amount=>1, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>1, cur=><<"FTT">>}
                   ],
          seq=>2,
          t=>os:system_time(millisecond)
         }), Pvt1),

  TxList=[
           {<<"4testexec">>, maps:put(sigverify,#{valid=>1},TX4)},
           {<<"5willfail">>, maps:put(sigverify,#{valid=>1},TX5)}
          ],
  Ledger=[
          {Addr2,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
          },
          {Addr3,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
          }
         ],
  Test=fun(LedgerPID) ->
           GetSettings=fun(mychain) -> Chain2;
                          (settings) ->
                           #{
                             chains => [1,Chain2],
                             keys =>
                             #{
                               <<"node1">> => crypto:hash(sha256, <<"node1">>),
                               <<"node2">> => crypto:hash(sha256, <<"node2">>),
                               <<"node3">> => crypto:hash(sha256, <<"node3">>)
                              },
                             nodechain =>
                             #{
                               <<"node1">> => Chain2,
                               <<"node2">> => Chain2,
                               <<"node3">> => Chain2
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
                                     <<"c1n1">>=><<128, 1, 64, 0, Chain2, 0, 0, 101>>,
                                     <<"c1n2">>=><<128, 1, 64, 0, Chain2, 0, 0, 102>>,
                                     <<"c1n3">>=><<128, 1, 64, 0, Chain2, 0, 0, 103>>,
                                     <<"node1">>=><<128, 1, 64, 0, Chain2, 0, 0, 101>>,
                                     <<"node2">>=><<128, 1, 64, 0, Chain2, 0, 0, 102>>,
                                     <<"node3">>=><<128, 1, 64, 0, Chain2, 0, 0, 103>>
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
                           case blockchain:rel(H, self) of
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
              case mledger:get(Addr) of
                #{amount:=_}=Bal -> Bal;
                undefined -> mbal:new()
              end
          end,

  ParentHash=crypto:hash(sha256, <<"parent">>),

  #{block:=Blk}=generate_block:generate_block(
             TxList,
             {1, ParentHash},
             GetSettings,
             GetAddr,
             [],
             [{ledger_pid, LedgerPID}]),
  block:outward_chain(Blk,Chain1)
  end,
  mledger:deploy4test(Ledger, Test).




xchain_test() ->
  Chain1=1,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr1=naddress:construct_public(1, Chain1, 1),
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX1=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>Addr1,
          seq=>2,
          t=>os:system_time(millisecond),
          payload=>[
                    #{purpose=>gas, amount=>10, cur=><<"FTT">>}
                   ],
          call=>#{function=>"init",args=>[1024]},
          txext=>#{ "code"=> Code,
                    "vm" => "erltest"
                  }
         }), Pvt1),
  TestFun=fun(#{block:=Block,
                failed:=Failed}) ->
              io:format("Block  ~p~n",[Block]),
              io:format("Failed ~p~n",[Failed])
          end,
  Ledger1=[
          {Addr1,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
          }
         ],
  TxL=[
       {<<"inward">>, xchain_test_callingblock()},
       {<<"1testdeploy">>, maps:put(sigverify,#{valid=>1},TX1)}
      ],
  extcontract_template(Chain1, TxL, Ledger1, TestFun, 1).

