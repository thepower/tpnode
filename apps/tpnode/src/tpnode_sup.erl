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
                          {port, 
                           application:get_env(tpnode,rpcport,43280)
                          },
                          {ip, {0,0,0,0,0,0,0,0}},
                          {public, "public"}
                         ]),
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
            {
             h2ldb,
             {h2leveldb, start_link, [ [] ]},
             permanent, 5000, worker, []
            },
            { blockchain, {blockchain,start_link,[]}, permanent, 5000, worker, []},
            { synchronizer, {synchronizer,start_link,[]}, permanent, 5000, worker, []},
            { mkblock, {mkblock,start_link,[]}, permanent, 5000, worker, []},
            { txpool, {txpool,start_link,[]}, permanent, 5000, worker, []}
           ]} }.

