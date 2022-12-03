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

extcontract_template(OurChain, TxList, Ledger, CheckFun, _Workers) ->
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
                            (entropy) -> crypto:hash(sha256,<<1,2,3>>);
                            (mean_time) -> 1617974752;
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

  mledger:deploy4test(Ledger, Test).
%
%after
%  lists:foreach(
%    fun(TermFun) ->
%        TermFun()
%    end, Servers)
%  end.

%extcontract_baddeploy1_test() ->
%  OurChain=150,
%  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
%          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
%  Addr1=naddress:construct_public(1, OurChain, 1),
%  {ok, Code}=file:read_file("./examples/testcontract.ec"),
%  TX3=tx:sign(
%        tx:construct_tx(#{
%          ver=>2,
%          kind=>deploy,
%          from=>Addr1,
%          seq=>2,
%          t=>os:system_time(millisecond),
%          payload=>[
%                    #{purpose=>gas, amount=>10, cur=><<"FTT">>},
%                    #{purpose=>srcfee, amount=>20, cur=><<"FTT">>}
%                   ],
%          call=>#{function=>"init",args=>[1024]},
%          txext=>#{ "code"=> Code,
%                    "vm" => "erltest"
%                  }
%         }), Pvt1),
%  TxList=[ {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)} ],
%  Ledger=[ {Addr1, #{amount => #{ <<"FTT">> => 100, <<"SK">> => 100 }} } ],
%  TestFun=fun(#{block:=Block,
%                emit:=_Emit,
%                failed:=Failed}) ->
%              Fee=maps:get(amount,
%                           maps:get(
%                             <<160, 0, 0, 0, 0, 0, 0, 1>>,
%                             maps:get(bals, Block)
%                            )
%                          ),
%              Sum1=ledgersum(Ledger),
%              Sum2=ledgersum(maps:get(bals, Block)),
%              [
%               ?assertEqual(Sum1,Sum2),
%               ?assertMatch([{<<"3testdeploy">>,noworkers}],Failed),
%               ?assertEqual(#{},Fee)
%              ]
%          end,
%  extcontract_template(OurChain, TxList, Ledger, TestFun, 0).

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
  TX6=tx:sign(
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
           {<<"6willfail">>, maps:put(sigverify,#{valid=>1},TX6)}
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
                             chains => [Chain1,Chain2],
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
  Addr2=naddress:construct_public(1, Chain1+10, 1),
  TX1=tx:sign(
        tx:construct_tx(#{
                          ver=>2,
                          kind=>generic,
                          from=>Addr1,
                          to=>Addr2,
                          seq=>2,
                          t=>os:system_time(millisecond),
                          payload=>[
                                    #{purpose=>transfer, amount=>30, cur=><<"FTT">>}
                                    #{purpose=>srcfee, amount=>28, cur=><<"TST">>}
                                   ]
                         }), Pvt1),
  TestFun=fun(#{block:=Block,
                failed:=Failed}) ->
              io:format("Block  ~p~n",[Block]),
              io:format("Failed ~p~n",[Failed])
          end,
  Ledger1=[
          {Addr1,
           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 28 }}
          }
         ],
  TxL=[
       {<<"1test">>, maps:put(sigverify,#{valid=>1},TX1)}
      ],
  extcontract_template(Chain1, TxL, Ledger1, TestFun, 1).

%xchain_test() ->
%  Chain1=1,
%  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
%          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
%  Addr1=naddress:construct_public(1, Chain1, 1),
%  {ok, Code}=file:read_file("./examples/testcontract.ec"),
%  TX1=tx:sign(
%        tx:construct_tx(#{
%          ver=>2,
%          kind=>deploy,
%          from=>Addr1,
%          seq=>2,
%          t=>os:system_time(millisecond),
%          payload=>[
%                    #{purpose=>gas, amount=>30, cur=><<"FTT">>}
%                    #{purpose=>srcfee, amount=>28, cur=><<"TST">>}
%                   ],
%          call=>#{function=>"init",args=>[1024]},
%          txext=>#{ "code"=> Code,
%                    "vm" => "erltest"
%                  }
%         }), Pvt1),
%  TestFun=fun(#{block:=Block,
%                failed:=Failed}) ->
%              io:format("Block  ~p~n",[Block]),
%              io:format("Failed ~p~n",[Failed])
%          end,
%  Ledger1=[
%          {Addr1,
%           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 28 }}
%          }
%         ],
%  TxL=[
%       {<<"inward">>, xchain_test_callingblock()},
%       {<<"1testdeploy1">>, maps:put(sigverify,#{valid=>1},TX1)}
%      ],
%  extcontract_template(Chain1, TxL, Ledger1, TestFun, 1).
%
%
%contract_ntfy_test() ->
%  Chain1=1,
%  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
%          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
%  Addr1=naddress:construct_public(1, Chain1, 1),
%  {ok, Code}=file:read_file("./examples/testcontract.ec"),
%  TX1=tx:sign(
%        tx:construct_tx(#{
%          ver=>2,
%          kind=>deploy,
%          from=>Addr1,
%          seq=>2,
%          t=>os:system_time(millisecond),
%          payload=>[
%                    #{purpose=>gas, amount=>10, cur=><<"FTT">>}
%                   ],
%          call=>#{function=>"init",args=>[1024]},
%          txext=>#{ "code"=> Code,
%                    "vm" => "erltest"
%                  }
%         }), Pvt1),
%  TX2=tx:sign(
%        tx:construct_tx(#{
%          ver=>2,
%          kind=>generic,
%          from=>Addr1,
%          to=>Addr1,
%          cur=><<"FTT">>,
%          call=>#{function=>"notify",args=>[256]},
%          payload=>[
%                    #{purpose=>gas, amount=>100, cur=><<"FTT">>},
%                    #{purpose=>srcfee, amount=>1, cur=><<"FTT">>}
%                   ],
%          seq=>2,
%          t=>os:system_time(millisecond)
%         }), Pvt1),
%
%
%
%  TestFun=fun(#{block:=Block,
%                failed:=Failed}) ->
%              io:format("Emit ~p~n",[maps:get(etxs,Block)]),
%              io:format("Block  ~p~n",[Block]),
%              io:format("Failed ~p~n",[Failed])
%          end,
%  Ledger1=[
%          {Addr1,
%           #{amount => #{ <<"FTT">> => 10, <<"SK">> => 3, <<"TST">> => 26 }}
%          }
%         ],
%  TxL=[
%       {<<"2ntfy">>, maps:put(sigverify,#{valid=>1},TX2)},
%       {<<"1testdeploy2">>, maps:put(sigverify,#{valid=>1},TX1)}
%      ],
%  extcontract_template(Chain1, TxL, Ledger1, TestFun, 1).
%
