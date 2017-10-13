-module(ldb).
-export([put_key/3,read_key/3,multiput/2,del_key/2,open/1,keys/1]).

open(Path) ->
    case h2leveldb:get_db(Path) of
        {ok,Port} ->
            {ok,Port};
        {error, _} ->
            case h2leveldb:create_db(Path) of
                {ok, Port} ->
                    {ok,Port};
                {error, Any} ->
                    lager:error("Can't create database ~p: ~p",
                                [Path, Any]),
                    {error, Any}
            end

    end.

read_key(DB, Key, Default) ->
    case h2leveldb:get(DB, Key) of
        key_not_exist -> Default;
        {ok, Bin} ->
            binary_to_term(Bin)
    end.

put_key(DB, Key, Value) ->
    h2leveldb:put(DB, Key, term_to_binary(Value)).

del_key(DB, Key) ->
    h2leveldb:delete(DB, Key).

multiput(DB, Elements) ->
    Batch=lists:foldl(
            fun({K,V}, Acc) ->
                    h2leveldb:add_put(K, term_to_binary(V), Acc)
            end,
            h2leveldb:new_write_batch(), Elements),
    ok = h2leveldb:write(DB, Batch).


keys(DB) ->
    case h2leveldb:first_key(DB) of
        {ok, K} ->
            [ K | next_key(DB, K) ];
        Any ->
            Any
    end.

next_key(DB,Key) ->
    case h2leveldb:next_key(DB,Key) of
        {ok, K} ->
            [ K | next_key(DB, K) ];
        _ ->
            []
    end.
