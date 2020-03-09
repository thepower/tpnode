-module(mbal).

-export([
         new/0,
         fetch/5,
         get_cur/2,
         put_cur/3,
         get/2,
         put/3,
         put/4,
         mput/4,
         pack/1,
         pack/2,
         unpack/1,
         merge/2,
         changes/1
        ]).

-define(FIELDS,
        [t, seq, lastblk, pubkey, ld, usk, state, code, vm, view, lstore]
       ).

-type balfield() :: 'amount'|'t'|'seq'|'lastblk'|'pubkey'|'ld'|'usk'|'state'|'code'|'vm'|'view'|'lstore'.
-type sparsebal () :: #{'amount'=>map(),
                  'changes'=>[balfield()],
                  'seq'=>integer(),
                  't'=>integer(),
                  'lastblk'=>binary(),
                  'pubkey'=>binary(),
                  'ld'=>integer(),
                  'usk'=>integer(),
                  'state'=>map(),
                  'code'=>binary(),
                  'vm'=>binary(),
                  'view'=>binary(),
                  'lstore'=>binary(),
                  'ublk'=>binary() %external attr
                 }.

-type bal () :: #{'amount':=map(),
                  'changes':=[balfield()],
                  'seq'=>integer(),
                  't'=>integer(),
                  'lastblk'=>binary(),
                  'pubkey'=>binary(),
                  'ld'=>integer(),
                  'usk'=>integer(),
                  'state'=>map(),
                  'code'=>binary(),
                  'vm'=>binary(),
                  'view'=>binary(),
                  'lstore'=>binary(),
                  'ublk'=>binary() %external attr
                 }.

-spec new () -> bal().
new() ->
  #{amount=>#{}, changes=>[]}.

-spec changes (bal()) -> sparsebal().
changes(Bal) ->
  Changes=maps:get(changes, Bal, []),
  if Changes==[] ->
       #{};
     true ->
       maps:with([amount|Changes], maps:remove(changes, Bal))
  end.


-spec fetch (binary(), binary(), boolean(),
             bal(), fun()) -> bal().
fetch(Address, _Currency, _Header, Bal, FetchFun) ->
  %    FetchCur=not maps:is_key(Currency, Bal0),
  %    IsHdr=maps:is_key(seq, Bal0),
  %    if(Header and not IsHdr) ->
  case maps:is_key(seq, Bal) of
    true -> Bal;
    false ->
      FetchFun(Address)
  end.

-spec get_cur (binary(), bal()) -> integer().
get_cur(Currency, #{amount:=A}=_Bal) ->
  maps:get(Currency, A, 0).

-spec put_cur (binary(), integer(), bal()) -> bal().
put_cur(Currency, Value, #{amount:=A}=Bal) ->
  case maps:get(Currency, A, 0) of
    Value -> %no changes
      Bal;
    _ ->
      Bal#{
        amount => A#{ Currency => trunc(Value)},
        changes=>[amount|maps:get(changes, Bal, [])]
       }
  end.

-spec mput (Seq::non_neg_integer(), T::non_neg_integer(),
            Bal::bal(), UseSK::boolean()|'reset') -> bal().

mput(Seq, 0, Bal, false) when is_integer(Seq) ->
  Bal#{
    changes=>[seq, t|maps:get(changes, Bal, [])],
    seq=>Seq
   };

mput(Seq, T, Bal, false) when is_integer(Seq),
                              is_integer(T),
                              T > 1500000000000,
                              T < 15000000000000 ->
  Bal#{
    changes=>[seq, t|maps:get(changes, Bal, [])],
    seq=>Seq,
    t=>T
   };

mput(Seq, T, Bal, true) when is_integer(Seq),
                             is_integer(T),
                             T > 1500000000000,
                             T < 15000000000000 ->
  USK=maps:get(usk, Bal, 0),
  Bal#{
    changes=>[seq, t, usk|maps:get(changes, Bal, [])],
    seq=>Seq,
    t=>T,
    usk=>USK+1
   };

mput(Seq, T, Bal, reset) when is_integer(Seq),
                              is_integer(T),
                              T > 1500000000000,
                              T < 15000000000000 ->
  Bal#{
    changes=>[seq, t, usk|maps:get(changes, Bal, [])],
    seq=>Seq,
    t=>T,
    usk=>1
   };

mput(_Seq, T, _Bal, _) when T < 1500000000000 orelse
                            T > 15000000000000 ->
  throw('bad_timestamp_format').

put(lstore, [], V, Bal) ->
  put(lstore, V, Bal);

%TODO: fix lstore
%put(lstore, P, V, Bal) ->
%  put(lstore, ,Bal);

put(state, <<>>, V, Bal) ->
  put(state, V, Bal);

put(state, P, V, Bal) ->
  case maps:find(state, Bal) of
    error ->
      Bal#{state=>#{P=>V}};
    {ok, PV} ->
      Bal#{state=>PV#{P=>V}}
  end;

put(K, [], V, Bal) ->
  put(K,V,Bal).

-spec put (atom(), integer()|binary(), bal()) -> bal().
put(amount, V, Bal) when is_map(V) -> %use on preload data
  Bal#{ amount=>V };

put(seq, V, Bal) when is_integer(V) ->
  Bal#{ seq=>V,
        changes=>[seq|maps:get(changes, Bal, [])]
      };

put(t, V, Bal) when is_integer(V),
                    V > 1500000000000,
                    V < 15000000000000  %only msec, not sec and not usec
                    ->
  Bal#{ t=>V,
        changes=>[t|maps:get(changes, Bal, [])]
      };
put(lastblk, V, Bal) when is_binary(V) ->
  Bal#{ lastblk=>V,
        changes=>[lastblk|maps:get(changes, Bal, [])]
      };
put(pubkey, V, Bal) when is_binary(V) ->
  Bal#{ pubkey=>V,
        changes=>[pubkey|maps:get(changes, Bal, [])]
      };
put(ld, V, Bal) when is_integer(V) ->
  Bal#{ ld=>V,
        changes=>[ld|maps:get(changes, Bal, [])]
      };
put(vm, V, Bal) when is_binary(V) ->
  Bal#{ vm=>V,
        changes=>[vm|maps:get(changes, Bal, [])]
      };
put(view, V, Bal) when is_list(V) ->
  case valid_latin1_str_list(V) of
    true ->
      Bal#{ view=>V,
            changes=>[view|maps:get(changes, Bal, [])]
          };
    false ->
      throw('incorrect_view_list')
  end;

%put(state, V, Bal) when is_map(V) ->
%  case maps:get(state, Bal, undefined) of
%    OldState when OldState==V ->
%      Bal;
%    _ ->
%      Bal#{ state=>V,
%            changes=>[state|maps:get(changes, Bal, [])]
%          }
%  end;

put(state, V, Bal) when is_function(V) ->
  Bal#{ state=>V };

put(code, V, Bal) when is_function(V); is_binary(V) ->
  case maps:get(code, Bal, undefined) of
    OldCode when OldCode==V ->
      Bal;
    _ ->
      Bal#{ code=>V,
            changes=>[code|maps:get(changes, Bal, [])]
          }
  end;

put(lstore, V, Bal) when is_map(V) ->
  Bal#{ lstore=>settings:mp(V),
        changes=>[lstore|maps:get(changes, Bal, [])]
      };

put(usk, V, Bal) when is_integer(V) ->
  Bal#{ usk=>V,
        changes=>[usk|maps:get(changes, Bal, [])]
      };
put(T, _, _) ->
  throw({"unsupported bal field for put", T}).


-spec get (atom(), bal()) -> integer()|binary()|undefined.
get(seq, Bal) ->    maps:get(seq, Bal, 0);
get(t, Bal) ->      maps:get(t, Bal, 0);
get(pubkey, Bal) -> maps:get(pubkey, Bal, <<>>);
get(ld, Bal) ->     maps:get(ld, Bal, 0);
get(usk, Bal) ->    maps:get(usk, Bal, 0);
get(vm, Bal) ->     maps:get(vm, Bal, undefined);
get(view, Bal) ->   maps:get(view, Bal, undefined);
get(state, Bal) ->  maps:get(state, Bal, undefined);
get(code, #{code:=C}) when is_function(C) -> C();
get(code, #{code:=C}) when is_binary(C) -> C;
get(code, _Bal) -> undefined;
get(lstore, Bal) -> settings:dmp(maps:get(lstore, Bal, <<128>>));
get(lastblk, Bal) ->maps:get(lastblk, Bal, <<0, 0, 0, 0, 0, 0, 0, 0>>);
get(T, _) ->      throw({"unsupported bal field for get", T}).

-spec pack (bal()) -> binary().
pack(Bal) ->
  pack(Bal, false).


-spec pack (bal(), boolean()) -> binary().
pack(#{
  amount:=Amount
 }=Bal, false) ->
  msgpack:pack(
    maps:put(
      amount, Amount,
      maps:with(?FIELDS, Bal)
     )
   );

pack(#{
  amount:=Amount
 }=Bal, true) ->
  msgpack:pack(
    maps:put(
      amount, Amount,
      maps:with([ublk|?FIELDS], Bal)
     )
   ).

-spec unpack (binary()) -> bal().
unpack(Bal) ->
  case msgpack:unpack(Bal, [{known_atoms, [ublk,amount|?FIELDS]}]) of
    {ok, #{amount:=_}=Hash} ->
      maps:put(changes, [],
               maps:filter( fun(K, _) -> is_atom(K) end, Hash)
              );
    _ ->
      throw('ledger_unpack_error')
  end.

-spec merge(bal(), bal()) -> bal().
merge(Old, New) ->
  P1=maps:merge(
       Old,
       maps:with(?FIELDS, New)
      ),
  Bals=maps:merge(
         maps:get(amount, Old, #{}),
         maps:get(amount, New, #{})
        ),
  P1#{amount=>Bals}.

valid_latin1_str([C|Rest]) when C>=16#20, C<16#7F ->
  valid_latin1_str(Rest);
valid_latin1_str([]) -> true;
valid_latin1_str(_) -> false.

valid_latin1_str_list([]) ->
  true;
valid_latin1_str_list([L1|Rest]) ->
  case valid_latin1_str(L1) of
    true ->
      valid_latin1_str_list(Rest);
    false ->
      false
  end.


