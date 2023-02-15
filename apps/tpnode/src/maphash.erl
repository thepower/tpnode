-module(maphash).

%% API
-export([hash/1, hash/2, map2binary/2]).

hash(Map) ->
  Hasher =
    fun(Bin) when is_binary(Bin) ->
      crypto:hash(sha256, Bin)
    end,
  hash(Map, Hasher).

hash(Map, Hasher) ->
  Hasher(map2binary(Map,[])).

map2binary(Map,Path) when is_map(Map) ->
  Keys = lists:sort(maps:keys(Map)),
  Converter =
    fun(CurrentKey, OrigMap) ->
      Value =
        case maps:get(CurrentKey, OrigMap) of
          V1 when is_map(V1) ->
            map2binary(V1,[CurrentKey|Path]);
          V2 ->
            make_binary(V2,[CurrentKey|Path])
        end,
      KeyBin = make_binary(CurrentKey,[CurrentKey|Path]),
      <<(size(KeyBin)):64/big, KeyBin/binary, (size(Value)):64/big, Value/binary>>
    end,
  Map1 = [Converter(K, Map) || K <- Keys],
  binary:list_to_bin(Map1).

make_binary(Arg,_) when is_integer(Arg) ->
  integer_to_binary(Arg, 10);

make_binary(Arg,_) when is_binary(Arg) ->
  Arg;

make_binary(Arg,Path) when is_list(Arg) ->
  list_to_binary([make_binary(E,Path) || E <- Arg ]);

make_binary(chain,_) -> <<"chain">>;
make_binary(chains,_) -> <<"chains">>;
make_binary(nodechain,_) -> <<"nodechain">>;
make_binary(keys,_) -> <<"keys">>;
make_binary(globals,_) -> <<"globals">>;
make_binary(patchsig,_) -> <<"patchsig">>;
make_binary(blocktime,_) -> <<"blocktime">>;
make_binary(minsig,_) -> <<"minsig">>;
make_binary(enable,_) -> <<"enable">>;
make_binary(params,_) -> <<"params">>;
make_binary(disable,_) -> <<"disable">>;
make_binary(nodes,_) -> <<"nodes">>;
make_binary(null,_) -> <<"null">>;
make_binary(true,_) -> <<"true">>;
make_binary(false,_) -> <<"false">>;

make_binary(Arg,Path) when is_atom(Arg) ->
  S=try throw(err) catch throw:err:SS -> SS end,
  logger:error("maphash: atom '~p' @ ~p", [Arg,Path]),
  lists:foreach(
    fun({?MODULE,_,_,_}) ->
        ok;
    (At) ->
      logger:error(" @ ~p", [At])
    end,
    S),
  atom_to_binary(Arg, utf8);

make_binary(Arg,Path) ->
  logger:error("maphash: bad arg '~p' @ ~p", [Arg,Path]),
  throw(badarg).
