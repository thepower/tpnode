-module(process_txs_mkblock2).

-include_lib("eunit/include/eunit.hrl").

run_tests(DBName, OurChain, Ledger, [{TxL1,Check1}|_]=Suite) when is_list(TxL1),
                                                          is_function(Check1,3) ->
  Node1Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 154>>,
  Node2Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 155>>,
  Node3Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 156>>,
  MeanTime=os:system_time(millisecond),
  Entropy=crypto:hash(sha256,<<"test1">>),
  ParentHeight=13,
  ParentHash=crypto:hash(sha256, <<"parent">>),


  GetSettings=fun(mychain) -> OurChain;
                 (parent_block) ->
                  #{height=>ParentHeight, hash=>ParentHash};
                 (settings) ->
                  #{
                    chains => [OurChain],
                    keys =>
                    #{
                      <<"node1">> => tpecdsa:calc_pub(Node1Pk),
                      <<"node2">> => tpecdsa:calc_pub(Node2Pk),
                      <<"node3">> => tpecdsa:calc_pub(Node3Pk)
                     },
                    nodechain =>
                    #{
                      <<"node1">> => OurChain,
                      <<"node2">> => OurChain,
                      <<"node3">> => OurChain
                     },
                    <<"current">> => #{
                                       <<"allocblock">> => #{
                                                             <<"block">> => 10,
                                                             <<"group">> => 10,
                                                             <<"last">> => 5
                                                            },
                                       chain => #{
                                                  blocktime => 5,
                                                  minsig => 2,
                                                  <<"allowempty">> => 0
                                                 },
                                       <<"gas">> => #{
                                                      <<"FTT">> => #{
                                                                     <<"tokens">> =>100,
                                                                     <<"gas">> => 1000
                                                                    },
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
                 ({get_block, Back}) when 64>=Back ->
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
  try

    Test=fun(DBName1) ->
             lists:reverse(
               lists:foldl(
                 fun({TxList, CheckFun}, A) ->
                     #{block:=Block} = Res
                     = generate_block2:generate_block(
                         TxList,
                         {ParentHeight, ParentHash},
                         GetSettings,
                         fun(_) -> throw('do not use it') end,
                         [],
                         [{ledger_pid, DBName1},
                          {entropy, Entropy},
                          {mean_time, MeanTime},
                          {extract_state, true}
                         ]),
                     #{header:=#{roots:=Roots}}=Block,
                     {ledger_hash,LH}=lists:keyfind(ledger_hash,1,Roots),
                     Applied=blockchain_updater:apply_ledger(DBName1,
                                                             %put,
                                                             {checkput, LH},
                                                             Block),
                     [CheckFun(DBName1,Res,Applied)|A]
                 end, [], Suite))
         end,
  mledger:deploy4test(DBName, Ledger, Test)
after
  ok
  end.


code_for_callwithcode() ->
  eevm_asm:asm(
    [{push,1,0},
     sload,
     {push,1,1},
     add,
     {dup,1},
     {push,1,0},
     sstore,
     {push,1,0},
     mstore,
     calldatasize,
     {dup,1},
     {push,1,0},
     {push,1,0},
     calldatacopy,
     {push,1,0},
     return]
   ).

wrong_signature_test() ->
      OurChain=151,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      PvtBad= <<255, 255, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      DBName=test_ledger,

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                      function => "test(bytes)", args => [<<1,2,3,4>>]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>3,
              txext => #{
                         "vm" => "evm",
                         "code" => code_for_callwithcode()
                        },
              t=>os:system_time(millisecond)
             }), PvtBad),
      TxList1=[ {<<"tx1">>, TX1} ],
      TestFun1=fun(_DBName, #{block:=#{failed:=FailedB},
                    failed:=Failed}, ApplyRes) ->
                   io:format("Failed ~p~n",[Failed]),
                   ?assertMatch({ok,_},ApplyRes),
                   ?assertMatch([{<<"tx1">>,bad_sig}],Failed),
                   ?assertMatch([{<<"tx1">>,_}],FailedB),
                   ok
              end,
      Ledger=[
              {Addr1,
               #{amount => #{
                             <<"FTT">> => 1000000,
                             <<"SK">> => 3,
                             <<"TST">> => 26
                            },
                 state => #{
                   <<0>> => <<1>>
                  },
                 pubkey => tpecdsa:calc_pub(Pvt1)
                }
              }
             ],
      Res=run_tests(DBName,
                                   OurChain,
                                   Ledger,
                                   [{TxList1,TestFun1}]),
      [?assertEqual([ok], Res) ].

verify_apply_block_test() ->
      OurChain=151,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      DBName=test_ledger,

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                      function => "test(bytes)", args => [<<1,2,3,4>>]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>3,
              txext => #{
                         "vm" => "evm",
                         "code" => code_for_callwithcode()
                        },
              t=>os:system_time(millisecond)
             }), Pvt1),
      TxList1=[ {<<"tx1">>, TX1} ],
      TestFun1=fun(_DBName, #{block:=Block=#{header:=#{roots:=Roots}},
                    log:=Log}, ApplyRes) ->
                   io:format("Block1 ~p~n",[Block]),
                  {ledger_hash,ExpectedHash} = lists:keyfind(ledger_hash,1,Roots),
                  ?assertMatch({ok,ExpectedHash},ApplyRes),
                  {ok,Log,Block}
              end,
      TestFun2=fun(DBName, #{block:=Block=#{header:=#{roots:=Roots}}}, ApplyRes) ->
                  {ledger_hash,ExpectedHash} = lists:keyfind(ledger_hash,1,Roots),
                  ?assertMatch({ok,ExpectedHash},ApplyRes),
                  ?assertMatch({ok,999282}, mledger:db_get_one(DBName, Addr1, balance, <<"FTT">>, [])),
                  {ok,Block}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{
                             <<"FTT">> => 1000000,
                             <<"SK">> => 3,
                             <<"TST">> => 26
                            },
                 state => #{
                   <<0>> => <<1>>
                  },
                 pubkey => tpecdsa:calc_pub(Pvt1)
                }
              }
             ],
      [{ok,_Log,OBlock},_]=run_tests(DBName,
                                   OurChain,
                                   Ledger,
                                   [{TxList1,TestFun1},
                                    {[],TestFun2}
                                   ]),
      #{bals:=B,txs:=[_],receipt:=[_Tx]}=block:downgrade(OBlock),
      Privs=[hex:decode("0x302E020100300506032B65700422042078F71808485338123812BCE25A20A4D24AF56D582DA784D7F22AAE7C1D68E343"),
            hex:decode("0x302E020100300506032B657004220420D50B406DF9C878EE87B81D9BFFDB9F11F2F99E1A5BA2F9D2F0AE06D5770BABB1")],
      SBlock=lists:foldl(
               fun(Priv, ABlock) ->
                   block:sign(ABlock, Priv)
               end, OBlock, Privs),
      Repacked=(block:unpack(block:pack(SBlock))),
      [
       ?assertMatch(#{state:=#{<<0>> := <<2>>}},maps:get(Addr1,B)),
       ?assertMatch({true,{[],0}},block:verify(OBlock)),
       ?assertMatch({true,{[_,_],0}},block:verify(SBlock)),
       ?assertMatch({true,{[_,_],0}},block:verify(Repacked))
      ].


