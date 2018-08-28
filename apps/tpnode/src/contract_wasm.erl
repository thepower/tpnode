-module(contract_wasm).
-behaviour(smartcontract2).

-export([deploy/4, handle_tx/4, getters/0, get/3, info/0]).

info() ->
	{<<"wasm">>, <<"WebAssembly">>}.

deploy(Tx, Ledger, GasLimit, _GetFun) ->
  %State0=bal:get(state, Ledger),
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      bal:pack(Ledger),
                      GasLimit,
                      self()
                     }
         end, "wasm", 2, []).

handle_tx(Tx, Ledger, GasLimit, _GetFun) ->
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      bal:pack(Ledger),
                      GasLimit,
                      self()
                     }
         end, "wasm", 2, []).
  %{ok, unchanged, GasLimit}.

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

