-module(bron_kerbosch).
-export([max_clique/1, unpack_bitmask/1]).

-ifndef(TEST).
-define(TEST, 1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


shift_until([],N,Off) ->
  {N,Off};
shift_until([{Lim,Shift}|Rest],N,Off) ->
  if((N band Lim)==0) ->
      shift_until(Rest, N bsr Shift, Off+Shift);
    true ->
      shift_until(Rest, N, Off)
  end.

shift_next(Number,OldOff) ->
  shift_until(
    [{340282366920938463463374607431768211455,128},
     {18446744073709551615,64},
     {4294967295,32},
     {65535,16},
     {255,8},
     {15,4},
     {3,2},
     {1,1}], Number, OldOff).

unpack_bitmask(B) ->
  unpack(B,0).

unpack(0,_) -> [];
unpack(1,O) -> [O];
unpack(B,O) ->
  {Left,O1}=shift_next(B,O),
  [O1|unpack(Left bsr 1,O1+1)].

is_connected(Row, Col, Matrix) ->
  lists:any(
    fun({Ind, List}) ->
      (Ind =:= Row) andalso lists:member(Col, List)
    end,
    Matrix
  ) andalso lists:any(
    fun({Ind, List}) ->
      (Ind =:= Col) andalso lists:member(Row, List)
    end,
    Matrix
  ).

check(Candidates, Rejected, Matrix) ->
  lists:foldl(
    fun(R, Acc1) ->
      Acc1 andalso lists:foldl(
        fun(C, Acc2) ->
          case is_connected(R, C, Matrix) of
            true -> false;
            false -> Acc2
          end
        end,
        true,
        Candidates
      )
    end,
    true,
    Rejected).

extend([], _, _, Results, _) -> Results;
extend(Candidates, Rejected, Compsub, Results, Matrix) ->
  case check(Candidates, Rejected, Matrix) of
    true ->
      [HCandidates | TCandidates] = Candidates,
      TRejected =
        case Rejected == [] of
          true -> [];
          false -> [_ | TR] = Rejected, TR
        end,
      
      NewCompsub = [HCandidates | Compsub],
      
      NewCandidates =
        lists:filter(
          fun(Val) ->
            is_connected(Val, HCandidates, Matrix) andalso (Val =/= HCandidates)
          end,
          Candidates
        ),
      
      NewRejected =
        lists:filter(
          fun(Val) ->
            is_connected(Val, HCandidates, Matrix) andalso (Val =/= HCandidates)
          end,
          Rejected
        ),
      
      NewResults =
        case (NewCandidates == []) andalso (NewRejected == []) of
          true ->
            [lists:sort(NewCompsub) | Results];
          false ->
            extend(
              NewCandidates,
              NewRejected,
              NewCompsub,
              Results,
              Matrix
            )
        end,
      extend(TCandidates, TRejected, Compsub, NewResults, Matrix);
    _ -> Results
  end.


max_clique(Matrix) when is_list(Matrix) ->
  Candidates = lists:sort(
    lists:map(
      fun({Ind, _}) ->
        Ind
      end,
      Matrix
    )
  ),
  Result = lists:sort(extend(Candidates, [], [], [], Matrix)),
  lists:foldl(
    fun(Val, Acc) ->
      case length(Val) > length(Acc) of
        true -> Val;
        false -> Acc
      end
    end,
    [],
    Result).

-ifdef(TEST).
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
    ?assertEqual([1, 3, 4, 5, 6],
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
    ?assertEqual([<<"A">>, <<"C">>, <<"D">>, <<"E">>, <<"F">>],
      max_clique(Matrix))
  ].

shift_test() ->
  [
   ?assertEqual(
      [0], 
      unpack_bitmask(1)
     ),
   ?assertEqual( 256, length(unpack_bitmask((1 bsl 256)-1))),
   ?assertEqual(
      [20,254,255], 
      unpack_bitmask((1 bsl 20) bor (1 bsl 255) bor (1 bsl 254))
     )
  ].

-endif.
