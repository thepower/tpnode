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
    io:format("Stopping tower\n"),
    application:stop(tpnode),
    io:format("Stopping cowboy listener\n"),
    cowboy:stop_listener(axiom_listener),
    io:format("Stopping axiom\n"),
    application:stop(axiom).



start(_StartType, _StartArgs) ->
    tpnode_sup:start_link().

stop(_State) ->
    ok.
