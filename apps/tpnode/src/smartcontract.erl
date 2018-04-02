-module(smartcontract).
-export([run/5]).

-callback deploy(Address :: binary(), 
				 Ledger :: map(),
				 Code :: binary(), 
				 State :: binary()|undefined,
				 GasLimit :: integer(),
				 GetFun :: fun()) -> 
	{'ok', NewLedger :: map()}.

-callback handle_tx(Tx :: binary(),
					Ledger :: map(),
					GasLimit :: integer(),
					GetFun :: fun()) -> 
	{'ok',  %success finish, emit new txs
	 NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
	 GasUsed :: integer(),
	 EmitTxs :: list()
	} |
	{'ok',  %success finish
	 NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
	 GasUsed :: integer()
	} | 
	{'error', %error during execution
	 Reason :: 'insufficient_gas' | string(),
	 GasUsed :: integer()
	} | 
	{'error', %error during start
	 Reason :: string()
	}.

run(VMType, #{to:=To}=Tx, Ledger, GasLimit, GetFun) ->
	VM=try 
		   erlang:binary_to_existing_atom(<<"contract_",VMType/binary>>,utf8)
	   catch error:badarg ->
				 throw('unknown_vm')
	   end,
	lager:info("run contract ~s for ~s", [VM,naddress:encode(To)]),
	try
		case erlang:apply(VM,
						  handle_tx,
						  [Tx, Ledger, GasLimit, GetFun]) of
			{ok, NewState, GasUsed, EmitTxs} when 
				  NewState==unchanged orelse is_binary(NewState) ->
				if NewState == unchanged ->
					   {Ledger, EmitTxs, GasUsed};
				   true ->
					   {
						bal:put(state, NewState, Ledger),
						EmitTxs, GasUsed}
				end;
			{ok, NewState, GasUsed} when 
				  NewState==unchanged orelse is_binary(NewState) ->
				if NewState == unchanged ->
					   {Ledger, [], GasUsed};
				   true ->
					   {
						bal:put(state, NewState, Ledger),
						[], GasUsed}
				end;
			{error, Reason, GasUsed} ->
				%throw({'run_failed',Reason});
				lager:error("Contract error ~p",[Reason]),
				{Ledger, [], GasUsed};
			{error, Reason} ->
				throw({'run_failed',Reason});
			Any ->
				lager:error("Contract return error ~p",[Any]),
				throw({'run_failed',other})
		end
	catch Ec:Ee ->
			  S=erlang:get_stacktrace(),
			  lager:error("Can't run contract ~p:~p @ ~p",
						  [Ec,Ee,hd(S)]),
			  throw({'contract_error',[Ec,Ee]})
	end.
	
