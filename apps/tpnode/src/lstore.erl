-module(lstore).
-include("include/tplog.hrl").

-export([set/3, get/2, get/3, patch/2]).
-export([merge/2]).

%% -- [ actions ] --
%% exists      _
%% nonexists   _
%% compare     Value
%% delete      Value
%% delete      null
%% set         Value

merge(Bottom, Top) ->
	maps:fold(
	  fun(Key, Value, BAcc) when is_map(Value) ->
			  Merged = merge(maps:get(Key,BAcc,#{}),Value),
			  maps:put(Key, Merged, BAcc);
		 (Key, Value, BAcc) ->
			  maps:put(Key, Value, BAcc)
	  end, Bottom, Top).

set(A, B, C) ->
    change(set, A, B, C).

get([], M, _D) -> M;
get([Hd], M, D) ->
    maps:get(Hd, M, D);
get([Hd|Path], M, D) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    get(Path, H1, D).

get([], M) -> M;
get([Hd|Path], M) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    get(Path, H1).

change(exists, [Path], _Value, M, FPath) ->
    if is_map(M) ->
		   case maps:is_key(Path, M) of
			   true ->
				   M;
			   false ->
				   throw({exist, FPath})
		   end;
       true ->
           throw({'non_map', FPath})
    end;

change(nonexists, [Path], _Value, M, FPath) ->
    if is_map(M) ->
		   case maps:is_key(Path, M) of
			   false ->
				   M;
			   true ->
				   throw({exist, FPath})
		   end;
       true ->
           throw({'non_map', FPath})
    end;


change(compare, [Path], Value, M, FPath) ->
    if is_map(M) ->
           Val=maps:get(Path, M, undefined),
           if Val==Value ->
                  M;
              true ->
                  throw({compare, FPath})
           end;
       true ->
           throw({'non_map', FPath})
    end;

change(delete, [Path], null, M, FPath) -> %force delete
    if is_map(M) ->
           maps:remove(Path, M);
       true ->
           throw({'non_map', FPath})
    end;

change(delete, [Path], Value, M, FPath) -> %compare and delete
    if is_map(M) ->
           Val=maps:get(Path, M, undefined),
           if Val==Value ->
                  maps:remove(Path, M);
              true ->
                  throw({delete_val, FPath, Value})
           end;
       true ->
           throw({'non_map', FPath})
    end;

change(set, [Path], Value, M, FPath) -> %set or replace
    if is_map(M) ->
           PrevValue=maps:get(Path, M, undefined),
           if is_map(PrevValue) ->
                io:format("change(set,[~p],~p,~p,~p)~n",[Path,Value,M,FPath]),
                  throw({'non_value', FPath});
              true ->
                  maps:put(Path, Value, M)
           end;
       true ->
           throw({'non_map', FPath})
    end;

change(Action, [Hd|Path], Value, M, FPath) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    maps:put(Hd, change(Action, Path, Value, H1, FPath), M).

change(Action, Path, Value, M) when is_list(Path) ->
    change(Action, Path, Value, M, Path).

patch([], M) -> M;
patch([{Path, Action, V}|Settings], M) ->
    M1=change(Action, Path, V, M),
    patch(Settings, M1);
patch([{Path, V}|Settings], M) ->
    M1=change(set, Path, V, M),
    patch(Settings, M1).

