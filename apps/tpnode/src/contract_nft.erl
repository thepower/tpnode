-module(contract_nft).
-behaviour(smartcontract).

-export([deploy/6, handle_tx/4, getters/0, get/3, info/0]).

info() ->
	{<<"nft">>, <<"non-fungible tokens">>}.

deploy(_Address, _Ledger, Code, _State, _GasLimit, _GetFun) ->
	#{owner:=Owner,
		name:=TokenName}=erlang:binary_to_term(Code, [safe]),
	{ok, term_to_binary(#{
				 owner=>Owner,
				 token=>TokenName
				})}.

handle_tx(#{to:=MyAddr}=_Tx, Ledger, _GasLimit, GetFun) ->
	MyState=bal:get(state, Ledger),
	#{interval:=Int, last_h:=LH}=State=erlang:binary_to_term(MyState, [safe]),
	#{header:=#{height:=CurHeight}}=GetFun({get_block, 0}),
	lager:info("chainfee ~p ~w", [State, CurHeight-(LH+Int)]),
	if CurHeight>=LH+Int ->
		   Collected=maps:get(amount, Ledger),
		   LS=max(bal:get(seq, Ledger), maps:get(seq, State, 0)),
		   Nodes=lists:foldl(
			 fun(N, Acc) ->
					 Blk=GetFun({get_block, N}),
					 ED=maps:get(extdata, Blk, []),
					 F=fun(Found) ->
							   if Acc==undefined ->
									  lists:foldl(
										fun(E, A) ->
												maps:put(E, 1, A)
										end, #{}, Found);
								  true ->
									  lists:foldl(
										fun(E, A) ->
												maps:put(E, 1+maps:get(E, A, 0), A)
										end, Acc, Found)
							   end
					   end,
					 case proplists:get_value(<<"prevnodes">>, ED) of
						 undefined ->
							 case proplists:get_value(prevnodes, ED) of
								 undefined ->
									 Acc;
								 Found ->
									 F(Found)
							 end;
						 Found ->
							 F(Found)
					 end
			 end, undefined, lists:seq(0, Int-1)),
		   MaxN=maps:fold(
				  fun(_, V, A) when V>A -> V;
					 (_, _, A) -> A
				  end, 0, Nodes),
		   Worthy=maps:fold(
					fun(K, V, A) ->
							if(V==MaxN)->
								  Wallet=settings:get(
										   [<<"current">>, <<"rewards">>, K],
										   GetFun(settings)),
								  if is_binary(Wallet) ->
										 [Wallet|A];
									 true -> A
								  end;
							  true ->
								  A
							end
					end, [], Nodes),
		   lager:info("collected ~p for ~p", [Collected, Worthy]),
		   WL=length(Worthy),
		   if WL>0 ->
				  {NewLS, TXs}=maps:fold(
								fun(Token, Amount, Acc) ->
										Each=trunc(Amount/WL),
										lists:foldl(
										  fun(Wallet, {SI, Acc1}) ->
												  {SI+1,
												   [#{
													 from=>MyAddr,
													 to=>Wallet,
													 cur=>Token,
													 amount=>Each,
													 seq=>SI+1,
													 timestamp=>0
													}|Acc1]}
										  end, Acc, Worthy)
								end, {LS, []}, Collected),
				  TXs1=lists:reverse(TXs),
				  {ok, erlang:term_to_binary(
						 State#{
						   last_h=>CurHeight,
						   seq=>NewLS
						  }), 0, TXs1};
			  true ->
				  {ok, erlang:term_to_binary(
						 State#{
						   last_h=>CurHeight,
						   seq=>LS
						  }), 0, []}
		   end;
	   true ->
		   {ok, unchanged, 0}
	end.

getters() ->
	[{<<"collected">>,[]},
	 {<<"sum">>,[{<<"Первое слагаемое"/utf8>>,int},{<<"Второе слагаемое"/utf8>>,int}]}
	].

get(<<"sum">>,[A,B],_Ledger) ->
	A+B;

get(<<"collected">>,[],Ledger) ->
	MyState=bal:get(state, Ledger),
	lager:info("Called ~p",[maps:keys(Ledger)]),
	#{last_h:=LH}=erlang:binary_to_term(MyState, [safe]),
	Collected=maps:get(amount, Ledger),
	#{last_height=>LH,
		collected=>Collected};

get(_,_,_Ledger) ->
	throw("unknown method").


