-module(tpnode_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1, check_key/0]).

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

check_key() ->
  try
    Priv=nodekey:get_priv(),
    case tpecdsa:keytype(Priv) of
      {priv, ed25519} -> ok;
      {priv, Type} ->
        throw({keytype_not_supported,Type})
    end,
    Public=nodekey:get_pub(),
    logger:notice("Starting up, pubkey is ~s",[hex:encode(Public)]),
    ok
  catch
    error:{badmatch,undefined} ->
      {error,"privkey does not specified"};
    throw:Reason ->
      {error,Reason};
    Ec:Ee ->
      logger:notice("Node key error ~p:~p",[Ec,Ee]),
      {error,"privkey broken"}
  end.


init([repl_sup]) ->
  Sup={_SupFlags = {simple_one_for_one, 5, 10},
       [
        #{start=>{tpnode_repl_worker,start_link,[]}, id=>simpleid}
       ]
      },
  {ok, Sup};

init([]) ->
    tpnode:reload(),

    case check_key() of
      ok -> ok;
      {error, Reason} ->
        throw(Reason)
    end,

    MandatoryServices = [ api ],
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

    DBPath=application:get_env(tpnode,dbpath,"db"),
    filelib:ensure_dir([DBPath,"/"]),
    ok=mledger:start_db(),
    ok=logs_db:start_db(),
    Management=case application:get_env(tpnode,management,undefined) of
                 X when is_list(X) ->
                   X;
                 _ ->
                   case utils:read_cfg(mgmt_cfg,[]) of
                     {ok, Cfg} ->
                       proplists:get_value(management,Cfg,undefined);
                     {error, _} ->
                       undefined
                   end
               end,

    MgChildren=case Management of
                  undefined ->
                    [];
                  _ ->
                    [
                     { mgmt_sup, {tpnode_netmgmt_sup, start_link, [mgmt, Management]},
                       permanent, 5000, worker, []}
                    ]
                end,

    Discovery=#{name=>discovery, services=>MandatoryServices},

    Services=case application:get_env(tpnode,replica,false) of
               true -> %slave node
                 [
                  { tpnode_repl, {tpnode_repl, start_link, []}, permanent, 5000, worker, []},
                  { repl_sup,
                    {supervisor, start_link, [ {local, repl_sup}, ?MODULE, [repl_sup]]},
                    permanent, 20000, supervisor, []
                  }
                 ];
               false -> %consensus node
                 VM_CS=case application:get_env(tpnode,run_wanode,true) of
                         true ->
                           [{ wasm_vm, {vm_wasm, start_link, []}, permanent, 5000, worker, []}];
                         _ ->
                           []
                       end,
                 [
                  { blockchain_sync, {blockchain_sync, start_link, []}, permanent, 5000, worker, []},
                  { synchronizer, {synchronizer, start_link, []}, permanent, 5000, worker, []},
                  { mkblock, {mkblock, start_link, []}, permanent, 5000, worker, []},
                  { topology, {topology, start_link, []}, permanent, 5000, worker, []},
                  { xchain_client, {xchain_client, start_link, [#{}]}, permanent, 5000, worker, []},
                  { xchain_dispatcher, {xchain_dispatcher, start_link, []}, permanent, 5000, worker, []},
                  { chainkeeper, {chainkeeper, start_link, []}, permanent, 5000, worker, []}
                  |VM_CS]
                 ++ xchain:childspec()
                 ++ tpic2:childspec()
                 ++ tpnode_vmproto:childspec(VMHost, VMPort)
             end,


    Childs=[
            { rdb_dispatcher, {rdb_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { blockchain_updater, {blockchain_updater, start_link, []},
              permanent, 5000, worker, []},

            { blockchain_reader, {blockchain_reader, start_link, []},
              permanent, 5000, worker, []},

            { blockvote, {blockvote, start_link, []},
              permanent, 5000, worker, []},

            { ws_dispatcher, {tpnode_ws_dispatcher, start_link, []},
              permanent, 5000, worker, []},

            { txqueue, {txqueue, start_link, []},
              permanent, 5000, worker, []},

            { txstorage, {tpnode_txstorage, start_link,
                          [#{name => txstorage}]},
              permanent, 5000, worker, []},

            { txpool, {txpool, start_link, []},
              permanent, 5000, worker, []},

            { txstatus, {txstatus, start_link, [txstatus]},
              permanent, 5000, worker, []},

            { discovery, {discovery, start_link, [Discovery]},
              permanent, 5000, worker, []},

            { tpnode_announcer, {tpnode_announcer, start_link, [#{}]},
              permanent, 5000, worker, []},

%            { tpnode_cert, {tpnode_cert, start_link, []},
%              permanent, 5000, worker, []},

            { tpnode_vmsrv, {tpnode_vmsrv, start_link, []},
              permanent, 5000, worker, []}

           ]
            ++ Services
            ++ MgChildren
            ++ tpnode_http:childspec_ssl()
            ++ tpnode_http:childspec(),
    {ok, { {one_for_one, 5, 10}, Childs } }.

