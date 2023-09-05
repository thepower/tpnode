-module(sponsor_sc_test_test).

-include_lib("eunit/include/eunit.hrl").

evm_lst_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      ScCode=fun() ->
                 {ok,Bin} = file:read_file("Lstore.bin"),
                 Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

                 {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
                 Code2
             end(),
      SkAddr=naddress:construct_public(1, OurChain, 2),

      TX1=tx:sign(
            tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                      function => "registerMessage(uint256,string)",
                      args => [1,<<"preved">>]
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
      TestFun=fun(#{block:=#{bals:=Bals}=_Block,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  io:format("Bals ~p~n",[Bals]),
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
                 code => ScCode,
                 vm => <<"evm">>
                }
              }
             ],
      io:format("whereis ~p~n",[whereis(eevm_tracer)]),
      register(eevm_tracer,self()),
      {ok,Log}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      unregister(eevm_tracer),
      ABI=contract_evm_abi:parse_abifile("Lstore.abi"),
      [{_,_,FABI}]=contract_evm_abi:find_function(<<"registerMessage(uint256,string)">>,ABI),
      D=fun() -> receive {trace,{return,Data}} -> Data after 0 -> <<>> end end(),
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

      hex:hexdump(D),
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


ssc_test() ->
  {ok,Bin} = file:read_file("examples/evm_builtin/build/sponsor.bin"),
  ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/sponsor.abi"),

  Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

  {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),

  %BinFun= <<"areYouSponsor()">>,
  %{ok,E}=ksha3:hash(256, BinFun),
  %<<X:4/binary,_/binary>> = E,
  %CD= <<X:4/binary>>,

  %{done,{return,Ret},_}=eevm:eval(Code2,#{},#{ gas=>10000, extra=>#{}, cd=>CD }),
  %[{_,_,FABI}]=contract_evm_abi:find_function(BinFun,ABI),

  %DRet=contract_evm_abi:decode_abi(Ret,FABI),
  DRet=call(<<"areYouSponsor()">>,[],ABI,Code2),
  DRet2=call(<<"wouldYouLikeToPayTx((uint256,address,address,uint256,uint256,(string,uint256[])[],(uint256,string,uint256)[],(bytes,uint256,bytes,bytes,bytes)[]))">>,
             [
              [1,<<1,2,3,4,5,6,7,8>>,<<1,2,3,4,5,6,7,9>>,1,2,[],
               [[1,<<"SK">>,5],[2,<<"SK">>,6]],
              []
              ]],ABI,Code2),
  %wouldYouLikeToPayTx(tpTx calldata utx) p
  [?assertMatch([{<<"arg1">>,true},{<<"arg2">>,<<"SK">>},{<<"arg3">>,100000}], DRet),
   ?assertMatch([{<<"iWillPay">>,<<"i will pay">>},
        {<<"pay">>,
         [[{<<"purpose">>,0},{<<"cur">>,<<"SK">>},{<<"amount">>,10}]]}],DRet2)
  ].

call(Function, CArgs, ABI, Code) when is_binary(Function), is_list(CArgs) ->
  [{_,InABI,OutABI}]=contract_evm_abi:find_function(Function,ABI),
  CD=callcd(Function, CArgs, InABI),
  {done,{return,Ret},_}=eevm:eval(Code,#{},#{ gas=>10000, extra=>#{}, cd=>CD }),
  contract_evm_abi:decode_abi(Ret,OutABI).

callcd(BinFun, CArgs, FABI) ->
  {ok,E}=ksha3:hash(256, BinFun),
  <<X:4/binary,_/binary>> = E,
  true=(length(FABI)==length(CArgs)),
  BArgs=contract_evm_abi:encode_abi(CArgs,FABI),
  <<X:4/binary,BArgs/binary>>.

evm_sponsored_call_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),

      SpCode=fun() ->
                 {ok,Bin} = file:read_file("examples/evm_builtin/build/sponsor.bin"),

                 Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),
                 {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
                 Code2
             end(),


      ScCode=fun() ->
                 {ok,Bin} = file:read_file("examples/evm_builtin/build/builtinFunc.bin"),
                 Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

                 {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),
                 Code2
             end(),
      SkAddr=naddress:construct_public(1, OurChain, 2),

      SpAddr=naddress:construct_public(1, OurChain, 3),

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
                        #{purpose=>gashint, amount=>55300, cur=><<"FTT">>},
                        #{purpose=>srcfeehint, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond),
              txext=>#{<<"sponsor">> => [SpAddr]}
             }), Pvt1),
            tpecdsa:generate_priv(ed25519)),

      hex:hexdump(tx:pack(TX1)),

      TxList1=[
               {<<"tx1">>, maps:put(sigverify,#{valid=>1},TX1)}
              ],
      TestFun=fun(#{block:=#{bals:=Bals}=_Block,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  io:format("Bals ~p~n",[Bals]),
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
              {SpAddr,
               #{amount => #{<<"SK">> => 100000000,
                             <<"FTT">> => 100000000,
                             <<"TST">> => 10000 },
                 code => SpCode,
                 vm => <<"evm">>
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => ScCode,
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


