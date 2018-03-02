-module(tpnode).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, stop/0, reload/0]).

-include("include/version.hrl").
%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    application:stop(tpnode).

start(_StartType, _StartArgs) ->
    tpnode_sup:start_link().

stop(_State) ->
    ok.

reload() ->
    ConfigFile=application:get_env(tpnode,config,"node.config"),
    case file:consult(ConfigFile) of
        {ok, Config} ->
            lists:foreach(
              fun({K,V}) ->
                      application:set_env(tpnode,K,V)
              end, Config);
        {error, Any} ->
            {error, Any}
    end.
