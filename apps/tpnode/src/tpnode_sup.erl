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
    code:ensure_loaded(tpic_checkauth),
    tpnode:reload(),

    % we'll register this services-without-pid on discovery starting up
    MandatoryServices = [ api ],

    {ok, TPIC0}=application:get_env(tpnode, tpic),
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
    VMHost=case application:get_env(tpnode,vmaddr,undefined) of
             XHost when is_list(XHost) ->
               {ok,Tuple}=inet:parse_address(XHost),
               Tuple;
             _ ->
               XHost="127.0.0.1",
               application:set_env(tpnode,vmaddr,XHost),
               {ok,Tuple}=inet:parse_address(XHost),
               Tuple
           end,
    VMPort=case application:get_env(tpnode,vmport,undefined) of
             XPort when is_integer(XPort) ->
               XPort;
             _ ->
               XPort=utils:alloc_tcp_port(),
               application:set_env(tpnode,vmport,XPort),
               XPort
           end,
    VM_CS=case application:get_env(tpnode,run_wanode,true) of
            true ->
              [{ wasm_vm, {vm_wasm, start_link, []}, permanent, 5000, worker, []}];
            _ ->
              []
          end,

		Discovery=#{name=>discovery, services=>MandatoryServices},
    Childs=[
            { rdb_dispatcher, {rdb_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { blockchain, {blockchain, start_link, []},
              permanent, 5000, worker, []},

            { blockvote, {blockvote, start_link, []},
              permanent, 5000, worker, []},

            { ws_dispatcher, {tpnode_ws_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { synchronizer, {synchronizer, start_link, []},
              permanent, 5000, worker, []},

            { mkblock, {mkblock, start_link, []},
              permanent, 5000, worker, []},

            { txpool, {txpool, start_link, []},
              permanent, 5000, worker, []},

            { txstatus, {txstatus, start_link, [txstatus]},
              permanent, 5000, worker, []},

            { tpic_sctp, {tpic_sctp, start_link, [TPIC]},
              permanent, 5000, worker, []},

            { topology, {topology, start_link, []}, permanent, 5000, worker, []},
            { ledger, {ledger, start_link, []},
              permanent, 5000, worker, []},

            { discovery, {discovery, start_link, [Discovery]},
              permanent, 5000, worker, []},

            { tpnode_announcer, {tpnode_announcer, start_link, [#{}]},
              permanent, 5000, worker, []},

            { xchain_client, {xchain_client, start_link, [#{}]},
              permanent, 5000, worker, []},

            { xchain_dispatcher, {xchain_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { tpnode_cert, {tpnode_cert, start_link, []},
              permanent, 5000, worker, []},

            { tpnode_vmsrv, {tpnode_vmsrv, start_link, []},
              permanent, 5000, worker, []}

           ] ++ VM_CS
            ++ xchain:childspec()
            ++ tpnode_vmproto:childspec(VMHost, VMPort)
            ++ tpnode_http:childspec(),
    {ok, { {one_for_one, 5, 10}, Childs } }.

