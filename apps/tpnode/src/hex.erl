-module(hex).
-export([parse/1]).

parse(B) when is_binary(B) ->
    parse(binary_to_list(B));

parse([$0, $x|L])  ->
    parse(L);

parse(L) when is_list(L) ->
    case length(L) rem 2 of
        0 -> ok;
        1 -> throw('bad length')
    end,
    parse(string:to_lower(L), <<>>).

parse([], Acc) ->
    Acc;

parse([H1, H2|Rest], Acc) ->
    parse(Rest, <<Acc/binary, ((h2i(H1) bsl 4) bor h2i(H2))/integer>>).


h2i($0) -> 0;
h2i($1) -> 1;
h2i($2) -> 2;
h2i($3) -> 3;
h2i($4) -> 4;
h2i($5) -> 5;
h2i($6) -> 6;
h2i($7) -> 7;
h2i($8) -> 8;
h2i($9) -> 9;
h2i($a) -> 10;
h2i($b) -> 11;
h2i($c) -> 12;
h2i($d) -> 13;
h2i($e) -> 14;
h2i($f) -> 15;
h2i(Any) -> throw({'bad_symbol', Any}).



