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

load_priv() ->
  case application:get_env(tpnode, privkey, false) of
    false ->
      case file:consult(utils:dbpath("node.key")) of
        {error,enoent} ->
          application:set_env(tpnode, privkey,
                              binary_to_list(hex:encodex(tpecdsa:generate_priv(ed25519))));
        {ok,[{privkey,Priv}]} ->
          application:set_env(tpnode, privkey, Priv)
      end;
    _ -> ok
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
  {ok, Cwd} = file:get_cwd(),

  tpnode:reload(),
  ConfigMode=lists:all(
               fun(E) ->
                   application:get_env(tpnode, E, false)==false
               end,
               [tpic, replica, ygg_peers, yggdrasil_peers, upstream]),

  load_priv(),
  case ConfigMode of
    true ->
      tpwdt:stop(),
      Secret=base58:encode(crypto:strong_rand_bytes(16)),
      HttpPort=utils:tcp_port_or_other(1080),
      HttpsPort=utils:tcp_port_or_other(1443),

      application:set_env(tpnode, dbsuffix, ""),
      application:set_env(tpnode, rpcport, HttpPort),
      application:set_env(tpnode, rpcsport, HttpsPort),
      application:set_env(tpnode, nodename, <<"unconfigured_node">>),
      application:set_env(tpnode, hostname, string:chomp(os:cmd("hostname"))),
      application:set_env(tpnode, conf_secret, crypto:hash(sha256, Secret)),
      Msg=[
           io_lib:format("No tpnode config file found, starting with preconfiguration mode~n",[]),
           io_lib:format("Visit one of the following urls to configure your node:~n",[]),
           io_lib:format(" - https://~s:~w/start~n",[application:get_env(tpnode,hostname,"127.0.0.1"),
                                                     HttpsPort]),
           io_lib:format(" - https://localhost:~w/start~n",[HttpsPort]),
           io_lib:format(" Your configuration token is ~s~n",[Secret])
          ],

      io:format("~s",[Msg]),
      lists:foreach( fun(X) -> logger:notice("~s",[X]) end, Msg),
      tpwdt:stop(),
      Childs = tpnode_http:childspec_ssl() ++ tpnode_http:childspec(),
      {ok, { {one_for_one, 5, 10}, Childs } };
    false ->
      case check_key() of
        ok -> ok;
        {error, Reason1} ->
          throw(Reason1)
      end,

      RestRes=try_restore_db(application:get_env(tpnode,upstream, [])),
      logger:info("Restore result ~p",[RestRes]),

      filelib:ensure_dir( utils:dbpath(db) ),
      %DBPath=application:get_env(tpnode,dbpath,"db"),
      %filelib:ensure_dir([DBPath,"/"]),
      ok=mledger:start_db(),
      ok=logs_db:start_db(),

      case application:get_env(tpnode,watchdog,undefined) of
        true ->
          tpwdt:start();
        false ->
          ok;
        undefined ->
          ok
      end,

      Yggdrasil = case application:get_env(tpnode,yggstack,false) of
                    true ->
                      Peers=application:get_env(tpnode,yggdrasil_peers,[<<"tls://asia.deinfra.org:15015">>]),
                      YggArg=#{
                               priv=>nodekey:get_priv(),
                               listen=>application:get_env(tpnode,yggport,15015),
                               admin=>filename:join(Cwd,"yggstack_admin.sock"),
                               peers=>Peers,
                               export=>tpnode:resolve_ports([{80,rpcport},{443,rpcsport},{1800,tpicport}])
                              },
                      [
                       {yggstack,
                        {ygg,start_stack,[YggArg]},
                        permanent, 5000, worker, []},
                       {yggpeers,
                        {tpnode_yggpeers,start_link,[]},
                        permanent, 5000, worker, []}
                      ];
                    false ->
                      []
                  end,


      MandatoryServices = if Yggdrasil == [] ->
                               [ api ];
                             true ->
                               [ api, ygg ]
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
                   VM_CS=case application:get_env(tpnode,run_wanode,false) of
                           true ->
                             [{ wasm_vm, {vm_wasm, start_link, []}, permanent, 5000, worker, []}];
                           _ ->
                             []
                         end,
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
      ++ Yggdrasil
      ++ tpic2:childspec(TpicOpts)
      ++ tpnode_http:childspec_ssl()
      ++ tpnode_http:childspec(),
      {ok, { {one_for_one, 5, 10}, Childs } }
  end.

