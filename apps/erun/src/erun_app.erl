%%%-------------------------------------------------------------------
%% @doc erun public API
%% @end
%%%-------------------------------------------------------------------

-module(erun_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erun_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
