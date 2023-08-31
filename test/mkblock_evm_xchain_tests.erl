-module(mkblock_evm_xchain_tests).

-export([mk_oubound/0, evm_contract_store/0]).
-include_lib("eunit/include/eunit.hrl").

evm_contract_store() ->
  % this contract loads value of storage with key 0x01, increments it,
  % stores it back and returns it
  eevm_asm:asm([{push,1,0},
                sload,
                {push,1,1},
                add,
                {dup,1},
                {push,1,0},
                sstore,
                {dup,1},
                {push,1,0},
                mstore,

                {dup,1},
                sstore,

                {push,1,50}, %2
                {push,1,32},
                {push,1,0},
                {log,1},

                {push,1,32},
                {push,1,0},
                return]).

evm_log_test() ->
      OurChain=150,
      SkAddr1=naddress:construct_public(1, OurChain, 1),
      Code1=evm_contract_store(),

      {ok,TX1,From}=mk_oubound(),

      TxList1=[
               {<<"inbound_block1">>, maps:put(sigverify,#{valid=>1},TX1)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    log:=Log,
                    failed:=Failed}) ->
                  io:format("Failed ~p~n",[Failed]),
                  {ok,Log,Failed,Block}
              end,
      Ledger=[
              {SkAddr1,
               #{amount => #{},
                 code => Code1,
                 vm => <<"evm">>,
                 state => #{ <<0>> => <<2,0,0>> }
                }
              }
             ],
      {ok,Log,Failed,Blk}=extcontract_template(OurChain, TxList1, Ledger, TestFun),
      ReadableLog=lists:map(
        fun(Bin) ->
            {ok,LogEntry} = msgpack:unpack(Bin),
            io:format("- ~p~n",[LogEntry]),
            LogEntry
        end, Log),
      OWB=block:outward_chain(Blk,151),
      [
       ?assertMatch([],Failed),
       ?assertMatch([
                     [<<"1xccall1">>,<<"evm">>, SkAddr1, From, _, [<<"2">>]]
                    ], ReadableLog),
       ?assertMatch({_,#{payload:=[#{amount:=_2511}]}}, hd(maps:get(txs,OWB))),
       ?assertMatch(true,true)
      ].

mk_oubound() ->
      OurChain=151,
      SCChain=150,
      Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
              248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
      Addr1=naddress:construct_public(1, OurChain, 1),
      SCAddr=naddress:construct_public(1, SCChain, 1),

      TX1=tx:sign(
            tx:construct_tx(#{
              ver=>2,
              kind=>generic,
              from=>Addr1,
              to=>SCAddr,
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
              to=>Addr1,
              payload=>[ #{purpose=>srcfee, amount=>2, cur=><<"FTT">>} ],
              seq=>4,
              t=>os:system_time(millisecond)+1
             }), Pvt1),

      TxList1=[
               {<<"1xccall1">>, maps:put(sigverify,#{valid=>1},TX1)},
               {<<"2local">>, maps:put(sigverify, #{valid=>1},TX2)}
              ],
      TestFun=fun(#{block:=Block,
                    emit:=_Emit,
                    log:=_Log,
                    failed:=_Failed}) ->
                  {ok,block:outward_chain(Block,150),Addr1}
              end,
      Ledger=[
              {Addr1,
               #{amount => #{ <<"FTT">> => 1000000, <<"SK">> => 3, <<"TST">> => 26 }}
              }
             ],
      extcontract_template(OurChain, TxList1, Ledger, TestFun).

extcontract_template(OurChain, TxList, Ledger, CheckFun) ->
  try
  Test=fun(LedgerPID) ->
           MeanTime=os:system_time(millisecond),
           Entropy=crypto:hash(sha256,<<"test1">>),

           GetSettings=fun(mychain) -> OurChain;
                          (settings) ->
                           settings:upgrade(
                           #{
                             chains => [150,151],
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
                            });
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

