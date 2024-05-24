-module(tpnode).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, stop/0, restart/0, reload/0, die/1]).

-include("include/version.hrl").
-include("include/tplog.hrl").
%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(tpnode).

restart() ->
  spawn(
    fun() ->
        tpnode:stop(),
        timer:sleep(3000),
        tpnode:start()
    end).

start(_StartType, _StartArgs) ->
    application:unset_env(tpnode, dead),
    tpnode_sup:start_link().

stop(_State) ->
    ok.

reload() ->
  ConfigFile=application:get_env(tpnode, config, "node.config"),
  case file:consult(ConfigFile) of
    {ok, Config} ->
      Config2=case file:consult(utils:dbpath('config_override')) of
                {ok, Overrides} ->
                  logger:info("Applying config overrides: ~p", [Overrides]),
                  lists:foldl(
                    fun({keyfile, Value}, Acc) ->
                        [{keyfile, Value} | lists:keydelete(privkey,1,Acc)];
                       ({Key, Value}, Acc) ->
                        [{Key, Value} | lists:keydelete(Key,1,Acc)]
                    end,
                    Config,
                    Overrides);
                _ ->
                  Config
              end,
      lists:foreach(
        fun({keyfile, Filename}) ->
            try
              {ok, PrivKeyFile}=file:consult(Filename),
              {privkey,Key} = lists:keyfind(privkey,1,PrivKeyFile),
              application:set_env(tpnode, privkey, Key)
            catch Ec:Ee ->
                    logger:error("Failed to load ext privkey from ~s: ~p:~p", [Filename, Ec, Ee]),
                    throw('failed_to_load_ext_privkey')
            end;
           ({K, V}) ->
            application:set_env(tpnode, K, V)
        end, Config2),

      Proc=fun(EEnv,OEnv,Fun) ->
               case application:get_env(tpnode, EEnv) of
                 {ok, _} ->
                   ok;
                 undefined ->
                   case os:getenv(OEnv) of
                     false ->
                       ignore;
                     MVal ->
                       case Fun(MVal) of
                         {ok, Val1} ->
                           application:set_env(tpnode, EEnv, Val1);
                         Any ->
                           {error, Any}
                       end
                   end
               end
           end,
      Proc(hostname, "TPNODE_HOSTNAME", fun(H) -> {ok, H} end),
      Proc(connect_chain, "TPNODE_CONNECT_CHAIN",
           fun(Val) ->
               {ok, list_to_integer(Val)}
           end),
      Proc(tpic, "TPNODE_TPIC_PORT",
           fun(Val) ->
               {ok, #{peers => [],port => list_to_integer(Val)}}
           end),
      Proc(privkey, "TPNODE_PRIVKEY",
           fun(Val) ->
               case tpecdsa:keytype(hex:decode(Val)) of
                 {priv,ed25519} -> {ok, Val};
                 _ -> badkey
               end
           end),

      logger_reconfig(),
      application:unset_env(tpnode, pubkey),
      application:unset_env(tpnode,privkey_dec);
    {error, Any} ->
      {error, Any}
  end.

logger_reconfig() ->

  logger:remove_handler(default),
  L=case application:get_env(tpnode, loglevel, info) of
        info -> info;
        debug -> debug;
        notice -> notice;
        error -> error;
        _ -> info
      end,
  logger:set_primary_config( #{filter_default => log, level => L }),
  Host=application:get_env(tpnode,hostname,atom_to_list(node())),

  logger:remove_handler(disk_debug_log),
  if(L==debug) ->
      logger:add_handler(disk_debug_log, logger_std_h,
                         #{config => #{
                                       file => application:get_env(tpnode,debug_log,"log/debug_"++Host++".log"),
                                       type => file,
                                       max_no_files => 10,
                                       max_no_bytes => 52428800 % 10 x 5mb
                                      },
                           level => all,
                           filters => [{nosasl, {fun logger_filters:progress/2, stop}}]
                          }),
      logger:update_handler_config(disk_debug_log,formatter,
                                   {logger_formatter,#{template => [time," ",file,":",line," ",level,": ",msg,"\n"]}});
    true -> 
      ok
  end,

  logger:remove_handler(disk_info_log),
  logger:add_handler(disk_info_log, logger_std_h,
                     #{config => #{
                                   file => application:get_env(tpnode,info_log,"log/info_"++Host++".log"),
                                   type => file,
                                   max_no_files => 10,
                                   max_no_bytes => 52428800 % 10 x 5mb
                                  },
                       level => info,
                       filters => [{nosasl, {fun logger_filters:progress/2, stop}}]
                      }),
  logger:update_handler_config(disk_info_log,formatter,
                               {logger_formatter,#{template => [time," ",file,":",line," ",level,": ",msg,"\n"]}}),
  logger:remove_handler(disk_err_log),
  logger:add_handler(disk_err_log, logger_std_h,
                     #{config => #{
                                   file => application:get_env(tpnode,error_log,"log/error_"++Host++".log"),
                                   type => file,
                                   max_no_files => 10,
                                   max_no_bytes => 52428800 % 10 x 5mb
                                  },
                       level => error
                      }
                    ),
  logger:update_handler_config(disk_err_log,formatter,
                               {logger_formatter,#{template => [time," ",file,":",line," ",level,": ",msg,"\n"]}}),
  ok.

die(Reason) ->
  spawn(fun() ->
            ?LOG_ERROR("Node dead: ~p",[Reason]),
            application:set_env(tpnode,dead,Reason),
            Shutdown = [ discovery, synchronizer, chainkeeper, blockchain_updater,
                         blockchain_sync, blockvote, mkblock, txstorage, txqueue,
                         txpool, txstatus, topology, tpnode_announcer,
                         xchain_client, xchain_dispatcher, tpnode_vmsrv, tpnode_repl, repl_sup],
            _ = catch tpwdt:stop(),
            [ ?LOG_INFO("Terminate ~p: ~p",[S,catch supervisor:terminate_child(tpnode_sup,S)]) || S<- Shutdown ]
        end), receive never -> done end.



