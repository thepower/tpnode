-module(tpwdt).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, stop/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
  logger:info("Starting tpwdt"),
    application:ensure_all_started(?MODULE).

stop() ->
  logger:info("Stopping tpwdt"),
    application:stop(tpwdt).

start(_StartType, _StartArgs) ->
    tpwdt_sup:start_link().

stop(_State) ->
    ok.

