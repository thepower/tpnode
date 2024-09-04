%% Base58 encoder/decoder for Erlang
%% By Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%% This code is in public domain

-module(base58).

-export([encode/1, decode/1, binary_to_base58/1, base58_to_binary/1, check_base58/1]).

-define(BASE58_TABLE, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz").

check_base58(Str) when is_list(Str) ->
	try
		_ = decode(list_to_binary(Str)),
		true
	catch error:_ ->
			  false
	end.

base58_to_binary(List) ->
	decode(list_to_binary(List)).

binary_to_base58(Bin) ->
	binary_to_list(encode(Bin)).

encode(<<0, T/binary>>) ->
    TEnc = encode(T),
    <<$1, TEnc/binary>>;
encode(Data) ->
    N = binary:decode_unsigned(Data, big),
    encode(N, <<>>).

encode(0, Acc) ->
    Acc;
encode(N, Acc) ->
    C = lists:nth(N rem 58 + 1, ?BASE58_TABLE),
    encode(N div 58, <<C:8/unsigned, Acc/binary>>).

decode(<<$1, T/binary>>) ->
    TDec = decode(T),
    <<0, TDec/binary>>;
decode(Data) ->
    binary:encode_unsigned(decode(Data, 0), big).

decode(<<>>, N) ->
    N;
decode(<<C:8/unsigned, T/binary>>, N) ->
    case string:chr(?BASE58_TABLE, C) of
        0 -> error(invalid_character);
        V -> decode(T, N * 58 + (V - 1))
    end.

