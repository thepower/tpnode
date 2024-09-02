-module(pstate_lstore).
-export([get/3,
		 patch/3
		]).

-spec get(binary(), list(), #{acc:=map()}) ->
	{value, binary()|integer()} |
	{leaf, Keys :: list()} | 
	{error, atom() }.

is_map(_,[],_) -> true;
is_map(Address, Path, State) ->
	case get(Address, {Path}, State) of
		[] ->
			is_map(Address, lists:droplast(Path), State);
		[_] ->
			false
	end.

get(Address, Path, #{getfun:=GetFun, getfunarg:=GFA, acc:=Acc}=State) ->
	case GetFun({lstore_raw,Address,Path},GFA) of
		not_found -> <<>>;
		List -> List
	end.

-spec patch(binary(), list(), #{acc:=map()}) -> {ok, map()} | {'error', atom()}.

patch(Address, Patches, #{getfun:=GetFun, getfunarg:=GFA, acc:=Acc}=State) ->
	io:format("patches ~p~n",[Patches]),

	io:format("r1 ~p~n",[get(Address,[<<"a">>,<<"b">>],State)]),

	AddrAcc1=lists:foldl(
			   fun(#{<<"p">> := Path,<<"t">> := <<"set">>,<<"v">> := Value}, A) ->
					   case is_map(lists:droplast(Path)) of
						   false ->
							   throw('non_map');
						   true ->
							   maps:put(Path, Value, A)
					   end
					   %P=GetFun({lstore,Address,{Path}},GFA),
					   %io:format("pe ~p ~p~n",[Path, P]),
					   %P1=GetFun({lstore,Address,Path},GFA),
					   %io:format("ps ~p ~p~n",[Path, P1]),
					   %A
			   end,
			   maps:get(Address,Acc,#{}),
			   Patches),
	{ok, State#{acc=>maps:put(Address,AddrAcc1,Acc)} }.

