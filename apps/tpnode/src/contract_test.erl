-module(contract_test).
-behaviour(smartcontract).

-export([deploy/6, handle_tx/4]).

deploy(_Address, _Ledger, _Code, _State, _GasLimit, _GetFun) -> 
	{ok, term_to_binary(#{
		   amount=>5,
		   token=><<"FTT">>
		  })}.

handle_tx(#{from:=From,to:=MyAddr}=_Tx, Ledger, _GasLimit, _GetFun) -> 
	lager:info("I going to emit tx to sender"),
	MyState=bal:get(state, Ledger),
	#{amount:=A,token:=T}=State=erlang:binary_to_term(MyState,[safe]),
	LS=max(bal:get(seq,Ledger),maps:get(seq,State,0)),
	{NewLS,TXs}=lists:foldl(
				  fun(Wallet,{SI,Acc1}) ->
						  {SI+1,
						   [#{
							 from=>MyAddr,
							 to=>Wallet,
							 cur=>T,
							 amount=>A,
							 seq=>SI+1,
							 timestamp=>0
							}|Acc1]}
				  end, {LS,[]}, [From]),
	TXs1=lists:reverse(TXs),
	{ok, erlang:term_to_binary(
		   State#{
			 seq=>NewLS
			}), 0, TXs1}.

