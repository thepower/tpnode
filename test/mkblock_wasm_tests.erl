-module(mkblock_wasm_tests).

-include_lib("eunit/include/eunit.hrl").

allocport() ->
  {ok,S}=gen_tcp:listen(0,[]),
  {ok,{_,CPort}}=inet:sockname(S),
  gen_tcp:close(S),
  CPort.

extcontract_template(OurChain, TxList, Ledger, CheckFun) ->
  Workers=1,
  Servers=case whereis(tpnode_vmsrv) of
            undefined ->
              Port=allocport(),
              application:ensure_all_started(ranch),
              {ok, Pid1} = tpnode_vmsrv:start_link(),
              {ok, Pid2} = ranch_listener_sup:start_link(
                             {vm_listener,Port},
                             ranch_tcp,
                             #{
                               connection_type => supervisor,
                               socket_opts => [{port,Port}]
                              },
                             tpnode_vmproto,[]),
              timer:sleep(300),
              [fun()->gen_server:stop(Pid1) end,
               fun()->exit(Pid2,normal) end
               | [
                  begin
                    SPid=vm_wasm:run("127.0.0.1",Port),
                    fun()->SPid ! stop end
                  end || _ <- lists:seq(1,Workers) ]
              ];
            _ ->
              VMPort=application:get_env(tpnode,vmport,50050),
              [
               begin
                 SPid=vm_wasm:run("127.0.0.1",VMPort),
                 fun()->SPid ! stop end
               end || _ <- lists:seq(1,Workers) ]
          end,
  timer:sleep(200),
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
  lists:foreach(
    fun(TermFun) ->
        TermFun()
    end, Servers)
  end.


extcontract_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Addr2=naddress:construct_public(1, OurChain, 3),
      Addr3=naddress:construct_public(1, OurChain, 5),
      %{ok, Code}=file:read_file("./examples/testcontract.wasm"),
      {ok, Code}=file:read_file("./examples/sc_inc4.wasm.lz4"),
      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>deploy,
              from=>Addr1,
              seq=>2,
              t=>os:system_time(millisecond),
              payload=>[
                        #{purpose=>srcfee, amount=>500, cur=><<"FTT">>},
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
              call=>#{function=>"add",args=>[4]},
              payload=>[
                        #{purpose=>transfer, amount=>1, cur=><<"FTT">>},
                        #{purpose=>transfer, amount=>3, cur=><<"TST">>},
                        #{purpose=>gas, amount=>10, cur=><<"TST">>}, %wont be used
                        #{purpose=>gas, amount=>10, cur=><<"SK">>}, %will be used 1
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
              call=>#{function=>"expensive",args=>[1000]},
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
                  ?assertMatch([{<<"5willfail">>,insufficient_gas}],Failed),
%                  io:format("Block ~p~n",[Block]),
                  %io:format("Failed ~p~n",[Failed]),
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
                  StateKey=msgpack:pack("v"),
                  StateVal=msgpack:pack(20),
                  io:format("St ~p~n",[ maps:get(StateKey,ContractState) ]),
                  NewLedgerSum=maps:fold(
                    fun(_Addr,#{amount:=Bal},Acc) ->
                       maps:fold(
                        fun(K,V,A) ->
                           maps:put(K,maps:get(K,A,0)+V,A)
                        end, Acc, Bal)
                    end, #{}, maps:get(bals, Block)),
                  io:format("NewLedgerSum ~p~n",[NewLedgerSum]),
                  [
                   ?assertMatch([{<<"5willfail">>,insufficient_gas}],Failed),
                   ?assertMatch([<<"4testexec">>,<<"3testdeploy">>],Success),
                   ?assertMatch(StateVal,maps:get(StateKey,ContractState)),
                   ?assertMatch(#{<<"TST">>:=29, <<"FTT">>:=390},maps:get(amount, NewSCLedger)),
                   ?assertMatch(#{<<"SK">>:=5, <<"FTT">>:=614},Fee)
                  ]
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {Addr2,
               #{amount => #{ <<"FTT">> => 10, <<"SK">> => 10, <<"TST">> => 26 }}
              },
              {Addr3,
               #{amount => #{ <<"FTT">> => 10, <<"SK">> => 2, <<"TST">> => 26 }}
              }
             ],
      OldLedgerSum=lists:foldl(
                    fun({_Addr,#{amount:=Bal}},Acc) ->
                       maps:fold(
                        fun(K,V,A) ->
                           maps:put(K,maps:get(K,A,0)+V,A)
                        end, Acc, Bal)
                    end, #{}, Ledger),
      io:format("OldLedgerSum ~p~n",[OldLedgerSum]),

      extcontract_template(OurChain, TxList, Ledger, TestFun).

brom_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Addr2=naddress:construct_public(1, OurChain, 2),
      %{ok, Code}=file:read_file("./examples/testcontract.wasm"),
      {ok, Code}=file:read_file("./examples/brom1"),
      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>deploy,
              from=>Addr1,
              seq=>2,
              t=>os:system_time(millisecond),
              payload=>[
                        #{purpose=>srcfee, amount=>1100, cur=><<"FTT">>},
                        #{purpose=>gas, amount=>30000, cur=><<"FTT">>}
                       ],
              call=>#{function=>"init",
                      args=> [
                              [binary_to_list(naddress:encode(Addr2)),
                               "AA100000171127710742",
                               "AA100000171127710742"]
                             ]},
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
              call=>#{
                function => "set_settings",
                args => [["20.08.20","edfsdfsdaf","1111","2222","0","100000","0","0"]]
               },
              payload=>[
                        #{purpose=>gas, amount=>29000, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>2,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TxList1=[
               {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)}
              ],
      TxList2=[
              {<<"4testexec">>, maps:put(sigverify,#{valid=>1},TX4)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  {ok,Bals}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 40000, <<"SK">> => 3, <<"TST">> => 26 }}
              }
             ],
      {ok,L1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      Ledger2=maps:to_list(
                maps:put(
                  Addr2,
                  #{amount => #{ <<"FTT">> => 30000, <<"SK">> => 10, <<"TST">> => 26 }},
                  L1)),


      TestFun2=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                   ?assertMatch([],Failed),
                   Bals=maps:get(bals, Block),
                   msgpack:unpack(
                     maps:get(state,
                              maps:get(<<128,0,32,0,150,0,0,1>>,Bals)
                             )
                    )
              end,
      EState1= maps:get(state,
               maps:get(<<128,0,32,0,150,0,0,1>>,L1)
              ),
      {ok,EState2}=extcontract_template(OurChain, TxList2, Ledger2, TestFun2),
      State2=decode_state(EState2),
      State1=decode_state(EState1),
      [
       ?assertMatch(false,maps:is_key("set",State1)),
       ?assertMatch(true,maps:is_key("self",State1)),
       ?assertMatch(true,maps:is_key("admins",State1)),

       ?assertMatch(true,maps:is_key("set",State2)),
       ?assertMatch(true,maps:is_key("self",State2)),
       ?assertMatch(true,maps:is_key("admins",State2))
      ].

decode_state(State) ->
  maps:fold(fun(K,V,A) ->
                {ok,K1}=msgpack:unpack(K),
                {ok,V1}=msgpack:unpack(V),
                maps:put(K1,V1,A)
            end, #{}, State).
