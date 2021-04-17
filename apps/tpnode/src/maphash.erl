-module(maphash).

%% API
-export([hash/1, hash/2, map2binary/1]).

hash(Map) ->
  Hasher =
    fun(Bin) when is_binary(Bin) ->
      crypto:hash(sha256, Bin)
    end,
  hash(Map, Hasher).

hash(Map, Hasher) ->
  Hasher(map2binary(Map)).

map2binary(Map) when is_map(Map) ->
  Keys = lists:sort(maps:keys(Map)),
  Converter =
    fun(CurrentKey, OrigMap) ->
      Value =
        case maps:get(CurrentKey, OrigMap) of
          V1 when is_map(V1) ->
            map2binary(V1);
          V2 ->
            make_binary(V2)
        end,
      KeyBin = make_binary(CurrentKey),
      <<(size(KeyBin)):64/big, KeyBin/binary, (size(Value)):64/big, Value/binary>>
    end,
  Map1 = [Converter(K, Map) || K <- Keys],
  binary:list_to_bin(Map1).

make_binary(Arg) when is_integer(Arg) ->
  integer_to_binary(Arg, 10);

make_binary(Arg) when is_binary(Arg) ->
  Arg;

make_binary(Arg) when is_list(Arg) ->
  list_to_binary([make_binary(E) || E <- Arg ]);

make_binary(Arg) when is_atom(Arg) ->
  atom_to_binary(Arg, utf8);

make_binary(_Arg) ->
  throw(badarg).
