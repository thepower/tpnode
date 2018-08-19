-module(vm).
-export([run/3, test1/0]).

test1() ->
  run(fun(Pid) ->
          Pid ! {run, 
                 testtx(),
                 <<130,164,99,111,100,101,196,0,
                   165,115,116,97,116,101,196,69,
                   129,196,32,88,88, 88,88,88,
                   88,88,88,88,88,88,88,88,
                   88,88,88,88,88,88,88,88,
                   88,88,88,88,88,88,88,88,
                   88,88,88,196,32,89,89,89,
                   89,89,89,89,89,89,89,89,
                   89,89,89,89,89,89,89,89,
                   89,89,89,89,89,89,89,89,
                   89,89,89,89,89>>,
                 11111,
                 self()
                }
      end, "wasm", 2).


run(Fun, VmType, VmVer) ->
  case gen_server:call(tpnode_vmsrv,{pick, VmType, VmVer, self()}) of
    {ok, Pid} ->
      R=Fun(Pid),
      gen_server:cast(tpnode_vmsrv,{return,Pid}),
      R;
    Any -> Any
  end.


testtx() ->
  tx:pack(#{body =>
            base64:decode(<<"iKFrEqFmxAiAACAAAgAAA6FwkpMAo1hYWAqTAaNGRUUUonRvxAiAACAAAgAABaFzBaF0zwAAAWRBcFcXoWOSpGluaXSRzb6voWWBpGNvZGXFAukAYXNtAQAAAAEWBWABfwBgAn9/AGAAAX9gAX4BfmAAAAJMBANlbnYMX2ZpbGxfc3RydWN0AAADZW52Cl9wcmludF9zdHIAAANlbnYMc3RvcmFnZV9yZWFkAAEDZW52DXN0b3JhZ2Vfd3JpdGUAAQMHBgECAwMEAAQEAXAAAAUDAQABBykFBm1lbW9yeQIABG5hbWUABQRpbml0AAYDZ2V0AAgIZ2V0X2RhdGEACQkBAAqiAwajAQEEf0EAQQAoAgRBIGsiBTYCBCAFQRhqIgJC2rTp0qXLlq3aADcDACAFQRBqIgNC2rTp0qXLlq3aADcDACAFQQhqIgRC2rTp0qXLlq3aADcDACAFQtq06dKly5at2gA3AwAgASAFEAIgAEEYaiACKQMANwAAIABBEGogAykDADcAACAAQQhqIAQpAwA3AAAgACAFKQMANwAAQQAgBUEgajYCBAsEAEEQCzYBAX9BAEEAKAIEQSBrIgE2AgRBIBABQTBB0AAQAyABQTAQBCAAEAchAEEAIAFBIGo2AgQgAAsLACAAQoCAtPUNhAskAQF/QQBBACgCBEEgayIANgIEIABB8AAQBEEAIABBIGo2AgQLjQEBBH9BAEEAKAIEQSBrIgQ2AgQgBEEYaiIBQQApA6gBNwMAIARBEGoiAkEAKQOgATcDACAEQQhqIgNBACkDmAE3AwAgBEEAKQOQATcDACAEEAAgAEEYaiABKQMANwAAIABBEGogAikDADcAACAAQQhqIAMpAwA3AAAgACAEKQMANwAAQQAgBEEgajYCBAsLkQEFAEEQCwl0ZXN0IG5hbWUAQSALDFRFU1QgU1RSSU5HAABBMAsgQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEAQdAACyBCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQgBBkAELIEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8A">>),
            sig => [],
            ver => 2}).

