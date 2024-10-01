-module(pstate).

-export([
		 get_state/4,
		 set_state/5,
		 new_state/2,
		 patch/1,
		 extract_state/1 %useful for tests
		]).

set_state(Address, lstore, Path, Value, #{getfun:=_, getfunarg:=_, acc:=_}=State) ->
	{ok,State1}=pstate_lstore:patch(Address,
									[ {Path,set,Value} ],
									State),
	State1;

set_state(Address, Field, Path, Value, #{getfun:=GetFun, getfunarg:=GFA, acc:=Acc}=State) ->
	State#{
	  acc=> set_state_int(Address, Field, Path, Acc, Value, GetFun, GFA)
	 }.

get_state(Address, lstore, Path, #{getfun:=_, getfunarg:=_, acc:=_}=State) ->
	pstate_lstore:get(Address, Path, State);

get_state(Address, Field, Path, #{getfun:=GetFun, getfunarg:=GFA, acc:=Acc}=State) ->
	{_, Value, Cached, Acc1} = get_state_int(Address, Field, Path, Acc, GetFun, GFA),
	{Value, Cached, State#{ acc=> Acc1 }}.

new_state(GetFun, GetFunArg) when is_function(GetFun,2) ->
	#{
	  acc => #{}, %accounts accumulator
	  lstore_patches => #{},
	  getfun => GetFun,
	  getfunarg => GetFunArg
	 }.

patch(#{acc:=Acc}) ->
	maps:fold(
	  fun(Address, Data, A0) ->
			  maps:fold(
				fun(lstore_map, _, A1) -> %lstore_map is just a cache. Ignore it
						A1;
				   (_, {_, undefined}, A1) ->
						A1;
				   (_, {OldValue, NewValue}, A1) when OldValue == NewValue ->
						A1;
				   ({Field, Path}, {OldValue, NewValue}, A1) ->
						[{Address,Field,Path,OldValue,NewValue}|A1]
				end, A0, Data)
	  end, [], Acc).

extract_state(#{acc:=Acc}) ->
	maps:fold(
	  fun(Address, Data, A0) ->
			  maps:fold(
				fun(lstore_map, _, A1) -> %lstore_map is just a cache. Ignore it
						A1;
				   ({Field, Path}, {OldValue, undefined}, A1) ->
						[{Address,Field,Path,OldValue,OldValue}|A1];
				   ({Field, Path}, {OldValue, NewValue}, A1) ->
						[{Address,Field,Path,OldValue,NewValue}|A1]
				end, A0, Data)
	  end, [], Acc).

get_from_acc(Address, Field, Path, Acc) ->
	case maps:get(Address, Acc, undefined) of
		undefined ->
			undefined;
		Map ->
			maps:get({Field,Path},Map,undefined)
	end.

store_to_acc(Address, Field, Path, Acc, Value) ->
	AddrAcc0=maps:get(Address, Acc, #{}),
	AddrAcc1=maps:put({Field, Path}, Value, AddrAcc0),
	maps:put(Address, AddrAcc1, Acc).

get_state_int(Address, Field, Path, Acc, GetFun, GFA) when
	  Field==storage ;
	  Field==code ;
	  Field==balance ;
	  Field==pubkey ;
	  Field==seq ;
	  Field==t ;
	  Field==lastblk ;
	  Field==lstore ->
	case get_from_acc(Address, Field, Path, Acc) of
		undefined ->
			DBValue=GetFun({Field,Address,Path}, GFA),
			{DBValue, DBValue, false, store_to_acc(Address, Field, Path, Acc, {DBValue,undefined})};
		{Value,undefined} when is_binary(Value) ; is_integer(Value) ->
			{Value, Value, true, Acc};
		{OldValue,Value} when is_binary(Value) ; is_integer(Value) ->
			{OldValue, Value, true, Acc}
	end.

set_state_int(Address, Field, Path, Acc, Value, GetFun, GFA) when
	  Field==storage ;
	  Field==code ;
	  Field==balance ;
	  Field==pubkey ;
	  Field==seq ;
	  Field==t ;
	  Field==lastblk ;
	  Field==lstore ->
	{OldValue, _, _, Acc1} = get_state_int(
							Address,
							Field,
							Path,
							Acc,
							GetFun, GFA),
	store_to_acc(
	  Address, Field, Path, Acc1,
	  {OldValue,Value}
	 ).


