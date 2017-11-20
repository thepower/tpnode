-module(tpnode).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, stop/0]).

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
