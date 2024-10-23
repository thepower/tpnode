-module(tpnode_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1, check_key/0, try_restore_db/1, try_restore_db/0]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

check_key() ->
  try
    Priv=nodekey:get_priv(),
    case tpecdsa:keytype(Priv) of
      {priv, ed25519} -> ok;
      {priv, Type} ->
        throw({keytype_not_supported,Type})
    end,
    Public=nodekey:get_pub(),
    logger:notice("Starting up, pubkey is ~s",[hex:encode(Public)]),
    ok
  catch
    error:{badmatch,undefined} ->
      {error,"privkey does not specified"};
    throw:Reason ->
      {error,Reason};
    Ec:Ee ->
      logger:notice("Node key error ~p:~p",[Ec,Ee]),
      {error,"privkey broken"}
  end.

try_restore_db() ->
	try_restore_db([]).

try_fetch_backup(_, [], _) ->
	false;

try_fetch_backup(0, [_|Next], Retry) ->
	try_fetch_backup(Retry, Next, Retry);

try_fetch_backup(N, [Host|_]=List, Retry) ->
	logger:info("Trying to fetch backup from ~s try ~p",[Host,Retry - N + 1]),
	try
		Bin = tpapi2:httpget(Host,<<"/api/node/backup.zip">>),
		true=is_binary(Bin),
		DBPath=application:get_env(tpnode,dbpath,"db"),
		file:write_file(DBPath++"/backup.zip", Bin),
		true
	catch Ec:Ee ->
			  logger:notice("Beckup fetch from ~s errror Ec:Ee",[Host, Ec,Ee]),
			  try_fetch_backup(N-1, List, Retry)
	end.

try_fetch_backup(N, List) ->
	try_fetch_backup(N, List, N).


try_restore_db(FetchFrom) ->
  ExistsDBPath=filelib:is_dir(utils:dbpath(db)),
  ExistsLedgerPath=filelib:is_dir(utils:dbpath(mledger)),

  if(ExistsDBPath =/= false) ->
      {ignore, db_exists};
    (ExistsLedgerPath =/= false) ->
      {ignore, mledger_exists};
    true ->
      DBPath=application:get_env(tpnode,dbpath,"db"),
      RPath=DBPath++"/restore",
      DelAfter=case filelib:is_dir(RPath) of
        true ->
          false;
        false ->
          case filelib:is_file(DBPath++"/backup.zip") of
            false ->
				  io:format("Trying to fetch from ~p~n",[FetchFrom]),
				  try_fetch_backup(2, FetchFrom),
				  case filelib:is_regular(DBPath++"/backup.zip") of
					  false -> false;
					  true ->
						  zip:extract(DBPath++"/backup.zip", [{cwd,RPath}]),
						  true
				  end;
            true ->
				  zip:extract(DBPath++"/backup.zip", [{cwd,RPath}]),
				  true
          end
      end,
      Res=case file:consult(RPath++"/backup.txt") of
        {ok, [#{dir:=Dir}=_Map]} ->
          DP=RPath++"/"++Dir,
          BlDir=filelib:is_dir(DP++".blocks"),
          MLDir=filelib:is_dir(DP++".mledger"),
          if(BlDir==false) ->
              {error, no_blocks_db};
            (MLDir==false) ->
              {error, no_mledger_db};
            true ->
              rockstable:restore(DP++".mledger",utils:dbpath(mledger)),
              rockstable:restore(DP++".blocks",utils:dbpath(db)),
              spawn(
                fun() ->
                    timer:sleep(10000),
                    try blockchain_sync ! runsync catch _:_ -> ok end,
                    timer:sleep(10000+trunc(rand:uniform()*90000)),
                    try blockchain_sync ! runsync catch _:_ -> ok end
                end),
              {ok, DP}
          end;
        {error, E} ->
          {error, E}
      end,
      if DelAfter ->
           file:del_dir_r(RPath);
         true ->
           ignore
      end,
      Res
  end.

init([repl_sup]) ->
  Sup={_SupFlags = {simple_one_for_one, 5, 10},
       [
        #{start=>{tpnode_repl_worker,start_link,[]}, id=>simpleid}
       ]
      },
  {ok, Sup};

init([]) ->
	case proplists:get_value("WORKDIR",os:env()) of
		undefined -> ok;
		L when is_list(L) ->
			file:set_cwd(L)
	end,
	case tpnode:reload() of
		ok -> ok;
		{error,enoent} ->
			{ok,CWD}=file:get_cwd(),
			throw({no_config_file_in,CWD});
		{error, Reason} ->
			throw(Reason)
	end,

    case check_key() of
      ok -> ok;
      {error, Reason1} ->
        throw(Reason1)
    end,

    MandatoryServices = [ api ],
    VMHost=case application:get_env(tpnode,vmaddr,undefined) of
             XHost when is_list(XHost) ->
               {ok,Tuple}=inet:parse_address(XHost),
               Tuple;
             _ ->
               XHost="127.0.0.1",
               application:set_env(tpnode,vmaddr,XHost),
               {ok,Tuple}=inet:parse_address(XHost),
               Tuple
           end,
    VMPort=case application:get_env(tpnode,vmport,undefined) of
             XPort when is_integer(XPort) ->
               XPort;
             _ ->
               XPort=utils:alloc_tcp_port(),
               application:set_env(tpnode,vmport,XPort),
               XPort
           end,
    RestRes=try_restore_db(application:get_env(tpnode,upstream, [])),
    logger:info("Restore result ~p",[RestRes]),

    filelib:ensure_dir( utils:dbpath(db) ),
    %DBPath=application:get_env(tpnode,dbpath,"db"),
    %filelib:ensure_dir([DBPath,"/"]),
    ok=mledger:start_db(),
    ok=logs_db:start_db(),

    Management=case application:get_env(tpnode,management,undefined) of
                 X when is_list(X) ->
                   X;
                 _ ->
                   case utils:read_cfg(mgmt_cfg,[]) of
                     Cfg when is_list(Cfg) ->
                       proplists:get_value(management,Cfg,undefined);
                     {error, _} ->
                       undefined
                   end
               end,

    MgChildren=case Management of
                  undefined ->
                    [];
                  _ ->
                    [
                     { mgmt_sup, {tpnode_netmgmt_sup, start_link, [mgmt, Management]},
                       permanent, 5000, worker, []}
                    ]
                end,

    case application:get_env(tpnode,watchdog,undefined) of
      true ->
        tpwdt:start();
      false ->
        ok;
      undefined ->
        ok
    end,

    Discovery=#{name=>discovery, services=>MandatoryServices},

    Services=case application:get_env(tpnode,replica,false) of
               true -> %slave node
                 case application:get_env(tpnode,upstream, undefined) of
                   undefined ->
                     case application:get_env(tpnode,connect_chain) of
                       {ok, Number} ->
                         Upstream=tpnode_peerfinder:check_peers(tpnode_peerfinder:propose_seed(Number,[]),2),
                         application:set_env(tpnode,upstream,Upstream);
                       _ -> ok
                     end;
                   _ -> ok
                 end,
                 [
                  { tpnode_repl, {tpnode_repl, start_link, []}, permanent, 5000, worker, []},
                  { repl_sup,
                    {supervisor, start_link, [ {local, repl_sup}, ?MODULE, [repl_sup]]},
                    permanent, 20000, supervisor, []
                  }
                 ];
               false -> %consensus node
                 VM_CS=case application:get_env(tpnode,run_wanode,true) of
                         true ->
                           [{ wasm_vm, {vm_wasm, start_link, []}, permanent, 5000, worker, []}];
                         _ ->
                           []
                       end,
                 GetTPICPeers=fun(_) ->
                                  SP=try
                                       {ok,[DBPeers]}=file:consult(utils:dbpath(peers)),
                                       DBPeers
                                     catch _:_ ->
                                             []
                                     end,
                                  if(SP==[]) ->
                                      case application:get_env(tpnode,connect_chain,undefined) of
                                        I when is_integer(I) ->
                                          TPIC_Port=maps:get(port,application:get_env(tpnode,tpic,#{}),1800),
                                          tpnode_peerfinder:propose_tpic(I,TPIC_Port);
                                        _ ->
                                          [{undefined,maps:get(peers,application:get_env(tpnode,tpic,#{}),[])}]
                                      end;
                                    true ->
                                      SP
                                  end
                              end,
                 TpicOpts=#{get_peers=>GetTPICPeers},
                 [
                  { blockchain_sync, {blockchain_sync, start_link, []}, permanent, 5000, worker, []},
                  { synchronizer, {synchronizer, start_link, []}, permanent, 5000, worker, []},
                  { mkblock, {mkblock, start_link, []}, permanent, 5000, worker, []},
                  { tpnode_reporter, {tpnode_reporter, start_link, []}, permanent, 5000, worker, []},
                  { topology, {topology, start_link, []}, permanent, 5000, worker, []},
                  { xchain_client, {xchain_client, start_link, [#{}]}, permanent, 5000, worker, []},
                  { xchain_dispatcher, {xchain_dispatcher, start_link, []}, permanent, 5000, worker, []},
                  { chainkeeper, {chainkeeper, start_link, []}, permanent, 5000, worker, []}
                  |VM_CS]
                 ++ xchain:childspec()
                 ++ tpic2:childspec(TpicOpts)
                 ++ tpnode_vmproto:childspec(VMHost, VMPort)
             end,


    Childs=[
            { rdb_dispatcher, {rdb_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { blockchain_updater, {blockchain_updater, start_link, []},
              permanent, 5000, worker, []},

            { blockchain_reader, {blockchain_reader, start_link, []},
              permanent, 5000, worker, []},

            { blockvote, {blockvote, start_link, []},
              permanent, 5000, worker, []},

            { ws_dispatcher, {tpnode_ws_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { txqueue, {txqueue, start_link, []},
              permanent, 5000, worker, []},

            { txstorage, {tpnode_txstorage, start_link,
                          [#{name => txstorage}]},
              permanent, 5000, worker, []},

            { txpool, {txpool, start_link, []},
              permanent, 5000, worker, []},

            { txstatus, {txstatus, start_link, [txstatus]},
              permanent, 5000, worker, []},

            { discovery, {discovery, start_link, [Discovery]},
              permanent, 5000, worker, []},

            { tpnode_announcer, {tpnode_announcer, start_link, [#{}]},
              permanent, 5000, worker, []},

%            { tpnode_cert, {tpnode_cert, start_link, []},
%              permanent, 5000, worker, []},

            { tpnode_vmsrv, {tpnode_vmsrv, start_link, []},
              permanent, 5000, worker, []}

           ]
            ++ Services
            ++ MgChildren
            ++ tpnode_http:childspec_ssl()
            ++ tpnode_http:childspec(),
    {ok, { {one_for_one, 5, 10}, Childs } }.

