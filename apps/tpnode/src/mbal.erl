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
         changes/1,
         uchanges/1,
         msgpack_state/1,
         prepare/1,
         patch/2
        ]).

-define(FIELDS,
        [t, seq, lastblk, pubkey, ld, usk, state, code, vm, view, lstore, vmopts]
       ).

-type balfield() :: 'amount'|'t'|'seq'|'lastblk'|'pubkey'|'ld'|'usk'|'state'|'code'|'vm'|'view'|'lstore'|'vmopts'.
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
                  'vmopts'=>map(),
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
                  'vmopts'=>map(),
                  'view'=>binary(),
                  'lstore'=>binary(),
                  'ublk'=>binary() %external attr
                 }.

msgpack_state(#{state:=Map}=MBal) when is_map(Map) ->
  MBal#{state=>msgpack:pack(Map)};

msgpack_state(MBal) -> 
  MBal.

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

prepare(Bal) ->
  maps:map(
    fun(lstore,Map) when is_map(Map) ->
        settings:mp(Map);
       (_,Any) ->
        Any
    end, Bal).

decode_fetched(Bal) ->
  maps:map(
    fun(lstore,Bin) when is_binary(Bin) ->
        {ok, Map} = settings:dmp(Bin),
        Map;
       (_,Any) ->
        Any
    end, Bal).

-spec fetch (binary(), binary(), boolean(),
             bal(), fun()) -> bal().
fetch(Address, _Currency, _Header, Bal, FetchFun) ->
  case maps:is_key(seq, Bal) of
    true -> Bal;
    false ->
      Fetched=FetchFun(Address),
      if Fetched==undefined ->
           throw({no_address,Address});
         true -> ok
      end,
      decode_fetched(Fetched)
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


uchanges(#{changes:=Changes}=Bal) ->
  Bal#{changes=>lists:usort(Changes)};

uchanges(Bal) ->
  Bal.

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
put(lstore, P, V, Bal) ->
  D=get(lstore, Bal),
  D1=settings:patch([#{<<"p">>=>P,<<"t">>=><<"set">>,<<"v">>=>V}],D),
  put(lstore, D1, Bal#{
                    changes=>[lstore|maps:get(changes, Bal, [])]
                   }
  );

put(state, <<>>, V, Bal) ->
  put(state, V, Bal#{
                  changes=>[state|maps:get(changes, Bal, [])]
                 }
     );

put(state, P, <<>>, #{state:=PV}=Bal) ->
  Bal#{state=>maps:remove(P,PV),
       changes=>[state|maps:get(changes, Bal, [])]};

put(state, _P, <<>>, Bal) ->
  Bal;

put(state, P, V, #{state:=PV}=Bal) ->
  Bal#{state=>PV#{P=>V},
       changes=>[state|maps:get(changes, Bal, [])]};

put(state, P, V, Bal) ->
  Bal#{state=>#{P=>V},
       changes=>[state|maps:get(changes, Bal, [])]};

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

put(vmopts, V, Bal) ->
  Bal#{ vmopts=>V,
        changes=>[vmopts|maps:get(changes, Bal, [])]
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

put(state, V, Bal) when is_function(V); is_binary(V) ->
  Bal#{ state=>V,
        changes=>[state|maps:get(changes, Bal, [])]
      };

put(state, V, Bal) when is_map(V) ->
  Bal#{ state=>V,
        changes=>[state|maps:get(changes, Bal, [])]
      };

put(mergestate, V, Bal) when is_map(V) ->
  case maps:find(state, Bal) of
    error ->
      Bal#{state=>V,
           changes=>[state|maps:get(changes, Bal, [])]};
    {ok, PV} ->
      Bal#{state=>maps:merge(PV,V),
           changes=>[state|maps:get(changes, Bal, [])]}
  end;

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
  Bal#{ lstore=>(V),
        changes=>[lstore|maps:get(changes, Bal, [])]
      };

put(usk, V, Bal) when is_integer(V) ->
  Bal#{ usk=>V,
        changes=>[usk|maps:get(changes, Bal, [])]
      };

put(ublk, V, Bal) ->
  Bal#{ ublk=>V };

put(T, _, _) ->
  throw({"unsupported bal field for put", T}).


-spec get (atom(), bal()) -> integer()|binary()|undefined.
get(seq, Bal) ->    maps:get(seq, Bal, 0);
get(t, Bal) ->      maps:get(t, Bal, 0);
get(pubkey, Bal) -> maps:get(pubkey, Bal, <<>>);
get(ld, Bal) ->     maps:get(ld, Bal, 0);
get(usk, Bal) ->    maps:get(usk, Bal, 0);
get(vm, Bal) ->     maps:get(vm, Bal, undefined);
get(vmopts, Bal) -> maps:get(vmopts, Bal, #{});
get(view, Bal) ->   maps:get(view, Bal, undefined);
get(state, Bal) ->  maps:get(state, Bal, undefined);
get(code, #{code:=C}) when is_function(C) -> C();
get(code, #{code:=C}) when is_binary(C) -> C;
get(code, _Bal) -> undefined;
get(lstore, Bal) -> case maps:get(lstore, Bal, #{}) of
                       B when is_binary(B) ->
                         settings:dmp(B);
                       M when is_map(M) ->
                         M
                    end;
get(lastblk, Bal) ->maps:get(lastblk, Bal, <<0, 0, 0, 0, 0, 0, 0, 0>>);
get(T, _) ->      throw({"unsupported bal field for get", T}).

-spec pack (bal()) -> binary().
pack(Bal) ->
  pack(Bal, false).


-spec pack (bal(), boolean()) -> binary().
pack(#{ amount:=_ }=Bal, false) ->
  pack1(Bal,?FIELDS);

pack(#{ amount:=_ }=Bal, true) ->
  pack1(Bal,[ublk|?FIELDS]).

pack1(#{ amount:=Amount }=Bal, Fields) ->
  Others=maps:map(
           fun(lstore,V) when is_map(V) ->
               settings:mp(V);
             (_,V) ->
               V
           end,
           maps:with(Fields, Bal)
          ),
  msgpack:pack(
    maps:put(
      amount, Amount,
      Others
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

-spec patch (list(), bal()) -> bal().
patch([{state,S1}|Rest], Bal) ->
  patch(Rest,mbal:put(state,S1,Bal));

patch([{mergestate,S1}|Rest], Bal) ->
  patch(Rest,mbal:put(mergestate,S1,Bal));

patch([], Bal) ->
  Bal.

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


