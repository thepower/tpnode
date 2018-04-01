-module(bron_kerbosch).
-export([max_clique/1]).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


isConnected(Row, Col, Matrix) ->
    lists:any(fun(Val) -> {Ind, List} = Val, (Ind =:= Row) andalso lists:member(Col, List) end, Matrix)
        andalso
    lists:any(fun(Val) -> {Ind, List} = Val, (Ind =:= Col) andalso lists:member(Row, List) end, Matrix).

check(Candidates, Rejected, Matrix) ->
    lists:foldl(fun(R, Acc1) ->
            Acc1 andalso lists:foldl(fun(C, Acc2) ->
                case isConnected(R, C, Matrix) of
                    true -> false;
                    false -> Acc2
                end
            end, true, Candidates)
        end, true, Rejected).

extend([], _, _, Results, _) -> Results;
extend(Candidates, Rejected, Compsub, Results, Matrix) ->
    case check(Candidates, Rejected, Matrix) of
        true ->
            [HCandidates|TCandidates] = Candidates,
            TRejected = case Rejected == [] of
                            true -> [];
                            false -> [_|TR] = Rejected, TR
                        end,

            NewCompsub = [HCandidates|Compsub],

            NewCandidates = lists:filter(fun(Val) ->
                isConnected(Val, HCandidates, Matrix) andalso (Val =/= HCandidates)
                                         end, Candidates),

            NewRejected = lists:filter(fun(Val) ->
                isConnected(Val, HCandidates, Matrix) andalso (Val =/= HCandidates)
                                       end, Rejected),

            NewResults = case (NewCandidates == []) andalso (NewRejected == []) of
                             true -> [lists:sort(NewCompsub)|Results];
                             false -> extend(NewCandidates, NewRejected, NewCompsub, Results, Matrix)
                         end,
            extend(TCandidates, TRejected, Compsub, NewResults, Matrix);
        _ -> Results
    end.


max_clique(Matrix) ->
    Candidates = lists:sort(lists:map(fun(Val) -> {Ind, _} = Val, Ind end, Matrix)),
    Result = lists:sort(extend(Candidates, [], [], [], Matrix)),
    lists:foldl(fun(Val, Acc) ->
        case length(Val) > length(Acc) of
            true -> Val;
            false -> Acc
        end
    end, [], Result).

-ifdef(TEST).
corrupt_matrix_test() ->
    Matrix = [{}],
    [
        ?assertError({badmatch,{}},
            max_clique(Matrix))
    ].

empty_matrix_test() ->
    Matrix = [],
    [
        ?assertEqual([],
            max_clique(Matrix))
    ].

integer_matrix_test() ->
    Matrix = [
        {0, [1, 2]},
        {1, [0, 2, 3, 4, 5, 6]},
        {2, [0, 1]},
        {3, [1, 4, 5, 6]},
        {4, [1, 3, 5, 6]},
        {5, [1, 3, 4, 6]},
        {6, [1, 3, 4, 5]}
    ],
    [
        ?assertEqual([1,3,4,5,6],
            max_clique(Matrix))
    ].

binary_matrix_test() ->
    Matrix = [
        {<<"a">>, [<<"A">>, <<"B">>]},
        {<<"A">>, [<<"a">>, <<"B">>, <<"C">>, <<"D">>, <<"E">>, <<"F">>]},
        {<<"B">>, [<<"a">>, <<"A">>]},
        {<<"C">>, [<<"A">>, <<"D">>, <<"E">>, <<"F">>]},
        {<<"D">>, [<<"A">>, <<"C">>, <<"E">>, <<"F">>]},
        {<<"E">>, [<<"A">>, <<"C">>, <<"D">>, <<"F">>]},
        {<<"F">>, [<<"A">>, <<"C">>, <<"D">>, <<"E">>]}
    ],
    [
        ?assertEqual([<<"A">>,<<"C">>,<<"D">>,<<"E">>,<<"F">>],
            max_clique(Matrix))
    ].

-endif.