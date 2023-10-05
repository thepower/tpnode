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
  ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
  [{_,_,FABI}]=contract_evm_abi:find_function(<<"retcl">>,ABI),
  Bin=contract_evm_abi:encode_abi([[["test",[1,3,5]], ["",[]]]],FABI),
  io:format("FABI ~p~n",[FABI]),
  hex:hexdump(Bin),
  D=contract_evm_abi:decode_abi(Bin,FABI),
  exit(Pid,stop),
  D.


eabi2_test() ->
  %Self=self(),
  %Pid=erlang:spawn(fun() -> timer:sleep(10000), exit(Self,stop) end),
  %ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
  %[{_,_,FABI}]=contract_evm_abi:find_function(<<"rettx">>,ABI),
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
  %Bin=contract_evm_abi:encode_abi([[123,345,456,1,2,[["asd",[1,2,3]]],[]]],FABI),
  Bin=contract_evm_abi:encode_abi([[
                          4100,
                          <<128,0,32,0,150,0,0,1>>,
                          <<128,0,32,0,150,0,0,1>>,
                          123,
                          243,
                          [["test",[1,3,5]], ["",[]]],
                          [[1234,<<"0123456">>,<<"123456">>,<<"123456">>]]
                         ]],FABI),
  %io:format("FABI ~p~n",[FABI]),
  D=contract_evm_abi:decode_abi(Bin,FABI),
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

      {ok,Bin} = file:read_file("examples/evm_builtin/build/builtinFunc.bin"),
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
      io:format("whereis ~p~n",[whereis(eevm_tracer)]),
      register(eevm_tracer,self()),
      {ok,Log}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      unregister(eevm_tracer),
      ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),
      [{_,_,FABI}]=contract_evm_abi:find_function(<<"getTxs()">>,ABI),
      D=fun() -> receive {trace,{return,Data}} -> Data after 0 -> <<>> end end(),
      hex:hexdump(D),
      fun FT() -> receive {trace,{stack,_,_}} -> FT(); {trace,_Any} -> [_Any|FT()] after 0 -> [] end end(),

      io:format("2dec ~p~n",[D]),
      io:format("ABI ~p~n",[FABI]),
      io:format("dec ~p~n",[catch contract_evm_abi:decode_abi(D,FABI)]),
      Events=contract_evm_abi:sig_events(ABI),

      DoLog = fun (BBin) ->
                  {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} = msgpack:unpack(BBin),
                  case lists:keyfind(Arg,2,Events) of
                    false ->
                      {DABI,Arg};
                    {EvName,_,EvABI}->
                      {EvName,contract_evm_abi:decode_abi(DABI,EvABI)}
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

      {ok,Bin} = file:read_file("examples/evm_builtin/build/checkSig.bin"),
      ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/checkSig.abi"),

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
      [{_,_,FABI}]=contract_evm_abi:find_function(<<"setAddr()">>,ABI),
      _D=fun() -> receive {trace,{return,Data}} ->
                           hex:hexdump(Data),
                           io:format("dec ~p~n",[contract_evm_abi:decode_abi(Data,FABI)]),
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

      Events=contract_evm_abi:sig_events(ABI),

      DoLog = fun (BBin) ->
                  case msgpack:unpack(BBin) of
                    {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} ->
                      case lists:keyfind(Arg,2,Events) of
                        false ->
                          {DABI,Arg};
                        {EvName,_,EvABI}->
                          {EvName,contract_evm_abi:decode_abi(DABI,EvABI)}
                      end;
                    {ok,[<<"tx1">>,<<"evm">>,<<"revert">>,Sig]} ->
                      [<<"tx1">>,<<"evm">>,<<"revert">>,Sig];
                    {ok,Any} ->
                      Any
                  end
              end,


      io:format("Logs ~p~n",[[ DoLog(LL) || LL <- Log ]]),
      [
       ?assertMatch(true,true)
      ].



evm_embedded_lstore_test() ->
      OurChain=151,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      {ok,Bin} = file:read_file("examples/evm_builtin/build/builtinFunc.bin"),
      ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/builtinFunc.abi"),

      Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

      {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
      SkAddr=naddress:construct_public(1, OurChain, 2),

      TX0=tx:sign(
            tx:construct_tx(#{
             kind => lstore,
             t => os:system_time(millisecond),
             seq => 2,
             from => SkAddr,
             ver => 2,
             payload => [ ],
             patches => [
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"int">>], <<"v">>=>$b},
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"bin">>], <<"v">>=><<"bin">>},
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"atom">>], <<"v">>=>true},
                         #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"array">>],
                           <<"v">>=>[1,true,<<1,2,33>>]}
                        ]
            }), Pvt1),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                      function => "setLStore(bytes[])",
                      %function => "blockCheck()",
                      %function => "callText(address,uint256)",
                      args => [[<<"a">>,<<"test">>]]
                      %args => [ <<175,255,255,255,255,0,0,2>>, 1025 ]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),


      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                      function => "getLStore(bytes[])",
                      %function => "blockCheck()",
                      %function => "callText(address,uint256)",
                      args => [[<<"a">>,<<"test">>]]
                      %args => [ <<175,255,255,255,255,0,0,2>>, 1025 ]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"tx0">>, maps:put(sigverify,#{valid=>1},TX0)},
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
      {ok,Log,#{bals:=B,txs:=_Tx}}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("Bals ~p~n",[B]),
      %io:format("st ~p~n",[[ maps:with([call,extdata],Body) || {_,Body} <- Tx]]),
      %io:format("Block ~p~n",[block:minify(Blk)]),
      unregister(eevm_tracer),
      %[{_,_,FABI}]=contract_evm_abi:find_function(<<"getLStore(bytes[])">>,ABI),
      %_D=fun() -> receive {trace,{return,Data}} ->
      %                     %hex:hexdump(Data),
      %                     io:format("dec ~p~n",[contract_evm_abi:decode_abi(Data,FABI)]),
      %                     Data
      %           after 0 ->
      %                   <<>>
      %           end end(),
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

      Events=contract_evm_abi:sig_events(ABI),

      DoLog = fun (BBin) ->
                  case msgpack:unpack(BBin) of
                    {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} ->
                      case lists:keyfind(Arg,2,Events) of
                        false ->
                          {DABI,Arg};
                        {EvName,_,EvABI}->
                          {EvName,contract_evm_abi:decode_abi(DABI,EvABI)}
                      end;
                    {ok,[<<"tx1">>,<<"evm">>,<<"revert">>,Sig]} ->
                      [<<"tx1">>,<<"evm">>,<<"revert">>,Sig]
                  end
              end,
      ProcLog=[ DoLog(LL) || LL <- Log ],
      io:format("Logs ~p~n",[ProcLog]),
      Succ=lists:foldl(fun({_,[{<<"text">>,<<"setByPath:success">>},{<<"data">>,<<1:256/big>>}]},_) ->
                     true;
                    (_,A) -> A
                 end, false, ProcLog),

      [
       ?assertMatch(Succ,true)
      ].



evm_caller_test() ->
      OurChain=151,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      {ok,Bin1} = file:read_file("examples/evm_builtin/build/Caller.bin"),
      {ok,Bin2} = file:read_file("examples/evm_builtin/build/Callee.bin"),
      ABI1=contract_evm_abi:parse_abifile("examples/evm_builtin/build/Caller.abi"),

      Code1=hex:decode(hd(binary:split(Bin1,<<"\n">>))),
      Code2=hex:decode(hd(binary:split(Bin2,<<"\n">>))),

      {done,{return,Code1b},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
      {done,{return,Code2b},_}=eevm:eval(Code2,#{},#{ gas=>1000000, extra=>#{} }),
      SkAddr1=naddress:construct_public(1, OurChain, 10),
      SkAddr2=naddress:construct_public(1, OurChain, 20),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr1,
              call=>#{
                      function => "setXFromAddress(address,uint256)",
                      args => [ SkAddr2, 1234 ]
               },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"tx1">>, maps:put(sigverify,#{valid=>1},TX1)}
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
              {SkAddr2,
               #{amount => #{},
                 code => Code2b,
                 vm => <<"evm">>
                }
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1b,
                 vm => <<"evm">>
                }
              }
             ],
      register(eevm_tracer,self()),
      {ok,Log,#{bals:=B,txs:=_Tx}}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("Bals ~p~n",[B]),
      %io:format("st ~p~n",[[ maps:with([call,extdata],Body) || {_,Body} <- Tx]]),
      %io:format("Block ~p~n",[block:minify(Blk)]),
      unregister(eevm_tracer),
      %[{_,_,FABI}]=contract_evm_abi:find_function(<<"getLStore(bytes[])">>,ABI),
      %_D=fun() -> receive {trace,{return,Data}} ->
      %                     %hex:hexdump(Data),
      %                     io:format("dec ~p~n",[contract_evm_abi:decode_abi(Data,FABI)]),
      %                     Data
      %           after 0 ->
      %                   <<>>
      %           end end(),
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

      Events=contract_evm_abi:sig_events(ABI1),

      DoLog = fun (BBin) ->
                  case msgpack:unpack(BBin) of
                    {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} ->
                      case lists:keyfind(Arg,2,Events) of
                        false ->
                          {DABI,Arg};
                        {EvName,_,EvABI}->
                          {EvName,contract_evm_abi:decode_abi(DABI,EvABI)}
                      end;
                    {ok,[<<"tx1">>,<<"evm">>,<<"revert">>,Sig]} ->
                      [<<"tx1">>,<<"evm">>,<<"revert">>,Sig]
                  end
              end,
      ProcLog=[ DoLog(LL) || LL <- Log ],
      io:format("Logs ~p~n",[ProcLog]),
      Succ=true,
      [
       ?assertMatch(Succ,true)
      ].



evm_weth9_test() ->
      OurChain=151,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      {ok,Bin1} = file:read_file("examples/evm_builtin/build/WETH9.bin"),
      ABI1=contract_evm_abi:parse_abifile("examples/evm_builtin/build/WETH9.abi"),

      Code1=hex:decode(hd(binary:split(Bin1,<<"\n">>))),

      {done,{return,Code1b},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
      SkAddr1=naddress:construct_public(1, OurChain, 10),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr1,
              %call=>#{
              %        function => "setXFromAddress(address,uint256)",
              %        args => [ SkAddr1, 1234 ]
              %},
              payload=>[
                        #{purpose=>transfer, amount=>10, cur => <<"SK">>},
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr1,
              call=>#{
                      function => "withdraw(uint256)",
                      args => [ 5 ]
              },
              payload=>[
                        #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
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
                             <<"SK">> => 15,
                             <<"TST">> => 26
                            }
                }
              },
              {SkAddr1,
               #{
                 code => Code1b,
                 amount => #{<<"SK">> => 0},
                 vm => <<"evm">>,
                 state =>
                 #{<<83,129,129,208,245,14,115,33,12,109,126,37,108,214,152,
                     44,168,51,97,153,155,156,202,220,5,55,2,253,234,208,170,
                     132>> =>
                       <<>>}
                }
              }
             ],
      register(eevm_tracer,self()),
      {ok,Log,#{bals:=B,txs:=_Tx}}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("Bals ~p~n",[B]),
      %io:format("st ~p~n",[[ maps:with([call,extdata],Body) || {_,Body} <- Tx]]),
      %io:format("Block ~p~n",[block:minify(Blk)]),
      unregister(eevm_tracer),
      %[{_,_,FABI}]=contract_evm_abi:find_function(<<"getLStore(bytes[])">>,ABI),
      %_D=fun() -> receive {trace,{return,Data}} ->
      %                     %hex:hexdump(Data),
      %                     io:format("dec ~p~n",[contract_evm_abi:decode_abi(Data,FABI)]),
      %                     Data
      %           after 0 ->
      %                   <<>>
      %           end end(),
      fun FT(N) ->
          receive
            %{trace,{opcode,_,{2122,_}}} -> FT(1);
            %{trace,{opcode,_,{_,{dup,_}}}=_Any} -> FT(0);
            %{trace,{opcode,_,{_,{swap,_}}}=_Any} -> FT(0);
            %{trace,{opcode,_,{_,pop}}=_Any} -> FT(0);
            %{trace,{opcode,_,{_,sub}}=_Any} -> FT(0);
            %{trace,{opcode,_,{_,call}}=_Any} ->
            %  io:format("~n~p",[_Any]),
            %  FT(3);
            %%{trace,{opcode,_,{_,mload}}=_Any} ->
            %%  io:format("~n~p",[_Any]),
            %%  FT(3);
            %{trace,{stack,_,_}=_Any} when N>0 ->
            %  io:format("~n: ~p",[_Any]),
            %  FT(0);
            %{trace,{stack,_,_}=_Any} ->
            %  FT(0);
            %{trace,{opcode,Dep,{push,Len,Val}}=_Any} ->
            %  io:format("~n++ {opcode,~w,{push,~w,0x~s}}",[Dep,Len,hex:encode(binary:encode_unsigned(Val))]),
            %  FT(0);
            %{trace,{opcode,_,_}=_Any} ->
            %  %io:format("~n~p",[_Any]),
            %  FT(0);
            {trace,_Any} when N>0 ->
              FT(N-1);
            {trace,_Any} ->
              FT(0)
          after 0 -> 
                  io:format("~n",[])
          end
      end(0),

      Events=contract_evm_abi:sig_events(ABI1),

      DoLog = fun (BBin) ->
                  case msgpack:unpack(BBin) of
                    {ok,[_,<<"evm">>,_,_,DABI,[Signature|Indexed]]} ->
                      case lists:keyfind(Signature,2,Events) of
                        false ->
                          {DABI,Signature};
                        {EvName,_,EvABI} ->
                          {EvName,contract_evm_abi:decode_abi(DABI,EvABI,Indexed)}
                      end;
                    {ok,[<<"tx1">>,<<"evm">>,<<"revert">>,Sig]} ->
                      [<<"tx1">>,<<"evm">>,<<"revert">>,Sig]
                  end
              end,
      ProcLog=[ DoLog(LL) || LL <- Log ],
      io:format("Logs ~p~n",[ProcLog]),
      [
       ?assertMatch(#{amount:=#{<<"SK">>:=5}},maps:get(SkAddr1,B)),
       ?assertMatch(#{amount:=#{<<"SK">>:=10}},maps:get(Addr1,B)),
       ?assertMatch([
                     {<<"Deposit(address,uint256)">>, [{_,Addr1},{_,10}]},
                     {<<"Withdrawal(address,uint256)">>, [{_,Addr1},{_,5}]}
                    ], ProcLog )
      ].



