-module(mkblock_evm_tests).

-include_lib("eunit/include/eunit.hrl").

mkstring(Bin) when size(Bin)==32 ->
  Bin;

mkstring(Bin) when size(Bin)<32 ->
  PadL=32-size(Bin),
  <<Bin/binary,0:(PadL*8)/integer>>.

deploycode() ->
  Code=eevm_asm:assemble(<<"
push1 14
dup1
codesize
sub
dup1
dup3
push1 0
codecopy
dup1
push1 0
return">>),
  Code.

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

balance_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Code=eevm_asm:assemble(
<<"
  address
  balance
  push1 0
  mstore
  push1 32
  push1 0
  return
">>),
      Deploycode=deploycode(),

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
              txext=>#{ "code"=> <<Deploycode/binary,Code/binary>>, "vm" => "evm" }
             }), Pvt1),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"1testdeploy">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)},
               {<<"3xfer">>, maps:put(sigverify,#{valid=>1},TX3)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              }
             ],
      {ok,L1,S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      ContractLedger=maps:get(Addr1,L1),
      io:format("State1 ~p~n",[maps:map(fun(_,V)->maps:keys(V) end,L1)]),
      State1= maps:get(state, ContractLedger),
      io:format("State1 ~p~n",[State1]),
      io:format("Sets ~p~n",[S1]),
      %io:format("= ADDR1 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr1),State1))]),
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

call_value_failed_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SkAddr1=naddress:construct_public(1, OurChain, 4),
      Code1=eevm_asm:asm(
              [{push,1,0},
 sload,
 {push,1,1},
 add,
 {dup,1},
 {push,1,0},
 sstore,
 {push,1,0},
 mstore,
 {push,1,32},
 {push,1,0},
 return]
             ),

      SkAddr=naddress:construct_public(1, OurChain, 5),
      Code=eevm_asm:assemble(
<<"
push1 0
push1 0
push1 0
push1 0
push1 2
push8 9223407223743447044
push3 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code,
                 vm => <<"evm">>
                }
              }
             ],
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("State1 ~p~n",[L1]),
      [
       ?assertMatch(#{amount:=#{<<"SK">>:=1}},
                    maps:get(<<128,0,32,0,150,0,0,5>>,L1)),
       ?assertMatch(true,true)
      ].


call_value_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SkAddr1=naddress:construct_public(1, OurChain, 4),
      Code1=eevm_asm:assemble(<<"
push1 0x0
sload
push1 0x1
add
dup1
push1 0x0
sstore
push1 0x0
mstore
push1 0x20
push1 0x0
return
">>),

      SkAddr=naddress:construct_public(1, OurChain, 5),
      Code=eevm_asm:assemble(<<"
push1 0
push1 0
push1 0
push1 0
push1 1
push8 to_addr
push3 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>,
#{"to_addr"=>binary:decode_unsigned(SkAddr1)}),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code,
                 vm => <<"evm">>
                }
              }
             ],
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("State1 ~p~n",[L1]),
      [
       ?assertMatch(#{amount:=#{<<"SK">>:=1}}, maps:get(SkAddr1,L1)),
       ?assertMatch(true,true)
      ].

call_embed_deploy_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      SkAddr=naddress:construct_public(1, OurChain, 5),
      Code=eevm_asm:assemble(<<"
push1 0
push1 0
push1 0
push1 0
push1 1
push8 0xAFFFFFFFFF000000
push3 262144
staticcall

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>),


      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>deploy,
              from=>SkAddr,
              txext => #{ "code"=>Code, "vm" => "evm" },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"deploy">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {SkAddr,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              }
             ],
      _=recv_return(),
      register(eevm_tracer,self()),
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      unregister(eevm_tracer),
      [<<Timestamp:256/big,Entropy/binary>>]=recv_return(),
      io:format("Timestamp ~p~n",[Timestamp]),
      io:format("Entropy ~p~n",[Entropy]),


      io:format("State1 ~p~n",[L1]),
      [
       ?assertMatch(true, (erlang:system_time(millisecond)-Timestamp  < 5000)),
       ?assertMatch(true,true)
      ].

recv_return() ->
  receive
    {trace,{return,Ret}} ->
      [Ret|recv_return()];
    {trace,_Any} ->
      recv_return()
  after 0 ->
          []
  end.


call_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SkAddr1=naddress:construct_public(1, OurChain, 4),
      Code1=eevm_asm:asm(
              [{push,1,0},
 sload,
 {push,1,1},
 add,
 {dup,1},
 {push,1,0},
 sstore,
 {push,1,0},
 mstore,
 {push,1,32},
 {push,1,0},
 return]
             ),

      SkAddr=naddress:construct_public(1, OurChain, 5),
      Code=eevm_asm:assemble(
<<"
push1 0
push1 0
push1 0
push1 0
push1 0
push8 9223407223743447044
push3 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),


      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)},
               {<<"3xfer">>, maps:put(sigverify,#{valid=>1},TX3)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code,
                 vm => <<"evm">>
                }
              }
             ],
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("State1 ~p~n",[L1]),
      [
       ?assertMatch(#{state:=#{<<0>> := <<2,0,2>>}},
                    maps:get(<<128,0,32,0,150,0,0,4>>,L1)),
       ?assertMatch(true,true)
      ].


create_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      Code=eevm_asm:assemble(
<<"
push16 38
push32 0x63000003e8600055716000546001018060005560005260206000F360701B6000
push1 0
mstore
push6 0x5260126000F3
push1 208
shl
push1 32
mstore

dup1
PUSH1 0
PUSH1 0
CREATE

push1 0
push1 0
push1 0
push1 0
push1 0
push8 9223723880743436294
push3 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>),

      Deploycode=deploycode(),

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
              txext=>#{ "code"=> <<Deploycode/binary,Code/binary>>, "vm" => "evm" }
             }), Pvt1),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),
      TX3=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>Addr1,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"1testdeploy">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)},
               {<<"3xfer">>, maps:put(sigverify,#{valid=>1},TX3)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {<<128,1,64,0,10,0,0,6>>,
               #{amount => #{},
                 code => <<96,0,84,96,1,1,128,96,0,85,96,0,82,96,32,96,0,243>>,
                 vm => <<"evm">>,
                 state => #{
                            <<0>> => <<123>>
                           }
                }
              }
             ],
      {ok,L1,S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      ContractLedger=maps:get(Addr1,L1),
      io:format("State1 ~p~n",[L1]),
      State1= maps:get(state, ContractLedger),
      io:format("State1 ~p~n",[State1]),
      io:format("Sets ~p~n",[S1]),
      %io:format("= ADDR1 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr1),State1))]),
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


embed_staticcall_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 10),
      SC1=naddress:construct_public(1, OurChain, 1),

      Code=eevm_asm:assemble(
                      <<"
PUSH1 64
PUSH1 0
PUSH1 0
PUSH1 0
push8 0xAFFFFFFFFF000000
PUSH2 0xFFFF
STATICCALL
push1 0
mload
push1 1
sstore
push1 32
mload
push1 2
sstore
push1 0
push1 32
return
">>
                     ),


      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SC1,
              payload=>[
                        #{purpose=>gas, amount=>5000, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SC1,
               #{amount => #{},
                 code => Code,
                 vm => <<"evm">>,
                 state => #{ }
                }
              }
             ],
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      _ContractLedger=maps:get(Addr1,L1),
      io:format("State1 ~p~n",[L1]),
      [
       ?assertMatch(#{state:=#{<<1>>:=_T,<<2>>:=<<_Rnd:256/big>>}},maps:get(SC1,L1))
      ].


callcode_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 10),
      SC1=naddress:construct_public(1, OurChain, 1),

      SC2=naddress:construct_public(1, OurChain, 2),

      Code=eevm_asm:assemble(
<<"
push sc2
PUSH1 0
PUSH1 0
PUSH1 0
PUSH1 0
PUSH1 0
DUP6
PUSH2 0xFFFF
CALLCODE

// Set first slot in the current contract
PUSH1 1
PUSH1 0
SSTORE

// Call with storage slot 0 != 0, returns 1
PUSH1 0
PUSH1 0
PUSH1 32
PUSH1 0
PUSH1 0
DUP7
PUSH2 0xFFFF
CALLCODE
">>,
#{"sc2" => binary:decode_unsigned(SC1)}
),

      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SC2,
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"2xfer">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    failed:=Failed}) ->
                  ?assertMatch([],Failed),
                  Bals=maps:get(bals, Block),
                  Sets=maps:get(settings, Block),
                  {ok,Bals,Sets}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SC1,
               #{amount => #{},
                 code => hex:decode(<<"600054600757FE5B">>),
                 vm => <<"evm">>,
                 state => #{ }
                }
              },
              {SC2,
               #{amount => #{},
                 code => Code,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<0>>}
                }
              }
             ],
      register(eevm_tracer,self()),
      {ok,L1,_S1}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      unregister(eevm_tracer),
      _ContractLedger=maps:get(Addr1,L1),
      io:format("State1 ~p~n",[L1]),
      CallRet=recv_callret(),
      io:format("CallRet ~p~n",[CallRet]),

      [
       ?assertMatch([{<<0>>,invalid},{<<1>>,eof}],CallRet)
      ].

recv_callret() ->
  receive
    {trace,{callret,_,_,Reason,Ret}=_Any} ->
      io:format("trace ~p~n",[_Any]),
      [{Ret,Reason}|recv_callret()];
    {trace,_Any} ->
      io:format("trace ~p~n",[_Any]),
      recv_callret()
  after 0 ->
          []
  end.



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
                      args=>[Addr3, 512],
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
      ContractLedger=maps:get(Addr1,L1),
      {ok,<<B1:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr1]),
      {ok,<<B2:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr2]),
      {ok,<<B3:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [Addr3]),
      {ok,<<B4:256/big>>} = contract_evm:call(ContractLedger, "balanceOf(address)", [<<12345:256/big>>]),
      io:format("Addr bal ~w/~w/~w/~w~n",[B1,B2,B3,B4]),
      State1= maps:get(state, ContractLedger),
      io:format("State1 ~p~n",[State1]),
      io:format("= ADDR1 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr1),State1))]),
      io:format("= ADDR2 var 2 ~p~n",[binary:decode_unsigned(maps:get(mapval(2,Addr2),State1))]),
%      {ok,EState2}=extcontract_template(OurChain, TxList2, Ledger2, TestFun2),
%      State2=decode_state(EState2),
      [
       ?assertMatch(256,B2),
       ?assertMatch(769,B3),
       ?assertMatch(0,B4),
       ?assertMatch(131072,B1+B2+B3+B4)
%       ?assertMatch(false,maps:is_key("set",State1)),
%       ?assertMatch(true,maps:is_key("self",State1)),
%       ?assertMatch(true,maps:is_key("admins",State1))

%       ?assertMatch(true,maps:is_key("set",State2)),
%       ?assertMatch(true,maps:is_key("self",State2)),
%       ?assertMatch(true,maps:is_key("admins",State2))
      ].

%varn(N) ->
%  %crypto:hash(sha256,<<N:256/big>>).
%  {ok,Hash}=ksha3:hash(256, <<N:256/big>>),
%  Hash.

mapval(N,Key) when is_binary(Key) ->
  NKey=binary:decode_unsigned(Key),
  %crypto:hash(sha256,<<NKey:256/big, N:256/big>>).
  {ok,Hash}=ksha3:hash(256, <<NKey:256/big, N:256/big>>),
  Hash.

evm_revert_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SkAddr1=naddress:construct_public(1, OurChain, 4),
      SkAddr2=naddress:construct_public(1, OurChain, 5),
      Code1=eevm_asm:asm(
              [{push,1,0},
 sload,
 {push,1,1},
 add,
 {dup,1},
 {push,1,0},
 sstore,
 {push,1,0},
 mstore,

 {push,1,50}, %2
 {push,1,32},
 {push,1,0},
 {log,1},

 {push,1,32},
 {push,1,0},
 revert]
             ),
      Code2=eevm_asm:asm(
              [{push,32,16#08c379a0},
               {push,1,224},
               shl,
               {push,1,0},
               mstore,

               {push,1,32},
               {push,1,4},
               mstore,

               {push,1,6},
               {push,1,4+32},
               mstore,

               {push,32,0},
               {push,1,4+64},
               mstore,

               {push,32,binary:decode_unsigned(<<"preved">>)},
               {push,1,(256-6)*8},
               shl,
               {push,1,4+64},
               mstore,

               {push,1,4+64+32},
               {push,1,0},
               revert]
             ),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr1,
              call=>#{
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>3,
              t=>os:system_time(millisecond)
             }), Pvt1),


      TX2=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr2,
              call=>#{
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"1log">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2log">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=_Block=#{txs:=Txs1},
                    emit:=_Emit,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  {ok,Log,Txs1}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              },
              {SkAddr2,
               #{amount => #{},
                 code => Code2,
                 vm => <<"evm">>,
                 state => #{}
                }
              }
             ],
      {ok,Log,BlockTx}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      io:format("Logs ~p~n",[BlockTx]),
      ReadableLog=lists:map(
        fun(Bin) ->
            {ok,LogEntry} = msgpack:unpack(Bin),
            io:format("- ~p~n",[LogEntry]),
            LogEntry
        end, Log),
      [
       ?assertMatch([
                     [<<"1log">>,<<"evm">>, <<"revert">>, <<131073:256/big>>],
                     [<<"2log">>,<<"evm">>, <<"revert">>, _]
                    ], ReadableLog),
       ?assertMatch(true,true)
      ].

evm_log_test() ->
      OurChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SkAddr1=naddress:construct_public(1, OurChain, 4),
      Code1=eevm_asm:asm(
              [{push,1,0},
 sload,
 {push,1,1},
 add,
 {dup,1},
 {push,1,0},
 sstore,
 {push,1,0},
 mstore,

 {push,1,50}, %2
 {push,1,32},
 {push,1,0},
 {log,1},

 {push,1,32},
 {push,1,0},
 return]
             ),

      SkAddr=naddress:construct_public(1, OurChain, 5),
      Code=eevm_asm:assemble(
<<"
  push8 addr1
  push1 49
  push1 2
  push1 0
  log2

push1 0
push1 0
push1 0
push1 0
push1 0
push8 addr1
push3 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>,#{"addr1" => binary:decode_unsigned(SkAddr1)}),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SkAddr,
              call=>#{
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
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
                %function => "0x095EA7B3", %"approve(address,uint256)",
                %function => "approve(address,uint256)",
                %args => [Addr2,1024]
               },
              payload=>[
                        #{purpose=>gas, amount=>3300, cur=><<"FTT">>},
                        #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                       ],
              seq=>4,
              t=>os:system_time(millisecond)
             }), Pvt1),

      TxList1=[
               {<<"1log">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2log">>, maps:put(sigverify,#{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=_Block,
                    emit:=_Emit,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  ?assertMatch([],Failed),
                  {ok,Log}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              },
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              },
              {SkAddr,
               #{amount => #{<<"SK">> => 1},
                 code => Code,
                 vm => <<"evm">>
                }
              }
             ],
      {ok,Log}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      %io:format("Logs ~p~n",[Log]),
      ReadableLog=lists:map(
        fun(Bin) ->
            {ok,LogEntry} = msgpack:unpack(Bin),
            io:format("- ~p~n",[LogEntry]),
            LogEntry
        end, Log),
      [
       ?assertMatch([
                     [<<"1log">>,<<"evm">>, SkAddr,  _, _, [<<"1">>,SkAddr1]],
                     [<<"1log">>,<<"evm">>, SkAddr1, _, _, [<<"2">>]],
                     [<<"2log">>,<<"evm">>, SkAddr,  _, _, [<<"1">>,SkAddr1]],
                     [<<"2log">>,<<"evm">>, SkAddr1, _, _, [<<"2">>]]
                    ], ReadableLog),
       ?assertMatch(true,true)
      ].
