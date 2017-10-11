-module(tpnode_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

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

init([]) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(tinymq),
    {ok,_PID}=axiom:start(tpnode_handlers,
                         [
                          {content_type,"text/html"},
                          {preprocessor, pre_hook},
                          {postprocessor, post_hook},
                          {sessions, []},
                          {nb_acceptors, 100},
                          {host, '_'},
                          {port, 43280},
                          {ip, {0,0,0,0,0,0,0,0}},
                          {public, "public"}
                         ]),
    {ok, { {one_for_one, 5, 10}, 
           [
            { blockchain, {blockchain,start_link,[]}, permanent, 5000, worker, []},
            { mkblock, {mkblock,start_link,[]}, permanent, 5000, worker, []},
            { txpool, {txpool,start_link,[]}, permanent, 5000, worker, []}
           ]} }.

