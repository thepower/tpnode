-module(mkblock_tests).

-include_lib("eunit/include/eunit.hrl").

tx2_patch_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 1, 1>>,
  Pvt2= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 2, 2>>,
  Pvt3= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 3, 3>>,
  Pvt4= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 4, 4>>,

  GetSettings=
  fun(mychain) ->
      2;
     (settings) ->
      #{
        chains => [2],
        globals => #{<<"patchsigs">> => 2},
        keys =>
        #{ <<"node1">> => tpecdsa:calc_pub(Pvt1,true),
           <<"node2">> => tpecdsa:calc_pub(Pvt2,true),
           <<"node3">> => tpecdsa:calc_pub(Pvt3,true),
           <<"node4">> => tpecdsa:calc_pub(Pvt4,true)
         },
        nodechain => #{<<"node1">> => 0,
                       <<"node2">> => 0,
                       <<"node3">> => 0},
        <<"current">> => #{
            <<"allocblock">> =>
            #{<<"block">> => 2, <<"group">> => 10, <<"last">> => 0}
           }
       };
     ({valid_timestamp, TS}) ->
      abs(os:system_time(millisecond)-TS)<3600000
      orelse
      abs(os:system_time(millisecond)-(TS-86400000))<3600000;
     ({endless, _Address, _Cur}) ->
      false;
     (Other) ->
      error({bad_setting, Other})
  end,
  Tx=tx:construct_tx(
    #{kind=>patch,
      ver=>2,
      patches=>
      [
       #{t=>set, 
         p=>[<<"current">>, <<"testbranch">>, <<"test1">>],
         v=>os:system_time(seconds)
        }
      ]
     }
   ),
  SignTx=lists:foldl(
    fun(Key, Acc) ->
        tx:sign(Acc, Key)
    end, Tx, [Pvt1, Pvt2, Pvt3, Pvt4]),
  {ok,TX0}=tx:verify(SignTx),
  ParentHash=crypto:hash(sha256, <<"parent">>),
  GetAddr=fun test_getaddr/1,
  R1=#{block:=Block,
    failed:=Failed}=mkblock:generate_block(
                      [{<<"tx1">>, TX0}],
                      {1, ParentHash},
                      GetSettings,
                      GetAddr,
                      []),
  {Failed,Block,maps:keys(R1)}.
  %[
  % ?assertEqual([], Failed),
  % ?assertMatch(#{
  %    bals:=#{<<128, 1, 64, 0, 2, 0, 0, 1>>:=_}
  %   }, Block)
  %].


tx2_test() ->
  GetSettings=
  fun(mychain) ->
      2;
     (settings) ->
      #{
        chains => [2],
        globals => #{<<"patchsigs">> => 2},
        keys =>
        #{ <<"node1">> => crypto:hash(sha256, <<"node1">>),
           <<"node2">> => crypto:hash(sha256, <<"node2">>),
           <<"node3">> => crypto:hash(sha256, <<"node3">>),
           <<"node4">> => crypto:hash(sha256, <<"node4">>)
         },
        nodechain => #{<<"node1">> => 0,
                       <<"node2">> => 0,
                       <<"node3">> => 0},
        <<"current">> => #{
            <<"allocblock">> =>
            #{<<"block">> => 2, <<"group">> => 10, <<"last">> => 0}
           }
       };
     ({valid_timestamp, TS}) ->
      abs(os:system_time(millisecond)-TS)<3600000
      orelse
      abs(os:system_time(millisecond)-(TS-86400000))<3600000;
     ({endless, _Address, _Cur}) ->
      false;
     (Other) ->
      error({bad_setting, Other})
  end,
  GetAddr=fun test_getaddr/1,
  ParentHash=crypto:hash(sha256, <<"parent">>),

  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr= <<128,1,64,0,2,0,0,1>>,
  T1=#{
    kind => generic,
    t => os:system_time(millisecond),
    seq => 10,
    from => Addr,
    to => <<128,1,64,0,2,0,0,2>>,
    ver => 2,
    payload => [
                #{cur=><<"FTT">>,
                  amount=>10,
                  purpose=>transfer
                 }
               ]
   },
  TXConstructed=tx:sign(tx:construct_tx(T1),Pvt1),
  {ok,TX0}=tx:verify(TXConstructed,[nocheck_ledger]),
  #{block:=Block,
    failed:=Failed}=mkblock:generate_block(
                      [{<<"tx1">>, TX0}],
                      {1, ParentHash},
                      GetSettings,
                      GetAddr,
                      []),

  io:format("~p~n", [Block]),
  [
   ?assertEqual([], Failed),
   ?assertMatch(#{
      bals:=#{<<128, 1, 64, 0, 2, 0, 0, 1>>:=_}
     }, Block)
  ].

alloc_addr2_test() ->
    GetSettings=
    fun(mychain) ->
            0;
       (settings) ->
            #{chain => #{0 =>
                         #{blocktime => 10,
                           minsig => 2,
                           nodes => [<<"node1">>, <<"node2">>, <<"node3">>],
                           <<"allowempty">> => 0}
                        },
              chains => [0],
              globals => #{<<"patchsigs">> => 2},
              keys =>
              #{ <<"node1">> => crypto:hash(sha256, <<"node1">>),
                 <<"node2">> => crypto:hash(sha256, <<"node2">>),
                 <<"node3">> => crypto:hash(sha256, <<"node3">>),
                 <<"node4">> => crypto:hash(sha256, <<"node4">>)
               },
              nodechain => #{<<"node1">> => 0,
                             <<"node2">> => 0,
                             <<"node3">> => 0},
              <<"current">> => #{
                  <<"allocblock">> =>
                  #{<<"block">> => 2, <<"group">> => 10, <<"last">> => 0}
                 }
             };
       ({endless, _Address, _Cur}) ->
            false;
       (Other) ->
            error({bad_setting, Other})
    end,
    GetAddr=fun test_getaddr/1,
    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42,
            215, 220, 24, 240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246,
            158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
    Pub1=tpecdsa:calc_pub(Pvt1,true),

    T1=#{
      kind => register,
      t => os:system_time(millisecond),
      ver => 2,
      inv => <<"test">>,
      keys => [Pub1]
     },
    {ok,TX0}=tx:verify(tx:sign(tx:construct_tx(T1,[{pow_diff,8}]),Pvt1)),
    #{block:=Block,
      failed:=Failed}=mkblock:generate_block(
            [{<<"alloc_tx1_id">>, TX0}],
            {1, ParentHash},
            GetSettings,
            GetAddr,
            []),

    io:format("~p~n", [Block]),
    [
    ?assertEqual([], Failed),
    ?assertMatch(#{bals:=#{<<128, 1, 64, 0, 2, 0, 0, 1>>:=_,
                           <<128, 1, 64, 0, 2, 0, 0, 1>>:=_}
                  }, Block)
    ].


alloc_addr_test() ->
    GetSettings=
    fun(mychain) ->
            0;
       (settings) ->
            #{chain => #{0 =>
                         #{blocktime => 10,
                           minsig => 2,
                           nodes => [<<"node1">>, <<"node2">>, <<"node3">>],
                           <<"allowempty">> => 0}
                        },
              chains => [0],
              globals => #{<<"patchsigs">> => 2},
              keys =>
              #{ <<"node1">> => crypto:hash(sha256, <<"node1">>),
                 <<"node2">> => crypto:hash(sha256, <<"node2">>),
                 <<"node3">> => crypto:hash(sha256, <<"node3">>),
                 <<"node4">> => crypto:hash(sha256, <<"node4">>)
               },
              nodechain => #{<<"node1">> => 0,
                             <<"node2">> => 0,
                             <<"node3">> => 0},
              <<"current">> => #{
                  <<"allocblock">> =>
                  #{<<"block">> => 2, <<"group">> => 10, <<"last">> => 0}
                 }
             };
       ({endless, _Address, _Cur}) ->
            false;
       (Other) ->
            error({bad_setting, Other})
    end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
    Pub1=tpecdsa:calc_pub(Pvt1,true),

    TX0=tx:unpack( tx:pack( #{ type=>register, register=>Pub1 })),
    #{block:=Block,
      failed:=Failed}=mkblock:generate_block(
            [{<<"alloc_tx1_id">>, TX0},
             {<<"alloc_tx2_id">>, TX0}],
            {1, ParentHash},
            GetSettings,
            GetAddr,
            []),

    io:format("~p~n", [Block]),
    [
    ?assertEqual([], Failed),
    ?assertMatch(#{bals:=#{<<128, 1, 64, 0, 2, 0, 0, 1>>:=_,
                           <<128, 1, 64, 0, 2, 0, 0, 1>>:=_}
                  }, Block)
    ].

extcontract_test() ->
  SPid=vm_erltest:run("127.0.0.1",5555),
  timer:sleep(200),
  try
    OurChain=150,
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
                    case gen_server:call(blockchain, {get_block, H}) of
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
  GetAddr=fun test_getaddr/1,

  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,
  {ok, Code}=file:read_file("./examples/testcontract.ec"),
  TX3=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>deploy,
          from=>naddress:construct_public(SG, OurChain, 11),
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
  TX4=tx:sign(
        tx:construct_tx(#{
          ver=>2,
          kind=>generic,
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(SG, OurChain, 11),
          cur=><<"FTT">>,
          call=>#{function=>"dec",args=>[512]},
          payload=>[
                    #{purpose=>transfer, amount=>1, cur=><<"FTT">>},
                    #{purpose=>transfer, amount=>3, cur=><<"TST">>},
                    #{purpose=>gas, amount=>10, cur=><<"TST">>}, %wont be used
                    #{purpose=>gas, amount=>3, cur=><<"SK">>},
                    #{purpose=>gas, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>2, cur=><<"FTT">>}
                   ],
          seq=>2,
          t=>os:system_time(millisecond)
         }), Pvt1),
  #{block:=Block,
    emit:=Emit,
    failed:=Failed}=mkblock:generate_block(
                      [
                       {<<"3testdeploy">>, maps:put(sigverify,#{valid=>1},TX3)},
                       {<<"4testexec">>, maps:put(sigverify,#{valid=>1},TX4)}
                      ],
                      {1, ParentHash},
                      GetSettings,
                      GetAddr,
                      []),

  Success=proplists:get_keys(maps:get(txs, Block)),
  NewCallerLedger=maps:get(amount,
                           maps:get(
                             naddress:construct_public(SG, OurChain, 3), 
                             maps:get(bals, Block)
                            )
                          ),
  NewSCLedger=maps:get(
                naddress:construct_public(SG, OurChain, 11), 
                maps:get(bals, Block)
               ),
  %{ Emit, NewCallerLedger }
  io:format("Emit ~p~n",[Emit]),
  io:format("NCL  ~p~n",[NewCallerLedger]),
  [
  ?assertMatch([],Failed),
  ?assertMatch([<<"4testexec">>,<<"3testdeploy">>],Success),
  ?assertMatch(<<512:64/big>>,maps:get(state, NewSCLedger)),
  ?assertMatch(#{<<"TST">>:=29, <<"FTT">>:=111},maps:get(amount, NewSCLedger))
  ]
after
  SPid ! stop
  end.


contract_test() ->
  OurChain=150,
  GetSettings=fun(mychain) -> OurChain;
           (settings) ->
            #{
            chains => [OurChain],
            chain =>
            #{OurChain =>
            #{blocktime => 5, minsig => 2, <<"allowempty">> => 0}
             },
            globals => #{<<"patchsigs">> => 2},
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
            case gen_server:call(blockchain, {get_block, H}) of
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
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,

  _TX0=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 10),
      deploy=><<"badvm">>,
      code=><<"code">>,
      state=><<>>,
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  _TX1=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 10),
      deploy=><<"chainfee">>,
      code=>erlang:term_to_binary(#{
          interval=>10
           }),
      state=><<>>,
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  _TX2=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(SG, OurChain, 10),
      amount=>10,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>2, feecur=><<"FTT">> }),
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  _TX3=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 11),
      deploy=><<"test">>,
      code=><<>>,
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  _TX4=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(SG, OurChain, 11),
      amount=>0,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>2, feecur=><<"FTT">> }),
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  #{block:=Block,
    emit:=Emit,
    failed:=Failed}=mkblock:generate_block(
            [
             %{<<"0bad">>, _TX0},
             %{<<"1feedeploy">>, _TX1},
             %{<<"2feeexec">>, _TX2},
             {<<"3testdeploy">>, _TX3},
             {<<"4testexec">>, _TX4}
            ],
            {1, ParentHash},
            GetSettings,
            GetAddr,
             []),

  Success=proplists:get_keys(maps:get(txs, Block)),
  NewLedger=maps:without([<<160, 0, 0, 0, 0, 0, 0, 0>>,
              <<160, 0, 0, 0, 0, 0, 0, 1>>,
              <<160, 0, 0, 0, 0, 0, 0, 2>>], maps:get(bals, Block)),
  { Success, Failed, Emit, NewLedger}.

mkblock_tx2_self_test() ->
    OurChain=5,
  GetSettings=fun(mychain) ->
            OurChain;
           (settings) ->
                  #{
              chains => [0, 1],
              chain =>
              #{0 =>
                #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                1 =>
                #{blocktime => 10, minsig => 1}
               },
              globals => #{<<"patchsigs">> => 2},
              keys =>
              #{
                <<"node1">> => crypto:hash(sha256, <<"node1">>),
                <<"node2">> => crypto:hash(sha256, <<"node2">>),
                <<"node3">> => crypto:hash(sha256, <<"node3">>),
                <<"node4">> => crypto:hash(sha256, <<"node4">>)
               },
              nodechain =>
              #{
                <<"node1">> => 0,
                <<"node2">> => 0,
                <<"node3">> => 0,
                <<"node4">> => 1
               },
              <<"current">> => #{
                  <<"fee">> => #{
                      params=>#{
                        <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>>
                       },
                      <<"FTT">> => #{
                          <<"base">> => 1,
                          <<"baseextra">> => 64,
                          <<"kb">> => 10
                         }
                     }
                 }
             };
           ({endless, _Address, _Cur}) ->
            false;
           ({valid_timestamp, TS}) ->
            abs(os:system_time(millisecond)-TS)<3600000
            orelse
            abs(os:system_time(millisecond)-(TS-86400000))<3600000;
           (Other) ->
            error({bad_setting, Other})
        end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,

  TX0=tx:sign(
        tx:construct_tx(
          #{
          ver=>2,
          kind=>generic,
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          payload=>[
                    #{purpose=>transfer, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>2, cur=><<"FTT">> }
                   ],
          seq=>2,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX1=tx:sign(
        tx:construct_tx(
          #{
          from => naddress:construct_public(1, OurChain, 3),
          kind => generic,
          payload =>
          [#{amount => 10,cur => <<"FTT">>,purpose => transfer},
           #{purpose=>srcfee, amount=>1, cur=><<"FTT">> }],
          seq => 3,
          t => os:system_time(millisecond),
          to => naddress:construct_public(1, OurChain, 3),
          ver => 2}
         ), Pvt1),
  #{block:=Block,
    failed:=_Failed}=mkblock:generate_block(
            [
             {<<"0interchain">>, maps:put(sigverify,#{valid=>1},TX0)},
             {<<"1invalid">>, maps:put(sigverify,#{valid=>1},TX1)}
            ],
            {1, ParentHash},
            GetSettings,
            GetAddr,
             []),

  SignedBlock=block:sign(Block, <<1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>>),
  ?assertMatch({true, {_, _}}, block:verify(SignedBlock)),
  #{bals:=NewBals}=Block,
  lists:foreach(
    fun({K,#{amount:=V}}) ->
        io:format("Bal ~p: ~p~n", [K,V])
    end, maps:to_list(NewBals)),
  FinalBals=#{
    naddress:construct_public(1, OurChain, 3) => 
      #{<<"FTT">> => 119,<<"SK">> => 1,<<"TST">> => 26},
    naddress:construct_public(SG, OurChain, 3) => 
      #{<<"FTT">> => 98,<<"SK">> => 3,<<"TST">> => 26},
    <<160,0,0,0,0,0,0,0>> => #{<<"FTT">> => 100,<<"TST">> => 100},
    <<160,0,0,0,0,0,0,1>> => #{<<"FTT">> => 103,<<"TST">> => 100}
   },
  maps:fold(
    fun(Addr, Bal, Acc) ->
        [?assertMatch(#{Addr := #{amount:=Bal}}, maps:with([Addr],NewBals))|Acc]
    end, [], FinalBals).



mkblock_tx2_test() ->
    OurChain=5,
  GetSettings=fun(mychain) ->
            OurChain;
           (settings) ->
                  #{
              chains => [0, 1],
              chain =>
              #{0 =>
                #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                1 =>
                #{blocktime => 10, minsig => 1}
               },
              globals => #{<<"patchsigs">> => 2},
              keys =>
              #{
                <<"node1">> => crypto:hash(sha256, <<"node1">>),
                <<"node2">> => crypto:hash(sha256, <<"node2">>),
                <<"node3">> => crypto:hash(sha256, <<"node3">>),
                <<"node4">> => crypto:hash(sha256, <<"node4">>)
               },
              nodechain =>
              #{
                <<"node1">> => 0,
                <<"node2">> => 0,
                <<"node3">> => 0,
                <<"node4">> => 1
               },
              <<"current">> => #{
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
                     }
                 }
             };
           ({endless, _Address, _Cur}) ->
            false;
           ({valid_timestamp, TS}) ->
            abs(os:system_time(millisecond)-TS)<3600000
            orelse
            abs(os:system_time(millisecond)-(TS-86400000))<3600000;
           (Other) ->
            error({bad_setting, Other})
        end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,

  TX0=tx:sign(
        tx:construct_tx(
          #{
          ver=>2,
          kind=>generic,
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          payload=>[
                    #{purpose=>transfer, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>2, cur=><<"FTT">> }
                   ],
          seq=>2,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX1=tx:sign(
        tx:construct_tx(
          #{
          from => naddress:construct_public(SG, OurChain, 3),
          kind => generic,
          payload =>
          [#{amount => 9000,cur => <<"BAD">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          seq => 3,
          t => os:system_time(millisecond),
          to => naddress:construct_public(1, OurChain, 8),
          ver => 2}
         ), Pvt1),
  TX2=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain+2, 1),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 9,cur => <<"FTT">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          seq=>4,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX3=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain+2, 2),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 2,cur => <<"FTT">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          seq=>5,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX4=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(0, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 10,cur => <<"FTT">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          seq=>6,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX5=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 1,cur => <<"FTT">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          seq=>7,
          t=>os:system_time(millisecond)
         }), Pvt1),
  TX6=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 1,cur => <<"FTT">>,purpose => transfer},
           #{amount => 3,cur => <<"TST">>,purpose => srcfee}],
          seq=>8,
          t=>os:system_time(millisecond)+86400000
         }), Pvt1),
  TX7=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 1,cur => <<"FTT">>,purpose => transfer},
           #{amount => 1,cur => <<"FTT">>,purpose => srcfee}],
          txext=>#{
            big=><<"11111111111111111111111111",
                   "11111111111111111111111111",
                   "11111111111111111111111111",
                   "11111111111111111111111111",
                   "11111111111111111111111111",
                   "11111111111111111111111111">>
           },
          seq=>9,
          t=>os:system_time(millisecond)+86400000
         }), Pvt1),
  TX8=tx:sign(
        tx:construct_tx(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain, 3),
          kind=>generic,
          ver=>2,
          payload =>
          [#{amount => 1,cur => <<"FTT">>,purpose => transfer},
           #{amount => 200,cur => <<"FTT">>,purpose => srcfee}],
          seq=>9,
          t=>os:system_time(millisecond)+86400000
         }), Pvt1),
  #{block:=Block,
    failed:=Failed}=mkblock:generate_block(
            [
             {<<"1interchain">>, maps:put(sigverify,#{valid=>1},TX0)},
             {<<"2invalid">>, maps:put(sigverify,#{valid=>1},TX1)},
             {<<"3crosschain">>, maps:put(sigverify,#{valid=>1},TX2)},
             {<<"4crosschain">>, maps:put(sigverify,#{valid=>1},TX3)},
             {<<"5nosk">>, maps:put(sigverify,#{valid=>1},TX4)},
             {<<"6sklim">>, maps:put(sigverify,#{valid=>1},TX5)},
             {<<"7nextday">>, maps:put(sigverify,#{valid=>1},TX6)},
             {<<"8nofee">>, maps:put(sigverify,#{valid=>1},TX7)},
             {<<"9nofee">>, maps:put(sigverify,#{valid=>1},TX8)}
            ],
            {1, ParentHash},
            GetSettings,
            GetAddr,
             []),

  Success=proplists:get_keys(maps:get(txs, Block)),
  ?assertMatch([{<<"2invalid">>, insufficient_fund},
          {<<"5nosk">>, no_sk},
          {<<"6sklim">>, sk_limit},
          {<<"8nofee">>, {insufficient_fee, 2}},
          {<<"9nofee">>, insufficient_fund_for_fee}
         ], lists:sort(Failed)),
  ?assertEqual([
          <<"1interchain">>,
          <<"3crosschain">>,
          <<"4crosschain">>,
          <<"7nextday">>],
         lists:sort(Success)),
  ?assertEqual([
          <<"3crosschain">>,
          <<"4crosschain">>
         ],
         proplists:get_keys(maps:get(tx_proof, Block))
        ),
  ?assertEqual([
          {<<"4crosschain">>, OurChain+2},
          {<<"3crosschain">>, OurChain+2}
         ],
         maps:get(outbound, Block)
        ),
  SignedBlock=block:sign(Block, <<1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>>),
  file:write_file("tmp/testblk.txt", io_lib:format("~p.~n", [Block])),
  ?assertMatch({true, {_, _}}, block:verify(SignedBlock)),
  _=maps:get(OurChain+2, block:outward_mk(maps:get(outbound, Block), SignedBlock)),
  #{bals:=NewBals}=Block,
  FinalBals=#{
    <<128,0,0,0,5,0,0,3>> => #{amount => #{<<"FTT">> => 110,<<"SK">> => 0,<<"TST">> => 26}},
    <<128,0,32,0,5,0,0,3>> => #{amount => #{<<"FTT">> => 121,<<"SK">> => 1,<<"TST">> => 26}},
    <<128,0,32,0,5,0,0,8>> => #{amount => #{<<"FTT">> => 110,<<"SK">> => 1,<<"TST">> => 26}},
    <<128,0,32,0,7,0,0,1>> => #{amount => #{<<"FTT">> => 110,<<"SK">> => 1,<<"TST">> => 26}},
    <<128,0,32,0,7,0,0,2>> => #{amount => #{<<"FTT">> => 110,<<"SK">> => 1,<<"TST">> => 26}},
    <<128,0,96,0,5,0,0,3>> => #{amount => #{<<"FTT">> => 84,<<"SK">> => 3,<<"TST">> => 23}},
    <<160,0,0,0,0,0,0,0>> => #{amount => #{<<"FTT">> => 100,<<"TST">> => 100}},
    <<160,0,0,0,0,0,0,1>> => #{amount => #{<<"FTT">> => 103,<<"TST">> => 102}},
    <<160,0,0,0,0,0,0,2>> => #{amount => #{<<"FTT">> => 101,<<"TST">> => 101}}},
  maps:fold(
    fun(Addr, #{amount:=Bal}, Acc) ->
        [?assertMatch(#{Addr := #{amount:=Bal}}, maps:with([Addr],NewBals))|Acc]
    end, [], FinalBals).


mkblock_test() ->
    OurChain=5,
  GetSettings=fun(mychain) ->
            OurChain;
           (settings) ->
            #{
            chains => [0, 1],
            chain =>
            #{0 =>
            #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
            1 =>
            #{blocktime => 10, minsig => 1}
             },
            globals => #{<<"patchsigs">> => 2},
            keys =>
            #{
            <<"node1">> => crypto:hash(sha256, <<"node1">>),
            <<"node2">> => crypto:hash(sha256, <<"node2">>),
            <<"node3">> => crypto:hash(sha256, <<"node3">>),
            <<"node4">> => crypto:hash(sha256, <<"node4">>)
             },
            nodechain =>
            #{
            <<"node1">> => 0,
            <<"node2">> => 0,
            <<"node3">> => 0,
            <<"node4">> => 1
             },
            <<"current">> => #{
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
               }
             }
           };
           ({endless, _Address, _Cur}) ->
            false;
           ({valid_timestamp, TS}) ->
            abs(os:system_time(millisecond)-TS)<3600000
            orelse
            abs(os:system_time(millisecond)-(TS-86400000))<3600000;
           (Other) ->
            error({bad_setting, Other})
        end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
      248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
    ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,

  TX0=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>10,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>2, feecur=><<"FTT">> }),
      seq=>2,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  TX1=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 8),
      amount=>9000,
      cur=><<"BAD">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
      seq=>3,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),

  TX2=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain+2, 1),
      amount=>9,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
      seq=>4,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  TX3=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain+2, 2),
      amount=>2,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
      seq=>5,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  TX4=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(0, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>10,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
      seq=>6,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  TX5=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>1,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
      seq=>7,
      timestamp=>os:system_time(millisecond)
       }, Pvt1)
     ),
  TX6=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>1,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>3, feecur=><<"TST">> }),
      seq=>8,
      timestamp=>os:system_time(millisecond)+86400000
       }, Pvt1)
     ),
  TX7=tx:unpack(
      tx:sign(
      #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>1,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">>,
                   big=><<"11111111111111111111111111",
                      "11111111111111111111111111",
                      "11111111111111111111111111",
                      "11111111111111111111111111",
                      "11111111111111111111111111",
                      "11111111111111111111111111">>
                   }),
      seq=>9,
      timestamp=>os:system_time(millisecond)+86400000
       }, Pvt1)
     ),
  TX8=tx:unpack(
      tx:sign(
        #{
      from=>naddress:construct_public(SG, OurChain, 3),
      to=>naddress:construct_public(1, OurChain, 3),
      amount=>1,
      cur=><<"FTT">>,
      extradata=>jsx:encode(#{ fee=>200, feecur=><<"FTT">> }),
      seq=>9,
      timestamp=>os:system_time(millisecond)+86400000
       }, Pvt1)
     ),
  #{block:=Block,
    failed:=Failed}=mkblock:generate_block(
            [
             {<<"1interchain">>, maps:put(sigverify,#{valid=>1},TX0)},
             {<<"2invalid">>, maps:put(sigverify,#{valid=>1},TX1)},
             {<<"3crosschain">>, maps:put(sigverify,#{valid=>1},TX2)},
             {<<"4crosschain">>, maps:put(sigverify,#{valid=>1},TX3)},
             {<<"5nosk">>, maps:put(sigverify,#{valid=>1},TX4)},
             {<<"6sklim">>, maps:put(sigverify,#{valid=>1},TX5)},
             {<<"7nextday">>, maps:put(sigverify,#{valid=>1},TX6)},
             {<<"8nofee">>, maps:put(sigverify,#{valid=>1},TX7)},
             {<<"9nofee">>, maps:put(sigverify,#{valid=>1},TX8)}
            ],
            {1, ParentHash},
            GetSettings,
            GetAddr,
             []),

  Success=proplists:get_keys(maps:get(txs, Block)),
  ?assertMatch([{<<"2invalid">>, insufficient_fund},
          {<<"5nosk">>, no_sk},
          {<<"6sklim">>, sk_limit},
          {<<"8nofee">>, {insufficient_fee, 2}},
          {<<"9nofee">>, insufficient_fund_for_fee}
         ], lists:sort(Failed)),
  ?assertEqual([
          <<"1interchain">>,
          <<"3crosschain">>,
          <<"4crosschain">>,
          <<"7nextday">>],
         lists:sort(Success)),
  ?assertEqual([
          <<"3crosschain">>,
          <<"4crosschain">>
         ],
         proplists:get_keys(maps:get(tx_proof, Block))
        ),
  ?assertEqual([
          {<<"4crosschain">>, OurChain+2},
          {<<"3crosschain">>, OurChain+2}
         ],
         maps:get(outbound, Block)
        ),
  SignedBlock=block:sign(Block, <<1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>>),
  file:write_file("tmp/testblk.txt", io_lib:format("~p.~n", [Block])),
  ?assertMatch({true, {_, _}}, block:verify(SignedBlock)),
  _=maps:get(OurChain+2, block:outward_mk(maps:get(outbound, Block), SignedBlock)),
  #{bals:=NewBals}=Block,
  ?assertMatch(#{<<160, 0, 0, 0, 0, 0, 0, 1>>:=#{
     amount:=#{<<"FTT">>:=103, <<"TST">>:=102}}}, NewBals),
  ?assertMatch(#{<<160, 0, 0, 0, 0, 0, 0, 2>>:=#{
     amount:=#{<<"FTT">>:=101, <<"TST">>:=101}}}, NewBals),
  NewBals.

%test_getaddr%({_Addr, _Cur}) -> %suitable for inbound tx
test_getaddr(Addr) ->
  case naddress:parse(Addr) of
    #{address:=_, block:=_, group:=Grp, type:=public} ->
      #{amount => #{ <<"FTT">> => 110, <<"SK">> => Grp, <<"TST">> => 26 },
        seq => 1,
        t => 1512047425350,
        lastblk => <<0:64>>,
        changes=>[amount]
       };
    #{address:=_, block:=_, type := private} ->
      #{amount => #{
        <<"FTT">> => 100,
        <<"TST">> => 100
         },
        lastblk => <<0:64>>,
        changes=>[amount]
       }
  end.

xchain_test() ->
  OurChain=5,
  C1N1= <<1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>>,
  C1N2= <<1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
          2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2>>,
  C2N1= <<2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1>>,
  C2N2= <<2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
          2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2>>,
  InitSet=#{
        chains => [5, 6],
        chain =>
        #{5 => #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
          6 => #{blocktime => 10, minsig => 1}
         },
        globals => #{<<"patchsigs">> => 2},
        keys =>
        #{
          <<"node1">> => tpecdsa:calc_pub(C1N1,true),
          <<"node2">> => tpecdsa:calc_pub(C1N2,true),
          <<"node3">> => tpecdsa:calc_pub(C2N1,true),
          <<"node4">> => tpecdsa:calc_pub(C2N2,true)
         },
        nodechain =>
        #{
          <<"node1">> => 5,
          <<"node2">> => 5,
          <<"node3">> => 6,
          <<"node4">> => 6
         },
        <<"current">> => #{
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
               }
           }
       },
  put(ch5set,InitSet),
  put(ch6set,InitSet),
  GetSettings5=fun(mychain) -> OurChain;
                 (settings) -> get(ch5set);
                 ({endless, _Address, _Cur}) ->
                  false;
                 ({valid_timestamp, TS}) ->
                  abs(os:system_time(millisecond)-TS)<3600000
                  orelse
                  abs(os:system_time(millisecond)-(TS-86400000))<3600000;
                 (Other) ->
                  error({bad_setting, Other})
              end,
  GetSettings6=fun(mychain) -> OurChain+1;
                 (settings) -> get(ch6set);
                 ({endless, _Address, _Cur}) ->
                  false;
                 ({valid_timestamp, TS}) ->
                  abs(os:system_time(millisecond)-TS)<3600000
                  orelse
                  abs(os:system_time(millisecond)-(TS-86400000))<3600000;
                 (Other) ->
                  error({bad_setting, Other})
              end,
  GetAddr=fun test_getaddr/1,
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  ParentHash=crypto:hash(sha256, <<"parent">>),
  SG=3,

  TX1=tx:unpack(
        tx:sign(
          #{
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain+1, 1),
          amount=>9,
          cur=><<"FTT">>,
          extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
          seq=>4,
          timestamp=>os:system_time(millisecond)
         }, Pvt1)
       ),
  TX2=tx:sign(
        tx:construct_tx(
          #{
          ver=>2,
          kind=>generic,
          from=>naddress:construct_public(SG, OurChain, 3),
          to=>naddress:construct_public(1, OurChain+1, 1),
          payload=>[
                    #{purpose=>transfer, amount=>10, cur=><<"FTT">>},
                    #{purpose=>srcfee, amount=>1, cur=><<"FTT">> }
                   ],
          seq=>2,
          t=>os:system_time(millisecond)
         }), Pvt1),
    #{block:=Block1,
    failed:=Failed1}=mkblock:generate_block(
                      [
                       {<<"tx1">>, maps:put(sigverify,#{valid=>1},TX1)}
                      ],
                      {1, ParentHash},
                      GetSettings5,
                      GetAddr,
                      []),

  Success1=proplists:get_keys(maps:get(txs, Block1)),
  ?assertMatch([], lists:sort(Failed1)),
  ?assertEqual([ <<"tx1">> ], lists:sort(Success1)),
  ?assertEqual([ <<"tx1">> ],
               proplists:get_keys(maps:get(tx_proof, Block1))
              ),
  ?assertEqual([ {<<"tx1">>, OurChain+1} ],
               maps:get(outbound, Block1)
              ),
  SignedBlock1=block:sign(Block1, C1N1),
  C5NS=
  blockchain:apply_block_conf_meta(
    SignedBlock1,
    blockchain:apply_block_conf(
      SignedBlock1, 
      get(ch5set)
     )
   ),
  put(ch5set, C5NS),
  #{block:=Block2,
    failed:=[]}=mkblock:generate_block(
                      [
                       {<<"tx2">>, maps:put(sigverify,#{valid=>1},TX2)}
                      ],
                      {2, maps:get(hash,Block1)},
                      GetSettings5,
                      GetAddr,
                      []),
  SignedBlock2=block:sign(Block2, C1N1),
  FormatBS=fun(Block) ->
               settings:patch(
                 maps:get(patch,proplists:get_value(<<"outch:6">>,maps:get(settings,Block))),
                 #{})
           end,
  #{hash:=OH1}=OBlk1=maps:get(OurChain+1, block:outward_mk(maps:get(outbound, SignedBlock1), SignedBlock1)),
  #{hash:=OH2}=OBlk2=maps:get(OurChain+1, block:outward_mk(maps:get(outbound, SignedBlock2), SignedBlock2)),
  HOH1=hex:encode(OH1),
  #{block:=RBlock1,
    failed:=[]}=mkblock:generate_block(
                  [ {HOH1, OBlk1} ],
                  {1, <<0,0,0,0, 0,0,0,0>>},
                  GetSettings6,
                  GetAddr,
                  []),
  HOH2=hex:encode(OH2),
  #{failed:=[{HOH2, {block_skipped,OH1}}]}=mkblock:generate_block(
                                             [ {HOH2, OBlk2} ],
                                             {1, <<0,0,0,0, 0,0,0,0>>},
                                             GetSettings6,
                                             GetAddr,
                                             []),
  %io:format("BB ~p~n",[RBlock1bad]),
  C6NS=
  blockchain:apply_block_conf_meta(
    RBlock1,
    blockchain:apply_block_conf(
      RBlock1, 
      get(ch6set)
     )
   ),
  put(ch6set, C6NS),
  #{failed:=[{HOH1, {overdue,OH1}}]}=mkblock:generate_block(
                                       [ {HOH1, OBlk1} ],
                                       {2, maps:get(hash,RBlock1)},
                                       GetSettings6,
                                       GetAddr,
                                       []),
  #{block:=RBlock2,
    failed:=[]}=mkblock:generate_block(
                  [ {HOH2, OBlk2} ],
                  {2, maps:get(hash,RBlock1)},
                  GetSettings6,
                  GetAddr,
                  []),
  put(ch6set,InitSet),
  #{block:=_RBlock1and2,
    failed:=[]}=mkblock:generate_block(
                  [ {HOH1, OBlk1},
                    {HOH2, OBlk2} ],
                  {1, <<0,0,0,0, 0,0,0,0>>},
                  GetSettings6,
                  GetAddr,
                  []),

  FormatDBS=fun(Block) ->
                settings:patch(
                  maps:get(patch,proplists:get_value(<<"syncch:5">>,maps:get(settings,Block))),
                  #{})
            end,
  TT=proplists:get_value(<<"tx2">>,maps:get(txs,RBlock2)),
  {
   FormatBS(OBlk1),
   maps:get(hash,OBlk1),
   FormatBS(OBlk2),
   FormatDBS(RBlock1),
   FormatDBS(RBlock2),
   TT
  }.

xchain_inbound_test() ->
  BlockTx={bin2hex:dbin2hex(
               <<210, 136, 133, 138, 53, 233, 33, 79,
                 75, 12, 212, 35, 130, 40, 68, 210,
                 73, 37, 251, 211, 204, 69, 65, 165,
                 76, 171, 250, 21, 89, 208, 120, 119>>),
             #{
               hash => <<210, 136, 133, 138, 53, 233, 33, 79,
                         75, 12, 212, 35, 130, 40, 68, 210,
                         73, 37, 251, 211, 204, 69, 65, 165,
                         76, 171, 250, 21, 89, 208, 120, 119>>,
               header => #{
                 balroot => <<53, 27, 182, 176, 168, 205, 168, 137,
                              118, 192, 113, 80, 26, 8, 168, 161,
                              225, 192, 179, 64, 42, 131, 107, 119,
                              228, 179, 70, 213, 97, 142, 22, 75>>,
                 height => 3,
                 chain=>2,
                 ledger_hash => <<126, 177, 211, 108, 143, 33, 252, 102,
                                  28, 174, 183, 241, 224, 199, 53, 212,
                                  190, 109, 9, 102, 244, 128, 148, 2,
                                  141, 113, 34, 173, 88, 18, 54, 167>>,
                 parent => <<209, 98, 117, 147, 242, 200, 255, 92,
                             65, 98, 40, 145, 134, 56, 237, 108,
                             111, 31, 204, 11, 199, 110, 119, 85,
                             228, 154, 171, 52, 57, 169, 193, 128>>,
                 txroot => <<160, 75, 167, 93, 173, 15, 76, 7,
                             206, 105, 125, 171, 71, 71, 73, 183,
                             152, 20, 1, 204, 255, 238, 56, 119,
                             48, 182, 3, 128, 120, 199, 119, 132>>},
               sign => [
                        #{binextra => <<2, 33, 3, 20, 168, 140, 163, 14,
                                        5, 254, 154, 92, 115, 194, 121, 240,
                                        35, 86, 153, 104, 127, 21, 35, 19,
                                        190, 200, 202, 242, 232, 101, 102, 255,
                                        67, 64, 4, 1, 8, 0, 0, 1,
                                        97, 216, 215, 132, 30, 3, 8, 0,
                                        0, 0, 0, 0, 54, 225, 28>>,
                          extra => [
                                    {pubkey, <<3, 20, 168, 140, 163, 14, 5,
                                               254, 154, 92, 115, 194, 121, 240, 35,
                                               86, 153, 104, 127, 21, 35, 19, 190,
                                               200, 202, 242, 232, 101, 102, 255, 67,
                                               64, 4>>},
                                    {timestamp, 1519761458206},
                                    {createduration, 3596572}],
                          signature => <<48, 69, 2, 32, 46, 71, 177, 112,
                                         252, 81, 176, 202, 73, 216, 45, 248,
                                         150, 187, 65, 47, 123, 172, 210, 59,
                                         107, 36, 166, 151, 105, 73, 39, 153,
                                         189, 162, 165, 12, 2, 33, 0, 239,
                                         133, 205, 191, 10, 54, 223, 131, 75,
                                         133, 178, 226, 150, 62, 90, 197, 191,
                                         170, 185, 190, 202, 84, 234, 147, 154,
                                         200, 78, 180, 196, 145, 135, 30>>},
                        #{
                            binextra => <<2, 33, 2, 242, 87, 82, 248, 198,
                                          80, 15, 92, 32, 167, 94, 146, 112,
                                          70, 81, 54, 120, 236, 25, 141, 129,
                                          124, 215, 7, 210, 142, 51, 139, 230,
                                          86, 0, 245, 1, 8, 0, 0, 1,
                                          97, 216, 215, 132, 25, 3, 8, 0,
                                          0, 0, 0, 0, 72,
                                          145, 55>>,
                            extra => [
                                      {pubkey, <<2, 242, 87, 82, 248, 198, 80,
                                                 15, 92, 32, 167, 94, 146, 112, 70,
                                                 81, 54, 120, 236, 25, 141, 129, 124,
                                                 215, 7, 210, 142, 51, 139, 230, 86,
                                                 0, 245>>},
                                      {timestamp, 1519761458201},
                                      {createduration, 4755767}],
                            signature => <<48, 69, 2, 33, 0, 181, 13, 206,
                                           186, 91, 46, 248, 47, 86, 203, 119,
                                           163, 182, 187, 224, 19, 148, 186, 230,
                                           192, 77, 37, 78, 34, 159, 0, 129,
                                           20, 44, 94, 100, 222, 2, 32, 17,
                                           113, 133, 105, 203, 59, 196, 83, 152,
                                           48, 93, 234, 94, 203, 198, 204, 37,
                                           71, 163, 102, 116, 222, 108, 244, 177,
                                           171, 121, 241, 78, 236, 20, 49>>}
                       ],
               tx_proof => [
                            {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                             {<<140, 165, 20, 175, 211, 221, 34, 143,
                                206, 26, 228, 214, 78, 239, 204, 117,
                                248, 243, 84, 232, 154, 163, 25, 31,
                                161, 244, 123, 77, 137, 49, 211, 190>>,
                              <<227, 192, 87, 99, 22, 171, 181, 153,
                                82, 253, 22, 226, 105, 155, 190, 217,
                                40, 167, 35, 76, 231, 83, 145, 17,
                                235, 226, 202, 176, 88, 112, 164, 75>>}}],
               txs => [
                       {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                        #{amount => 10, cur => <<"FTT">>,
                          extradata =>
                          <<"{\"message\":\"preved from test_xchain_tx to ",
                            "AA100000001677721780\"}">>,
                          from => <<128, 1, 64, 0, 2, 0, 0, 1>>,
                          seq => 1,
                          sig =>
                          #{<<3, 106, 33, 240, 104, 190, 146, 105,
                              114, 104, 182, 13, 150, 196, 202, 147,
                              5, 46, 193, 4, 228, 158, 0, 58,
                              226, 196, 4, 249, 22, 134, 67, 114, 244>> =>
                            <<48, 69, 2, 33, 0, 137, 129, 11,
                              184, 226, 47, 248, 169, 88, 87, 235,
                              54, 114, 41, 218, 54, 208, 110, 177,
                              156, 86, 154, 57, 168, 248, 135, 234,
                              133, 48, 122, 162, 159, 2, 32, 111,
                              74, 165, 165, 165, 20, 39, 231, 137,
                              198, 69, 97, 248, 202, 129, 61, 131,
                              85, 115, 106, 71, 105, 254, 113, 106,
                              128, 151, 224, 154, 162, 163, 161>>},
                          timestamp => 1519761457746,
                          to => <<128, 1, 64, 0, 1, 0, 0, 1>>,
                          type => tx}}]}
            },

    ParentHash= <<0, 0, 0, 0, 1, 1, 1, 1,
                  2, 2, 2, 2, 3, 3, 3, 3,
                  0, 0, 0, 0, 1, 1, 1, 1,
                  2, 2, 2, 2, 3, 3, 3, 3>>,
    GetSettings=fun(mychain) ->
                        1;
                   (settings) ->
                        #{chain =>
                          #{1 => #{blocktime => 2, minsig => 2, <<"allowempty">> => 0},
                            2 => #{blocktime => 2, minsig => 2, <<"allowempty">> => 0}},
                          chains => [1, 2],
                          globals => #{<<"patchsigs">> => 4},
                          keys =>
                          #{<<"c1n1">> => <<2, 6, 167, 57, 142, 3, 113, 35,
                                            25, 211, 191, 20, 246, 212, 125, 250,
                                            157, 15, 147, 0, 243, 194, 122, 10,
                                            100, 125, 146, 90, 94, 200, 163, 213,
                                            219>>,
                            <<"c1n2">> => <<3, 49, 215, 116, 73, 54, 27, 41,
                                            144, 13, 76, 183, 209, 15, 238, 61,
                                            231, 222, 154, 116, 37, 161, 113, 159,
                                            2, 37, 130, 166, 140, 176, 51, 183,
                                            170>>,
                            <<"c1n3">> => <<2, 232, 199, 219, 27, 18, 156, 224,
                                            149, 39, 153, 173, 87, 46, 204, 64,
                                            247, 2, 124, 209, 4, 156, 168, 33,
                                            95, 67, 253, 87, 225, 62, 85, 250,
                                            63>>,
                            <<"c2n1">> => <<3, 20, 168, 140, 163, 14, 5, 254,
                                            154, 92, 115, 194, 121, 240, 35, 86,
                                            153, 104, 127, 21, 35, 19, 190, 200,
                                            202, 242, 232, 101, 102, 255, 67, 64,
                                            4>>,
                            <<"c2n2">> => <<3, 170, 173, 144, 22, 230, 53, 155,
                                            16, 61, 0, 29, 207, 156, 35, 78,
                                            48, 153, 163, 136, 250, 63, 111, 164,
                                            34, 28, 239, 85, 113, 11, 33, 238,
                                            173>>,
                            <<"c2n3">> => <<2, 242, 87, 82, 248, 198, 80, 15,
                                            92, 32, 167, 94, 146, 112, 70, 81,
                                            54, 120, 236, 25, 141, 129, 124, 215,
                                            7, 210, 142, 51, 139, 230, 86, 0,
                                            245>>},
                          nodechain =>
                          #{<<"c1n1">> => 1, <<"c1n2">> => 1, <<"c1n3">> => 1,
                            <<"c2n1">> => 2, <<"c2n2">> => 2, <<"c2n3">> => 2},
                          <<"current">> =>
                          #{<<"allocblock">> =>
                            #{<<"block">> => 1, <<"group">> => 10, <<"last">> => 1}}};
                   ({endless, _Address, _Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting, Other})
                end,
    GetAddr=fun test_getaddr/1,

    #{block:=#{hash:=NewHash,
               header:=#{height:=NewHeight}}=Block,
      failed:=Failed}=mkblock:generate_block(
                        [BlockTx],
                        {1, ParentHash},
                        GetSettings,
                        GetAddr,
             []),

%        SS1=settings:patch(AAlloc, SetState),
    GetSettings2=fun(mychain) ->
                        1;
                   (settings) ->
                         lists:foldl(
                           fun(Patch, Acc) ->
                                   settings:patch(Patch, Acc)
                           end, GetSettings(settings), maps:get(settings, Block));
                   ({endless, _Address, _Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting, Other})
                end,
    #{block:=Block2,
      failed:=Failed2}=mkblock:generate_block(
                         [BlockTx],
                         {NewHeight, NewHash},
                         GetSettings2,
                         GetAddr,
            []),

    [
    ?assertEqual([], Failed),
    ?assertMatch([
                  {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                   #{amount:=10}
                  }
                 ], maps:get(txs, Block)),
    ?assertMatch(#{amount:=#{<<"FTT">>:=120}},
                 maps:get(<<128, 1, 64, 0, 1, 0, 0, 1>>, maps:get(bals, Block))
                ),
    ?assertMatch([], maps:get(txs, Block2)),
    ?assertMatch([{_, {overdue, _}}], Failed2)
    ].

