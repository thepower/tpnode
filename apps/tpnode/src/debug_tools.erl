-module(debug_tools).
-export([display_address_storage/2]).
-export([compare_pstate/2]).


transform_code(undefined) ->
  undefined;
transform_code(<<>>) ->
  <<"empty">>;

transform_code(Code) when is_binary(Code) ->
  list_to_binary(
    [
     integer_to_list( size(Code)),
     " bytes ",
     hex:encodex(crypto:hash(sha256,Code))
    ]).

strip_code(#{{code,[]}:={Code1,Code2}}=Acc) when is_binary(Code1)->
  maps:put({code,[]}, {transform_code(Code1), transform_code(Code2)},Acc);
strip_code(#{{code,[]}:=Code}=Acc) when is_binary(Code)->
  maps:put({code,[]}, transform_code(Code),Acc);

strip_code(Any) -> Any.


compare_pstate(S0, S1) when S0==S1 ->
  #{};

compare_pstate(S0, S1) ->
  Keys=lists:usort(maps:keys(S0)++maps:keys(S1)),
  %io:format("compare_pstate keys ~p~n",[Keys]),
  lists:foldl(
    fun(Key, A) ->
        V0=maps:get(Key,S0,undefined),
        V1=maps:get(Key,S1,undefined),
        if V0==V1 ->
            A;
          is_map(V0) andalso is_map(V1) ->
            maps:put(Key,compare_pstate(V0,V1),A);
          true ->
            maps:put(Key,{strip_code(V0),strip_code(V1)},A)
        end
    end, #{}, Keys).

dpad(N) ->
	lists:flatten([ "| " || _ <- lists:seq(1,N) ]).

display_node(Depth, {address_storage,_,<<"R">>,{Number,<<K0,V/binary>>=Goto}}) ->
	io:format("~sRoot ~w members root Node ~s ~p~n",
			  [ dpad(Depth), Number, [K0], sext:decode(V) ]),
	[Goto];

display_node(Depth, {address_storage,_,<<"L",_K/binary>>,{Key,B1,_Hash}}) ->
	%io:format("Leaf ~p = ~p~n\t~p~n\tH:~s~n",
	%		  [ sext:decode(K) ,
	%			sext:decode(Key) ,
	%			sext:decode(B1),
	%			hex:encode(_Hash)
	%		  ]),

	io:format("~sLeaf ~p~n\t~p~n",
			  [ dpad(Depth), 
				sext:decode(Key) ,
				sext:decode(B1)
			  ]),
	[];

display_node(Depth, {address_storage,_,<<"N",_K/binary>>,
			  {Key,_Hash,
			   <<LKind,ChL/binary>>=Go1,
			   <<RKind,ChR/binary>>=Go2}}) ->
	%io:format("Node ~p = ~p~n\t Left ~s:~s ~p~n\tRight ~s:~s ~p~n\tH:~s~n",
	%		  [
	%		   sext:decode(K) ,
	%		   sext:decode(Key) ,
	%		   [LKind], hex:encode(ChL), sext:decode(ChL),
	%		   [RKind], hex:encode(ChR), sext:decode(ChR),
	%		   hex:encode(_Hash)
	%		  ]),

	io:format("~sNode ~p~n\t Left ~s: ~p~n\tRight ~s: ~p~n",
			  [ dpad(Depth), 
			   sext:decode(Key) ,
			   [LKind], sext:decode(ChL),
			   [RKind], sext:decode(ChR)
			  ]),
	[Go1,Go2].

display_sorted(_Depth, _,[]) ->
	[];
display_sorted(Depth, Key,List) ->
	case 
		lists:keyfind(Key,3,List)
	of false ->
		   List;
	   Exists ->
		   Goto=display_node(Depth, Exists),
		   lists:foldl(
			 fun(Go, ListAcc) ->
					 display_sorted(Depth+1, Go, ListAcc)
			 end, List -- [Exists],
			 Goto)
	end.

display_address_storage(DBName, Address) ->
	S=rockstable:get(DBName, undefined,  {address_storage,Address,'_','_'}),
	io:format("-- [ storage for address ~s ] --~n",[hex:encodex(Address)]),
	Left=display_sorted(0, <<"R">>,S),
	if Left==[] -> ok;
	   true ->
		   io:format("-- [ out of tree ] --~n"),
		   lists:foreach(
			 fun(Node) ->
					 display_node(0,Node)
			 end, S)
	end,
	io:format("-- [ end ] --~n").

