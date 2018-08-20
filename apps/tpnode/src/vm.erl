-module(vm).
-export([run/3, test_erl/0, test_wasm/0, teststate/0]).

test_erl() ->
  SPid=vm_erltest:run("127.0.0.1",5555),
  timer:sleep(200),
  try
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

    ok=run(fun(Pid) ->
               lager:info("Got worker ~p",[Pid]),
               Pid ! {run, 
                      Tx,
                      msgpack:pack(#{}),
                      11111,
                      self()
                     },
               ok
           end, "erltest", 1),
    receive {run_req, ReqNo} ->
              receive {result, ResNo, Res, Delay} when ResNo == ReqNo ->
                        lager:info("Contract delay ~p ms",[Delay/1000000]),
                        Res
              after 1000 ->
                      no_result
              end
    after 5000 ->
            no_request
    end
  after
    SPid ! stop
  end.


test_wasm() ->
  run(fun(Pid) ->
          Pid ! {run, 
                 testtx(),
                 teststate(), 
                 11111,
                 self()
                }
      end, "wasm", 2),
  receive {run_req, ReqNo} ->
            receive {result, ResNo, Res, Delay} when ResNo == ReqNo ->
                      lager:info("Contract delay ~p ms",[Delay/1000000]),
                      Res
            after 1000 ->
                    no_result
            end
  after 5000 ->
          no_request
  end.


run(Fun, VmType, VmVer) ->
  case gen_server:call(tpnode_vmsrv,{pick, VmType, VmVer, self()}) of
    {ok, Pid} ->
      R=Fun(Pid),
      gen_server:cast(tpnode_vmsrv,{return,Pid}),
      R;
    Any -> Any
  end.


teststate() ->
  msgpack:pack(
    #{
    %"code"=><<>>,
    "state"=>msgpack:pack(#{
               %<<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">> =>
               %<<"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB">>,
               %<<"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX">> =>
               %<<"YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY">>
              })
   }).

testtx() ->
  Tx=tx:construct_tx(
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
         txext=>#{"code"=>element(2,file:read_file("../wanode/test1.wasm"))}
        }),
  tx:pack(Tx).

