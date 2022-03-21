-module(mkblock_evm_tests).

-include_lib("eunit/include/eunit.hrl").

mkstring(Bin) when size(Bin)==32 ->
  Bin;

mkstring(Bin) when size(Bin)<32 ->
  PadL=32-size(Bin),
  <<Bin/binary,0:(PadL*8)/integer>>.


extcontract_template(OurChain, TxList, Ledger, CheckFun) ->
  try
  Test=fun(LedgerPID) ->
           MeanTime=os:system_time(millisecond),
           Entropy=crypto:hash(sha256,<<"test1">>),

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
                          (entropy) -> Entropy;
                          (mean_time) -> MeanTime;
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
             TxList,
             {1, ParentHash},
             GetSettings,
             GetAddr,
             [],
             [{ledger_pid, LedgerPID},
              {entropy, Entropy},
              {mean_time, MeanTime}
             ]))
  end,
  mledger:deploy4test(Ledger, Test)
after
  ok
  end.


%test_evm() ->
%  {ok,HexCode}=file:read_file("./examples/TetherToken.hex"),
%  Code=hex:decode(HexCode),
%  Tx1=tx:pack(tx:construct_tx(
%               #{ver=>2,
%                 kind=>deploy,
%                 from=><<128,0,32,0,2,0,0,3>>,
%                 seq=>5,
%                 t=>1530106238743,
%                 payload=>[
%                           #{amount=>10, cur=><<"XXX">>, purpose=>transfer },
%                           #{amount=>20, cur=><<"FEE">>, purpose=>srcfee }
%                          ],
%                 txext=>#{"code"=>Code,
%                          "vm"=>"evm"}
%                })),
%    Entropy=crypto:hash(sha256,<<"test">>),
%    MeanTime=1555555555555,
%    XtraFields=#{ mean_time => MeanTime, entropy => Entropy },
%  L0=msgpack:pack(
%      #{
%      %"code"=><<>>,
%      "state"=>msgpack:pack(#{
%%                 <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">> => <<"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB">>,
%%                 <<"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX">> => <<"YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY">>
%                })
%     }),
%  {ok,#{"state":=S1}}=run(fun(Pid) ->
%                              Pid ! {run, Tx1, L0, 11111, self(), XtraFields }
%      end, "evm", 2, []),
%
%  Tx2=tx:pack(tx:construct_tx(
%               #{ver=>2,
%                 kind=>generic,
%                 from=><<128,0,32,0,2,0,0,3>>,
%                 to=><<128,0,32,0,2,0,0,3>>,
%                 seq=>5,
%                 t=>1530106238743,
%                 payload=>[
%                           #{amount=>10, cur=><<"XXX">>, purpose=>transfer },
%                           #{amount=>20, cur=><<"FEE">>, purpose=>srcfee }
%                          ],
%                 call=>#{function=>"inc",args=>[<<1:256/big>>]}
%                })),
%  L1=msgpack:pack(
%      #{
%      "code"=>Code,
%      "state"=>S1
%      }),
%  {ok,#{"state":=S2}=R2}=run(fun(Pid) ->
%                      Pid ! {run, Tx2, L1, 11111, self(), XtraFields }
%                  end, "wasm", 2, []),
%%  {ok,UT2}=msgpack:unpack(Tx2),
%  {msgpack:unpack(S1),
%   msgpack:unpack(S2),
%   R2
%  }.



tether_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Addr2=naddress:construct_public(1, OurChain, 2),
      Addr3=naddress:construct_public(1, OurChain, 3),
      Code0=fun() ->
                {ok,HexCode}=file:read_file("./examples/TetherToken.hex"),
                [HexCode1|_]=binary:split(HexCode,<<"\n">>),
                hex:decode(HexCode1)
            end(),

      CoinSym=mkstring(<<"CoinSym">>),
      Code= <<Code0/binary,(131072):256/big,CoinSym/binary,CoinSym/binary,3:256/big>>,

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>deploy,
              from=>Addr1,
              seq=>2,
              t=>os:system_time(millisecond),
              payload=>[
                        #{purpose=>transfer, amount=>0, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>1100, cur=><<"FTT">>},
                        #{purpose=>gas, amount=>30000, cur=><<"FTT">>}
                       ],
              txext=>#{ "code"=> Code, "vm" => "evm" }
             }), Pvt1),
      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                function => "approve(address,uint256)",
                args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
       TX2a=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                      args=>[<<12345:256/big>>, 1024],
                      function => "transfer(address,uint256)"
                     },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr2,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                function => "transferFrom(address,address,uint256)",
                %function => "approve(address,uint256)",
                %function => <<"balanceOf(address)">>,
                args => [Addr1,Addr2,256]
               },
              payload=>[
                        #{purpose=>gas, amount=>4000, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>5,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TX4=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr2,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                function => "transferFrom(address,address,uint256)",
                %function => "approve(address,uint256)",
                %function => <<"balanceOf(address)">>,
                args => [Addr1,Addr3,257]
               },
              payload=>[
                        #{purpose=>gas, amount=>4000, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>6,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"1testdeploy">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2approve1">>, maps:put(sigverify,#{valid=>1},TX2)},
               {<<"2transfer1">>, maps:put(sigverify,#{valid=>1},TX2a)},
               {<<"3transfer1">>, maps:put(sigverify,#{valid=>1},TX3)},
               {<<"4transfer2">>, maps:put(sigverify,#{valid=>1},TX4)}
              ],
%      TxList2=[
%              {<<"4testexec">>, maps:put(sigverify,#{valid=>1},TX4)}
%              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  {ok,Bals}
              end,
      Ledger=[
              {Addr2,
               #{amount => #{ <<"FTT">> => 10000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              }
             ],
      {ok,L1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
%      Ledger2=maps:to_list(
%                maps:put(
%                  Addr2,
%                  #{amount => #{ <<"FTT">> => 30000, <<"SK">> => 10, <<"TST">> => 26 }},
%                  L1)),
%
%
%      TestFun2=fun(#{block:=Block,
%                    emit:=_Emit,
%                    failed:=Failed}) ->
%                   ?assertMatch([],Failed),
%                   Bals=maps:get(bals, Block),
%                   msgpack:unpack(
%                     maps:get(state,
%                              maps:get(<<128,0,32,0,150,0,0,1>>,Bals)
%                             )
%                    )
%              end,
      ContractLedger=maps:get(Addr1,L1),
      {ok,<<B1:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr1]),
      {ok,<<B2:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr2]),
      {ok,<<B3:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr3]),
      io:format("Addr bal ~w/~w/~w~n",[B1,B2,B3]),
      State1= maps:get(state, ContractLedger),
      io:format("State1 ~p~n",[State1]),
      io:format("= ADDR1 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr1),State1))]),
      io:format("= ADDR2 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr2),State1))]),
%      {ok,EState2}=extcontract_template(OurChain, TxList2, Ledger2, TestFun2),
%      State2=decode_state(EState2),
      [
%       ?assertMatch(false,maps:is_key("set",State1)),
%       ?assertMatch(true,maps:is_key("self",State1)),
%       ?assertMatch(true,maps:is_key("admins",State1))

%       ?assertMatch(true,maps:is_key("set",State2)),
%       ?assertMatch(true,maps:is_key("self",State2)),
%       ?assertMatch(true,maps:is_key("admins",State2))
      ].

varn(N) ->
  crypto:hash(sha256,<<N:256/big>>).

mapval(N,Key) when is_binary(Key) ->
  NKey=binary:decode_unsigned(Key),
  crypto:hash(sha256,<<NKey:256/big, N:256/big>>).

