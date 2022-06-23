-module(erun).
-export([start/0,stop/0,reload/0]).

start() ->
  application:ensure_all_started(erun).

stop() ->
  application:stop(erun).

reload() ->
    ConfigFile=application:get_env(erun, config, "erun.config"),
    case file:consult(ConfigFile) of
        {ok, Config} ->
            lists:foreach(
              fun({K, V}) ->
                      application:set_env(erun, K, V)
              end, Config);
        {error, Any} ->
            {error, Any}
    end.

