-module(logs_db).
-compile({no_auto_import,[get/1]}).
-export([start_db/0, deploy4test/1]).
-export([put/3,get/1]).

-record(logs, {
          blockhash,
          height,
          payload
         }).

tables() ->
  [table_descr(logs)].

table_descr(logs) ->
  {
   logs,
   record_info(fields, logs),
   [blockhash],
   [height],
   undefined
  }.

rm_rf(Dir) ->
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).

deploy4test(TestFun) ->
  application:start(rockstable),
  TmpDir="/tmp/logs_db_test."++(integer_to_list(os:system_time(),16)),
  filelib:ensure_dir(TmpDir),
  ok=rockstable:open_db(logs_db,TmpDir,tables()),
  try
    TestFun(undefined)
  after
    rockstable:close_db(mledger),
    rm_rf(TmpDir)
  end.

start_db() ->
  Path=utils:dbpath(logs_db),
  ok=rockstable:open_db(logs_db,Path,tables()),
  ok.

put(BlkID, Height, Logs) ->
  F=fun() ->
        Elements=rockstable:get(logs_db,env,#logs{height=Height,_='_'}),
        [ rockstable:del(logs_db,env,X) || X<- Elements ],

        rockstable:put(logs_db, env, #logs{height=Height,
                                           blockhash=BlkID,
                                           payload=Logs})
    end,
  case rockstable:transaction(logs_db,F) of
    {atomic,Res} ->
      {ok, Res};
    {aborted,{throw,{abort,NewHash}}} ->
      {error, NewHash}
  end.

get(Height) when is_integer(Height) ->
  {atomic,List}=rockstable:transaction(
                  logs_db,
                  fun()->
                      rockstable:get(logs_db,env,
                                     #logs{
                                        height=Height,
                                        _='_'
                                       })
                  end),
  case List of
    [] ->
      undefined;
    [E] ->
      l2m(E)
  end;

get(BlkID) when is_binary(BlkID) ->
  {atomic,List}=rockstable:transaction(
                  logs_db,
                  fun()->
                      rockstable:get(logs_db,env,
                                     #logs{
                                        blockhash=BlkID,
                                        _='_'
                                       })
                  end),
  case List of
    not_found ->
      undefined;
    [E] ->
      l2m(E)
  end.

l2m(#logs{blockhash=BlkID, height=Height, payload=P}) ->
  #{blkid=>BlkID,
    height=>Height,
    logs=>P
   }.


