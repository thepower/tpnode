-module(bron_kerbosch).
-export([max_clique/1]).

isConnected(Row, Col, Matrix) ->
  lists:any(fun(Val) -> {Ind, List} = Val, (Ind =:= Row) and lists:member(Col, List) end, Matrix)
    and
  lists:any(fun(Val) -> {Ind, List} = Val, (Ind =:= Col) and lists:member(Row, List) end, Matrix).

check(Candidates, Rejected, Matrix) ->
  lists:foldl(fun(R, Acc1) ->
    Acc1 and lists:foldl(fun(C, Acc2) ->
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
        isConnected(Val, HCandidates, Matrix) and (Val =/= HCandidates)
      end, Candidates),

      NewRejected = lists:filter(fun(Val) ->
        isConnected(Val, HCandidates, Matrix) and (Val =/= HCandidates)
      end, Rejected),

      NewResults = case (NewCandidates == []) and (NewRejected == []) of
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