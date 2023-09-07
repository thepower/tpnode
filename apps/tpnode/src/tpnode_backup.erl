-module(tpnode_backup).
-include("include/tplog.hrl").
-export([make_backup/0,get_backup/0]).

make_backup() ->
  filelib:ensure_dir(utils:dbpath(backup)++"/"),
  D0=case get_info() of
       {ok,M} -> M;
       _ -> #{}
     end,
  T=os:system_time(),
  Last=maps:get(last,D0,0),
  if((T-Last) div 1000000000 < 10) ->
      {ignore,Last};
    true ->
      #{header:=Hdr,hash:=Hash}=blockchain:last(),
      Hei=maps:get(height,Hdr,undefined),
      PHei=maps:get(height,maps:get(header,D0,#{}),undefined),

      if(Hei==undefined orelse PHei==undefined orelse Hei>PHei) ->
          DB=utils:dbpath(backup)++"/"++integer_to_list(T),
          rockstable:backup(mledger,DB++".mledger"),
          gen_server:call(rdb_dispatcher,{backup,utils:dbpath(db),DB++".blocks"}),
          file:write_file(DB++".set",io_lib:format("~p.~n",[chainsettings:by_path([])])),
          Data=D0#{last=>T,
                   prev=>[T|maps:get(prev,D0,[])],
                   hash=>Hash,
                   dir=>DB,
                   header => Hdr},
          file:write_file(
            utils:dbpath(backup)++"/info",
            io_lib:format("~p.~n",[Data])
           ),
          {ok, T};
        true ->
          {ignore,Last}
      end
  end.

get_info() ->
  case file:consult(utils:dbpath(backup)++"/info") of
    {error,enoent} ->
      {error,enoent};
    {ok, [Map]} ->
      {ok,Map}
  end.

get_backup() ->
  {ok,Info=#{dir:=Dir,last:=Last}}=get_info(),
  case file:read_file(Dir++".zip") of
    {ok, Bin} ->
      {ok,Bin};
    {error, enoent} ->
      TL=integer_to_list(Last),
      Files=filelib:wildcard(TL++"*",utils:dbpath(backup)) ++ filelib:wildcard(TL++"*/**",utils:dbpath(backup)),
      Info1=(maps:with([last,hash,header],Info))#{dir=>TL},
      file:write_file(utils:dbpath(backup)++"/backup.txt",io_lib:format("~p.~n",[Info1])),
      Files1=["backup.txt"|lists:usort(Files)],
      ?LOG_INFO("Storing files ~p~n",[Files1]),
      {ok,_}=zip:create(Dir++".zip",Files1,[{cwd,utils:dbpath(backup)}]),
      file:read_file(Dir++".zip")
  end.

