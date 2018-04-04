-module(ldb).
-export([put_key/3, read_key/3, del_key/2, open/1, keys/1]).

open(Path) ->
    gen_server:call(rdb_dispatcher,
                                {open, Path, [{create_if_missing, true}]}).

read_key(DB, Key, Default) when is_binary(Key) ->
    case rocksdb:get(DB, Key, []) of
        not_found -> Default;
        {ok, Bin} ->
            binary_to_term(Bin)
    end;
read_key(_DB, Key, _Default) ->
    lager:error("LDB read_key: key must be binary ~p", [Key]),
    throw({non_binary_key, Key}).

put_key(DB, Key, Value) when is_binary(Key) ->
    rocksdb:put(DB, Key, term_to_binary(Value), []);
put_key(_DB, Key, _Value) ->
    lager:error("LDB put_key: key must be binary ~p", [Key]),
    throw({non_binary_key, Key}).

del_key(DB, Key) ->
    rocksdb:delete(DB, Key).

%multiput(DB, Elements) ->
%    Batch=lists:foldl(
%            fun({K, V}, Acc) ->
%                    h2leveldb:add_put(K, term_to_binary(V), Acc)
%            end,
%            h2leveldb:new_write_batch(), Elements),
%    ok = h2leveldb:write(DB, Batch).

keys(DB) ->
    {ok, K} = rocksdb:iterator(DB, []),
    next_key(DB, K).

next_key(DB, Key) ->
    case rocksdb:iterator_move(Key, next) of
        {ok, K} ->
            [ K | next_key(DB, K) ];
        _ ->
            []
    end.
