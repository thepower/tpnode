-module(contract_wasm).
-behaviour(smartcontract2).

-export([deploy/4, handle_tx/4, getters/0, get/3, info/0]).

info() ->
	{<<"wasm">>, <<"WebAssembly">>}.

deploy(Tx, Ledger, GasLimit, GetFun) ->
  handle_tx(Tx, Ledger, GasLimit, GetFun).

handle_tx(Tx, Ledger, GasLimit, GetFun) ->
  Entropy=GetFun(entropy),
  MeanTime=GetFun(mean_time),
  Settings=GetFun(settings),
  XtraFields=#{ "mean_time" => MeanTime,
                "entropy" => Entropy },
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      bal:pack(Ledger),
                      GasLimit,
                      self(),
                      XtraFields
                     }
         end, "wasm", 2, [
                          {run_timeout, chainsettings:get(blocktime,Settings)*1000}
                         ]).

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

