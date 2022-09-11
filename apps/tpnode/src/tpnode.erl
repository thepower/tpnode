-module(tpnode).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, stop/0, reload/0, die/1]).

-include("include/version.hrl").
%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(tpnode).

start(_StartType, _StartArgs) ->
    application:unset_env(tpnode, dead),
    tpnode_sup:start_link().

stop(_State) ->
    ok.

reload() ->
    ConfigFile=application:get_env(tpnode, config, "node.config"),
    case file:consult(ConfigFile) of
        {ok, Config} ->
            lists:foreach(
              fun({K, V}) ->
                      application:set_env(tpnode, K, V)
              end, Config),
            application:unset_env(tpnode, pubkey);
        {error, Any} ->
            {error, Any}
    end.

die(Reason) ->
  logger:error("Node dead: ~p",[Reason]),
  application:set_env(tpnode,dead,Reason),
  Shutdown = [ discovery, synchronizer, chainkeeper, blockchain_updater,
               blockchain_sync, blockvote, mkblock, txstorage, txqueue,
               txpool, txstatus, topology, ledger, tpnode_announcer,
               xchain_client, xchain_dispatcher, tpnode_vmsrv ],
  [ supervisor:terminate_child(tpnode_sup,S) || S<- Shutdown ].



