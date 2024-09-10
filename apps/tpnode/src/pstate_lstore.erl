-module(pstate_lstore).
-include_lib("eunit/include/eunit.hrl").
-export([get/3,
		 patch/3
		]).

% lstore is a hierarchical structure that might be represented as tree
% each leaf has a path and value.
% Path is list of binaries and/or non negative integers
% Value might be integer, binary or list (list of integers or binaries)
% modification methods for non list leafs:
% - set
% - delete
% modification methods for list leafs:
% - lcleanup
% - add
% - remove
%
% verify methods for non list leafs:
% - exists
% - compare
% verify methods for list leafs:
% - member
%
% when creating any leaf node check that it's no child of any other leaf
% user should never expect that list's node keep order of elements

is_leaf([], AddrAcc, _) -> {false,AddrAcc};
is_leaf(Path, AddrAcc, {Address, GetFun, GFA}=Handler) ->
	case maps:get({lstore,Path}, AddrAcc, undefined) of
		{undefined, undefined} ->
			is_leaf(lists:droplast(Path),
					AddrAcc,
					Handler);
		{V0,undefined} ->
			{true, V0, AddrAcc};
		{_,V1} ->
			{true, V1, AddrAcc};
		undefined ->
			R=GetFun({lstore_raw,Address,{Path}},GFA),
			case R of
				[] ->
					is_leaf(lists:droplast(Path), AddrAcc, Handler);
				[{_,Val}] when is_list(Val); is_binary(Val); is_integer(Val) ->
					{true, Val, AddrAcc}
			end
	end.

-spec get(binary(), list(), #{acc:=map()}) ->
	{
	 binary()|integer()|map()|[binary()|integer()],
	 boolean(),
	State1::map()}.

response_get(Resp, Cached, State) ->
	{Resp, Cached, State}.

get(Address, Path, #{getfun:=GetFun, getfunarg:=GFA, acc:=Acc}=State) ->
	AddrAcc=maps:get(Address,Acc,#{}),
	AccLStore=maps:get(lstore_map,AddrAcc,#{}),
	case maps:is_key({lstore,Path}, AddrAcc) of
		true ->
			CacheGot=settings:get(Path, AccLStore),
			response_get(CacheGot, true, State);
		false ->
			DataGot=GetFun({lstore_raw,Address,Path},GFA),
			GotMap=lists:foldl(
					 fun({P,V}, LAcc) ->
							 settings:set(P,V,LAcc) end,
					 #{},
					 DataGot),
			HasChildren=lists:foldl(
						  fun(_, true) -> true;
							 ({P,_}, false) ->
								  (length(P) > length(Path))
						  end,
						  false,
						  DataGot),
			AccLStore1=settings:merge(
						 GotMap,
						 AccLStore
						),
			AddrAcc1 = if HasChildren ->
							  maps:put({lstore,Path},{undefined,undefined},
									   AddrAcc#{
										 lstore_map=>AccLStore1
										});
						  true ->
							  AddrAcc#{
								lstore_map=>AccLStore1
							   }
					   end,
			AddrAcc2=lists:foldl(
					   fun({P,V}, UAcc) ->
							   case maps:is_key({lstore,P},UAcc) of
								   true ->
									   UAcc;
								   false ->
									   maps:put({lstore,P},{V,undefined},UAcc)
							   end
					   end,
					   AddrAcc1,
					   DataGot),
			response_get(
			  settings:get(Path, AccLStore1),
			  false,
			  State#{acc=>maps:put(Address,AddrAcc2,Acc)}
			 )
	end.

-spec patch(binary(), list(), #{acc:=map()}) -> {ok, map()} | {'error', atom()}.

do_apply({Path, set, Value}, {#{lstore_map:=Map}=AddrAcc, List, {_Address, _GetFun, _GFA}=Handler}) ->
	IsLeaf = is_leaf(Path, AddrAcc, Handler),
	case IsLeaf of
		{true, V0, AddrAcc1} when is_integer(V0) orelse is_binary(V0) ->
			{
			 AddrAcc1#{lstore_map => settings:set(Path, Value, Map),
					  {lstore,Path} => {undefined,Value}},
			 [{Path, set, Value}|List],
			 Handler
			};
		{false, AddrAcc1} ->
			{
			 AddrAcc1#{lstore_map => settings:set(Path, Value, Map),
					  {lstore,Path} => {undefined,Value}},
			 [{Path, set, Value}|List],
			 Handler
			};
		_ ->
			throw({'incompatible_type',Path})
	end.

patch(Address, Patches, #{getfun:=GetFun,
						  getfunarg:=GFA,
						  acc:=Acc,
						  lstore_patches := LSP
						 }=State) when is_list(Patches) ->
	AddrAcc=maps:get(Address,Acc,#{}),
	{AddrAcc1,PatchesApplied,_}=lists:foldl(
								   fun do_apply/2,
								   {AddrAcc,
									maps:get(Address,LSP,[]),
									{Address, GetFun, GFA}
								   },
								   Patches),
	{ok, State#{
		   acc=>maps:put(Address,AddrAcc1,Acc),
		   lstore_patches => maps:put(Address, PatchesApplied, LSP)
		  }
	}.

patch_test() ->
	TestData=#{
			   <<"key1">> => 1,
			   <<"key2">> => <<"bin">>,
			   <<"key3">> => [<<$l>>,<<$i>>,<<$s>>,<<$t>>],
			   <<"key4">> => [$l,$>,$s,$t],
			   <<"map">> => #{
							  <<"int">> => 1,
							  <<"bin">> => <<"value">>,
							  123 => 321
							 }
			  },
	LedgerData = [
				  { <<1>> , #{ lstore => TestData }}
				 ],
	Test=fun(_) ->
				 S=pstate:new_state(fun mledger:getfun/2,pstate_lstore),
				 {_,_,S0}=get(<<1>>,[<<"map">>,123],S),
				 {ok,S1}=pstate_lstore:patch(<<1>>,[{[<<"map">>,<<"key33">>],set,<<10,0>>},
													{[<<"key2">>],set,<<20,0>>}],S0),
				 {R1,C1,S2}=get(<<1>>,[<<"map">>],S1),
				 {R2,C2,S3}=get(<<1>>,[<<"map">>],S2),
				 [
				  ?assertEqual(R1,R2),
				  ?assertMatch(#{123:=321,
								<<"bin">>:=<<"value">>,
								<<"int">>:=1,
								<<"key33">> := <<10,0>>
								},R2),
				  ?assertEqual(2,
							   length(maps:get(<<1>>,maps:get(lstore_patches,S3)))
							  ),
				  ?assertEqual(true,C2),
				  ?assertEqual(false,C1)
				 ]
		 end,
	mledger:deploy4test(pstate_lstore,
						LedgerData,
						Test).

