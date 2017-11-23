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
    case application:get_env(tpnode, neighbours) of
        {ok, Neighbours} when is_list(Neighbours) ->
            lists:foreach(
              fun(Node) ->
                      net_adm:ping(Node)
              end, Neighbours);
        _ -> 
            ok
    end,
    
    {ok, { {one_for_one, 5, 10}, 
           [
            { blockchain, {blockchain,start_link,[]}, permanent, 5000, worker, []},
            { ws_dispatcher, {tpnode_ws_dispatcher,start_link,[]}, permanent, 5000, worker, []},
            { synchronizer, {synchronizer,start_link,[]}, permanent, 5000, worker, []},
            { mkblock, {mkblock,start_link,[]}, permanent, 5000, worker, []},
            { txpool, {txpool,start_link,[]}, permanent, 5000, worker, []},
            tpnode_http:childspec()
           ]} }.

