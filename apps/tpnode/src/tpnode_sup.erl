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

    {ok,TPIC0}=application:get_env(tpnode,tpic),
    TPIC=TPIC0#{
           ecdsa=>tpecdsa:generate_priv(),
           authmod=>tpic_checkauth,
           handler=>tpnode_tpic_handler,
           routing=>#{
             <<"timesync">>=>synchronizer,
             <<"mkblock">>=>mkblock,
             <<"blockvote">>=>blockvote,
             <<"blockchain">>=>blockchain
            }
          },
    {ok, { {one_for_one, 5, 10}, 
           [
            { rdb_dispatcher, {rdb_dispatcher,start_link,[]}, permanent, 5000, worker, []},
            { blockchain, {blockchain,start_link,[]}, permanent, 5000, worker, []},
            { blockvote, {blockvote,start_link,[]}, permanent, 5000, worker, []},
            { ws_dispatcher, {tpnode_ws_dispatcher,start_link,[]}, permanent, 5000, worker, []},
            { synchronizer, {synchronizer,start_link,[]}, permanent, 5000, worker, []},
            { mkblock, {mkblock,start_link,[]}, permanent, 5000, worker, []},
            { txpool, {txpool,start_link,[]}, permanent, 5000, worker, []},
            { tpic_sctp, {tpic_sctp, start_link, [TPIC]}, permanent, 5000, worker, []},
            { ledger, {ledger, start_link, []}, permanent, 5000, worker, []},
            { discovery, {discovery, start_link, [#{pid=>discovery, name=>discovery}]}, permanent, 5000, worker, []},
            { tpnode_announcer, {tpnode_announcer, start_link, [#{}]}, permanent, 5000, worker, []},
            { crosschain, {crosschain, start_link, [#{}]}, permanent, 5000, worker, []},
            { xchain_dispatcher, {xchain_dispatcher, start_link, []}, permanent, 5000, worker, []},
            tpnode_http:childspec(),
            xchain_ws_handler:childspec()
           ]
         } }.

