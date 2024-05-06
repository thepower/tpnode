-module(contract_wasm).
-behaviour(smartcontract2).

-export([deploy/5, handle_tx/5, getters/0, get/3, info/0]).

info() ->
	{<<"wasm">>, <<"WebAssembly">>}.

deploy(Tx, Ledger, GasLimit, GetFun, Opaque) ->
  handle_tx(Tx, Ledger, GasLimit, GetFun, Opaque).

handle_tx(Tx, Ledger, GasLimit, GetFun, _Opaque) ->
  throw(wasm_vm_broken),
  %io:format("wasm Opaque ~p~n",[_Opaque]),
  %Storage=lists:foldl(
  %          fun({state,K,V},A) ->
  %              maps:put(K,V,A)
  %          end,#{},
  %          mledger:get_kpvs(maps:get(to,Tx),state,'_')
  %         ),
  %logger:notice("storage retrival hack for wasm contract ~p",maps:get(to,Tx)),
  %Ledger=maps:put(state,Storage,Ledger0),
  Entropy=GetFun(entropy),
  MeanTime=GetFun(mean_time),
  Settings=GetFun(settings),
  XtraFields=#{ "mean_time" => MeanTime,
                "entropy" => Entropy },
  vm:run(fun(VMPid) ->
             VMPid ! {run, 
                      tx:pack(Tx),
                      mbal:pack(Ledger),
                      GasLimit,
                      self(),
                      XtraFields
                     }
         end, "wasm", 2, [
                          {run_timeout, chainsettings:get(
                                          <<"blocktime">>,
                                          Settings,
                                          fun() -> GetFun(mychain) end
                                         )*1000}
                         ]).

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

