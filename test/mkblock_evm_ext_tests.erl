-module(mkblock_evm_ext_tests).

-include_lib("eunit/include/eunit.hrl").

extcontract_template(OurChain, TxList, Ledger, CheckFun) ->
  Node1Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 154>>,
  Node2Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 155>>,
  Node3Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
  97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 156>>,
  try
  Test=fun(LedgerPID) ->
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
       GetAddr=fun({storage,Addr,Key}) ->
                   Res=case mledger:get(Addr) of
                     #{state:=State} -> maps:get(Key,State,<<>>);
                     _ -> <<>>
                   end,
                   io:format("TEST get addr ~p key ~p = ~p~n",[Addr,Key,Res]),
                   Res;
                  (Addr) ->
                   case mledger:get(Addr) of
                     #{amount:=_}=Bal -> Bal;
                     undefined -> mbal:new()
                   end
               end,

  CheckFun(generate_block:generate_block(
             TxList,
             {ParentHeight, ParentHash},
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


eabi_test() ->
  Self=self(),
  Pid=erlang:spawn(fun() -> timer:sleep(10000), exit(Self,stop) end),
  ABI=tp_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
  [{_,_,FABI}]=tp_abi:find_function(<<"retcl">>,ABI),
  Bin=tp_abi:encode_abi([[["test",[1,3,5]], ["",[]]]],FABI),
  io:format("FABI ~p~n",[FABI]),
  tp_abi:hexdump(Bin),
  D=tp_abi:decode_abi(Bin,FABI),
  exit(Pid,stop),
  D.


eabi2_test() ->
  %Self=self(),
  %Pid=erlang:spawn(fun() -> timer:sleep(10000), exit(Self,stop) end),
  %ABI=tp_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
  %[{_,_,FABI}]=tp_abi:find_function(<<"rettx">>,ABI),
  FABI=[{<<>>,
       {tuple,[{<<"kind">>,uint256},
               {<<"from">>,address},
               {<<"to">>,address},
               {<<"t">>,uint256},
               {<<"seq">>,uint256},
               {<<"call">>,
                {array,{tuple,[{<<"func">>,string},
                               {<<"args">>,{array,uint256}}]}}},
               {<<"signatures">>,
                {array,{tuple,[{<<"timestamp">>,uint256},
                               {<<"pubkey">>,bytes},
                               {<<"rawkey">>,bytes},
                               {<<"signature">>,bytes}]}}}]}}],
  %Bin=tp_abi:encode_abi([[123,345,456,1,2,[["asd",[1,2,3]]],[]]],FABI),
  Bin=tp_abi:encode_abi([[
                          4100,
                          <<128,0,32,0,150,0,0,1>>,
                          <<128,0,32,0,150,0,0,1>>,
                          123,
                          243,
                          [["test",[1,3,5]], ["",[]]],
                          [[1234,<<"0123456">>,<<"123456">>,<<"123456">>]]
                         ]],FABI),
  %io:format("FABI ~p~n",[FABI]),
  D=tp_abi:decode_abi(Bin,FABI),
  %exit(Pid,stop),
  [
   ?assertMatch(
      [{_,
        [{<<"kind">>,4100},
         {<<"from">>,<<128,0,32,0,150,0,0,1>>},
         {<<"to">>,<<128,0,32,0,150,0,0,1>>},
         {<<"t">>,123},
         {<<"seq">>,243},
         {<<"call">>,
          [[{<<"func">>,<<"test">>},{<<"args">>,[1,3,5]}],
           [{<<"func">>,<<>>},{<<"args">>,[]}]]},
         {<<"signatures">>,[
                            [{<<"timestamp">>,1234},
                             {<<"pubkey">>,<<"0123456">>},
                             {<<"rawkey">>,<<"123456">>},
                             {<<"signature">>,<<"123456">>}
                            ]
                           ]}
        ]}],
      D)
  ].

evm_embedded_abicall_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      {ok,Bin} = file:read_file("examples/evm_builtin/build/builtinFunc.hex"),
      Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

      {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
      SkAddr=naddress:construct_public(1, OurChain, 2),

      TX1=tx:sign(
            tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                      function => "getTxs()",
                      args => []
                      %function => "callText(address,uint256)",
                      %args => [ <<175,255,255,255,255,0,0,2>>, 1025 ]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
            tpecdsa:generate_priv(ed25519)),


      TxList1=[
               {<<"tx1">>, maps:put(sigverify,#{valid=>1},TX1)}
              ],
      TestFun=fun(#{block:=_Block,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  {ok,Log}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{
                             <<"FTT">> => 1000000,
                             <<"SK">> => 3,
                             <<"TST">> => 26
                            }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code2,
                 vm => <<"evm">>
                }
              }
             ],
      register(eevm_tracer,self()),
      {ok,Log}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      unregister(eevm_tracer),
      ABI=tp_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
      [{_,_,FABI}]=tp_abi:find_function(<<"getTxs()">>,ABI),
      D=fun() -> receive {trace,{return,Data}} -> Data after 0 -> <<>> end end(),
      tp_abi:hexdump(D),
      fun FT() ->
          receive 
            {trace,{stack,_,_}} ->
              FT();
            {trace,_Any} ->
              %io:format("~p~n",[_Any]),
              FT()
          after 0 -> ok
          end
      end(),

      io:format("dec ~p~n",[tp_abi:decode_abi(D,FABI)]),
      Events=tp_abi:sigevents(ABI),

      DoLog = fun (BBin) ->
                  {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} = msgpack:unpack(BBin),
                  case lists:keyfind(Arg,2,Events) of
                    false ->
                      {DABI,Arg};
                    {EvName,_,EvABI}->
                      {EvName,tp_abi:decode_abi(DABI,EvABI)}
                  end
              end,


      io:format("Logs ~p~n",[[ DoLog(LL) || LL <- Log ]]),
      [
       ?assertMatch(true,true)
      ].

evm_embedded_gets_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      {ok,Bin} = file:read_file("examples/evm_builtin/build/checkSig.hex"),
      ABI=tp_abi:parse_abifile("examples/evm_builtin/build/checkSig.abi"),

      Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

      {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
      SkAddr=naddress:construct_public(1, OurChain, 2),

      Node1Pk= <<48,46,2,1,0,48,5,6,3,43,101,112,4,34,4,32,22,128,239,248,8,82,125,208,68,96,
                 97,109,94,119,85,167,252,119,1,162,89,59,80,48,100,163,212,254,246,123,208, 154>>,
      TX1=tx:sign(
            tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                      function => "setAddr()",
                      args => []
                      %function => "callText(address,uint256)",
                      %args => [ <<175,255,255,255,255,0,0,2>>, 1025 ]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
            Node1Pk),

      TX2=tx:sign(
            tx:construct_tx(#{
                              ver=>2,
                              kind=>generic,
                              from=>Addr1,
                              to=>SkAddr,
                              call=>#{
                                      function => "blockCheck()",
                                      args => []
                                      %function => "callText(address,uint256)",
                                      %args => [ <<175,255,255,255,255,0,0,2>>, 1025 ]
                                     },
                              payload=>[
                                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>},
                                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                                       ],
                              seq=>4,
                              t=>os:system_time(millisecond)
                             }), Pvt1),



      TxList1=[
               {<<"tx1">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"tx2">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  {ok,Log,Block}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{
                             <<"FTT">> => 1000000,
                             <<"SK">> => 3,
                             <<"TST">> => 26
                            }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code2,
                 vm => <<"evm">>
                }
              }
             ],
      register(eevm_tracer,self()),
      {ok,Log,#{bals:=B,txs:=Tx}=Blk}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("Bals ~p~n",[B]),
      io:format("st ~p~n",[[ maps:with([call,extdata],Body) || {_,Body} <- Tx]]),
      io:format("Block ~p~n",[block:minify(Blk)]),
      unregister(eevm_tracer),
      [{_,_,FABI}]=tp_abi:find_function(<<"setAddr()">>,ABI),
      _D=fun() -> receive {trace,{return,Data}} ->
                           tp_abi:hexdump(Data),
                           io:format("dec ~p~n",[tp_abi:decode_abi(Data,FABI)]),
                           Data
                 after 0 ->
                         <<>>
                 end end(),
      fun FT() ->
          receive 
            {trace,{stack,_,_}} ->
              FT();
            {trace,_Any} ->
              %io:format("~p~n",[_Any]),
              FT()
          after 0 -> ok
          end
      end(),

      Events=tp_abi:sigevents(ABI),

      DoLog = fun (BBin) ->
                  case msgpack:unpack(BBin) of
                    {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} ->
                      case lists:keyfind(Arg,2,Events) of
                        false ->
                          {DABI,Arg};
                        {EvName,_,EvABI}->
                          {EvName,tp_abi:decode_abi(DABI,EvABI)}
                      end;
                    {ok,[<<"tx1">>,<<"evm">>,<<"revert">>,Sig]} ->
                      [<<"tx1">>,<<"evm">>,<<"revert">>,Sig]
                  end
              end,


      io:format("Logs ~p~n",[[ DoLog(LL) || LL <- Log ]]),
      [
       ?assertMatch(true,true)
      ].



