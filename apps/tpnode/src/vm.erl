-module(vm).
-export([run/4, test_erl/0, test_wasm/0]).

test_erl() ->
  SPid=vm_erltest:run("127.0.0.1",5555),
  timer:sleep(200),
  try
    Entropy=crypto:hash(sha256,<<"test">>),
    MeanTime=1555555555555,
    XtraFields=#{ mean_time => MeanTime, entropy => Entropy },
    Tx=tx:pack(
         tx:construct_tx(
           #{ver=>2,
             kind=>deploy,
             from=><<128,0,32,0,2,0,0,3>>,
             seq=>5,
             t=>1530106238743,
             payload=>[
                       #{amount=>10, cur=><<"XXX">>, purpose=>transfer },
                       #{amount=>20, cur=><<"FEE">>, purpose=>srcfee }
                      ],
             call=>#{function=>"init",args=>[48815]},
             txext=>#{"code"=>element(2,file:read_file("./examples/testcontract.ec"))}
            })
        ),
    run(fun(Pid) ->
            lager:info("Got worker ~p",[Pid]),
            Pid ! {run,
                   Tx,
                   msgpack:pack(#{}),
                   11111,
                   self(),
                   XtraFields
                  },
            ok
        end, "erltest", 1, [])
  after
    SPid ! stop
  end.

test_wasm() ->
  {ok,Code}=file:read_file("./examples/testcontract.wasm"),
  Tx1=tx:pack(tx:construct_tx(
               #{ver=>2,
                 kind=>deploy,
                 from=><<128,0,32,0,2,0,0,3>>,
                 seq=>5,
                 t=>1530106238743,
                 payload=>[
                           #{amount=>10, cur=><<"XXX">>, purpose=>transfer },
                           #{amount=>20, cur=><<"FEE">>, purpose=>srcfee }
                          ],
                 call=>#{function=>"init",args=>[<<512:256/big>>]},
                 txext=>#{"code"=>Code}
                })),
    Entropy=crypto:hash(sha256,<<"test">>),
    MeanTime=1555555555555,
    XtraFields=#{ mean_time => MeanTime, entropy => Entropy },
  L0=msgpack:pack(
      #{
      %"code"=><<>>,
      "state"=>msgpack:pack(#{
%                 <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">> => <<"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB">>,
%                 <<"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX">> => <<"YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY">>
                })
     }),
  {ok,#{"state":=S1}}=run(fun(Pid) ->
                              Pid ! {run, Tx1, L0, 11111, self(), XtraFields }
      end, "wasm", 2, []),

  Tx2=tx:pack(tx:construct_tx(
               #{ver=>2,
                 kind=>generic,
                 from=><<128,0,32,0,2,0,0,3>>,
                 to=><<128,0,32,0,2,0,0,3>>,
                 seq=>5,
                 t=>1530106238743,
                 payload=>[
                           #{amount=>10, cur=><<"XXX">>, purpose=>transfer },
                           #{amount=>20, cur=><<"FEE">>, purpose=>srcfee }
                          ],
                 call=>#{function=>"inc",args=>[<<1:256/big>>]}
                })),
  L1=msgpack:pack(
      #{
      "code"=>Code,
      "state"=>S1
      }),
  {ok,#{"state":=S2}=R2}=run(fun(Pid) ->
                      Pid ! {run, Tx2, L1, 11111, self(), XtraFields }
                  end, "wasm", 2, []),
%  {ok,UT2}=msgpack:unpack(Tx2),
  {msgpack:unpack(S1),
   msgpack:unpack(S2),
   R2
  }.

run(Fun, VmType, VmVer, Opts) ->
  Timeout=proplists:get_value(run_timeout, Opts, 1000),
  case gen_server:call(tpnode_vmsrv,{pick, VmType, VmVer, self()}) of
    {ok, Pid} ->
      Fun(Pid),
      R=receive {run_req, ReqNo} ->
                  receive {result, ResNo, Res} when ResNo == ReqNo ->
                            case Res of
                              pong ->
                                {ok, pong};
                              {ok, Payload, Ext} ->
                                lager:info("Contract ext ~p",[Ext]),
                                {ok,Payload};
                              {error, Err} ->
                                lager:error("Error ~p",[Err]),
                                {error, Err}
                            end
                  after Timeout ->
                          no_result
                  end
        after Timeout ->
                no_request
        end,
      gen_server:cast(tpnode_vmsrv,{return,Pid}),
      R;
    Any -> Any
  end.

