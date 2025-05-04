%%%-------------------------------------------------------------------
%% @doc teaclient public API
%% @end
%%%-------------------------------------------------------------------

-module(teaclient_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    teaclient_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
