-module(contract_erltest).
-behaviour(smartcontract2).

-export([deploy/4, handle_tx/4, getters/0, get/3, info/0]).

info() ->
	{<<"erltest">>, <<"Erlang VM for unit testing">>}.

deploy(Tx, Ledger, GasLimit, _GetFun) ->
  %State0=bal:get(state, Ledger),
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      Ledger,
                      GasLimit,
                      self()
                     }
         end, "erltest", 1).

handle_tx(Tx, Ledger, GasLimit, _GetFun) ->
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      Ledger,
                      GasLimit,
                      self()
                     }
         end, "erltest", 1).
  %{ok, unchanged, GasLimit}.

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

