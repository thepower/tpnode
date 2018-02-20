-module(bal).

-export([
         new/0,
         fetch/5,
         get_cur/2,
         put_cur/3,
         get/2,
         put/3,
         mput/5,
         pack/1,
         unpack/1,
         merge/2
        ]).

-spec new () -> #{amount:=map()}.
new() ->
    #{amount=>#{}}.

-spec fetch (integer()|binary(), integer()|binary(), 'true'|'false', 
             map(), fun()) -> map().
fetch(Address, _Currency, _Header, Bal, FetchFun) ->
%    FetchCur=not maps:is_key(Currency,Bal0),
%    IsHdr=maps:is_key(seq,Bal0),
%    if(Header and not IsHdr) ->
    case maps:is_key(seq,Bal) of
        true -> Bal;
        false -> 
          FetchFun(Address)
    end.

-spec get_cur (integer()|binary(), map()) -> integer().
get_cur(Currency, #{amount:=A}=_Bal) ->
    maps:get(Currency, A, 0).

-spec put_cur (integer()|binary(), integer(), #{amount:=map()}) -> map().
put_cur(Currency, Value, #{amount:=A}=Bal) ->
    Bal#{
      amount => A#{ Currency => Value}
     }.

-spec mput (integer()|binary(), integer(), integer(), integer(), map()) -> map().
mput(Cur, Amount, Seq, T, #{amount:=A}=Bal) when is_integer(Amount),
                                    is_integer(Seq),
                                    is_integer(T),
                                    T > 1500000000000,
                                    T < 15000000000000 ->
    Bal#{
      amount=>A#{Cur=>Amount},
      seq=>Seq,
      t=>T
     };

mput(_Cur, _Amount, _Seq, T, _Bal) when T < 1500000000000 orelse
                                    T > 15000000000000 ->
    throw('bad_timestamp_format').

-spec put (atom(), integer()|binary(), map()) -> map().
put(seq, V, Bal) when is_integer(V) ->
    maps:put(seq, V, Bal);
put(t, V, Bal) when is_integer(V),
                    V > 1500000000000,
                    V < 15000000000000  %only msec, not sec and not usec
                    -> 
    maps:put(t, V, Bal);
put(lastblk, V, Bal) when is_binary(V) ->
    maps:put(lastblk, V, Bal);
put(pubkey, V, Bal) when is_binary(V) ->
    maps:put(pubkey, V, Bal);
put(T, _, _) ->
    throw({"unsupported bal field",T}).


-spec get (atom(), map()) -> integer()|binary().
get(seq, Bal) ->
    maps:get(seq, Bal, 0);
get(t, Bal) ->
    maps:get(t, Bal, 0);
get(pubkey, Bal) ->
    maps:get(pubkey, Bal, <<>>);
get(lastblk, Bal) ->
    maps:get(lastblk, Bal, <<0,0,0,0,0,0,0,0>>);

get(T, _) ->
    throw({"unsupported bal field",T}).

-spec pack (map()) -> binary().
pack(#{
  amount:=Amount
 }=Bal) ->
    msgpack:pack(
      maps:put(
        amount, Amount,
        maps:with([t,seq,lastblk,pubkey],Bal)
       )
     ).

-spec unpack (binary()) -> 'error'|map().
unpack(Bal) ->
    case msgpack:unpack(Bal,[{known_atoms,[amount,seq,t,lastblk,pubkey]}]) of
        {ok, #{amount:=_}=Hash} ->
            maps:filter(
              fun(K,_) -> is_atom(K) end,
              Hash);
        _ ->
            error
    end.

-spec merge(map(), map()) -> map().
merge(Old, New) ->
    P1=maps:merge(
         Old,
         maps:with([pubkey,lastblk,seq,t],New)
        ),
    Bals=maps:merge(
           maps:get(amount, Old,#{}),
           maps:get(amount, New,#{})
          ),
    P1#{amount=>Bals}.

