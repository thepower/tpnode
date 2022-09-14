-module(basic_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


-define(TESTNET_NODES, [
  "test_c4n1",
  "test_c4n2",
  "test_c4n3",
  "test_c5n1",
  "test_c5n2",
  "test_c5n3",
  "test_c6n1",
  "test_c6n2",
  "test_c6n3"
]).

%%-define(TESTNET_NODES, [
%%    "test_c4n1",
%%    "test_c4n2",
%%    "test_c4n3"
%%]).

all() ->
    [
        discovery_got_announce_test,
        discovery_register_test,
        discovery_lookup_test,
        discovery_unregister_by_name_test,
        discovery_unregister_by_pid_test,
        discovery_ssl_test,
        transaction_test,
        register_wallet_test,
        patch_gasprice_test,
        %smartcontract_test,
        evm_test,
        check_blocks_test
        %,crashme_test
        %instant_sync_test
    ].

% -----------------------------------------------------------------------------

init_per_suite(Config) ->
%%    Env = os:getenv(),
%%    io:fwrite("env ~p", [Env]),
%%    io:fwrite("w ~p", [os:cmd("which erl")]),
    file:make_symlink("../../../../db", "db"),
    application:ensure_all_started(inets),
    ok = wait_for_testnet(60),
    %cover_start(),
%%    Config ++ [{processes, Pids}].
    Config.

% -----------------------------------------------------------------------------

init_per_testcase(_, Config) ->
    Config.

% -----------------------------------------------------------------------------

end_per_testcase(_, Config) ->
    Config.

% -----------------------------------------------------------------------------

end_per_suite(Config) ->
%%    Pids = proplists:get_value(processes, Config, []),
%%    lists:foreach(
%%        fun(Pid) ->
%%            io:fwrite("Killing ~p~n", [Pid]),
%%            exec:kill(Pid, 15)
%%        end, Pids),
    %cover_finish(),
    save_bckups(),
    Config.

% -----------------------------------------------------------------------------

save_bckups() ->
    logger("saving bckups"),
    SaveBckupForNode =
        fun(Node) ->
            BckupDir = "/tmp/ledger_bckups/" ++ Node ++ "/",
%%        filelib:ensure_dir("../../../../" ++ BckupDir),
            filelib:ensure_dir(BckupDir),
            logger("saving bckup for node ~p to dir ~p", [Node, BckupDir]),
            rpc:call(get_node(Node), blockchain_updater, backup, [BckupDir])
        end,
    lists:foreach(SaveBckupForNode, get_testnet_nodenames()),
    ok.
  


%%get_node_cmd(Name) when is_list(Name) ->
%%    "erl -progname erl -config " ++ Name ++ ".config -sname "++ Name ++ " -detached -noshell -pa _build/default/lib/*/ebin +SDcpu 2:2: -s lager -s tpnode".
%%%%    "sleep 1000".

%%run_testnet_nodes() ->
%%    exec:start([]),
%%
%%    io:fwrite("my name: ~p", [erlang:node()]),
%%
%%    Pids = lists:foldl(
%%        fun(NodeName, StartedPids) ->
%%            Cmd = get_node_cmd(NodeName),
%%            {ok, _Pid, OsPid} = exec:run_link(Cmd, []),
%%
%%            io:fwrite("Started node ~p with os pid ~p", [NodeName, OsPid]),
%%            [OsPid | StartedPids]
%%        end, [], get_testnet_nodenames()
%%    ),
%%    ok = wait_for_testnet(Pids),
%%    {ok, Pids}.

cover_start() ->
    application:load(tpnode),
    {true,{appl,tpnode,{appl_data,tpnode,_,_,_,Modules,_,_,_},_,_,_,_,_,_}}=application_controller:get_loaded(tpnode),
    cover:compile_beam(Modules),
    lists:map(
        fun(NodeName) ->
            rpc:call(NodeName,cover,compile_beam,[Modules])
        end, nodes()),
    ct_cover:add_nodes(nodes()),
    cover:start(nodes()).

% -----------------------------------------------------------------------------

cover_finish() ->
    logger("going to flush coverage data~n"),
    logger("nodes: ~p~n", [nodes()]),
    erlang:register(ctester, self()),
    ct_cover:remove_nodes(nodes()),
%%    cover:stop(nodes()),
%%    cover:stop(),
    cover:flush(nodes()),
    cover:analyse_to_file([{outdir,"cover1"}]).
%%    timer:sleep(1000).
%%    cover:analyse_to_file([{outdir,"cover"},html]).

% -----------------------------------------------------------------------------

get_node(Name) ->
    NameBin = utils:make_binary(Name),
    [_,NodeHost]=binary:split(atom_to_binary(erlang:node(),utf8),<<"@">>),
    binary_to_atom(<<NameBin/binary, "@", NodeHost/binary>>, utf8).

% -----------------------------------------------------------------------------

wait_for_testnet(Trys) ->
    AllNodes = get_testnet_nodenames(),
    NodesCount = length(AllNodes),
    Alive = lists:foldl(
        fun(Name, ReadyNodes) ->
            NodeName = get_node(Name),
            case net_adm:ping(NodeName) of
                pong ->
                    ReadyNodes + 1;
                _Answer ->
                    io:fwrite("Node ~p answered ~p~n", [NodeName, _Answer]),
                    ReadyNodes
            end
        end, 0, AllNodes),

    if
        Trys<1 ->
            timeout;
        Alive =/= NodesCount ->
            io:fwrite("testnet starting timeout: alive ~p, need ~p", [Alive, NodesCount]),
            timer:sleep(1000),
            wait_for_testnet(Trys-1);
        true -> ok
    end.

% -----------------------------------------------------------------------------

discovery_register_test(_Config) ->
    DiscoveryPid =
      rpc:call(get_node(get_default_nodename()), erlang, whereis, [discovery]),
    Answer = gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    ?assertEqual(ok, Answer).


discovery_lookup_test(_Config) ->
    DiscoveryPid =
      rpc:call(get_node(get_default_nodename()), erlang, whereis, [discovery]),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertMatch({ok, _, <<"test_service">>}, Result1),
    Result2 = gen_server:call(DiscoveryPid, {lookup, <<"nonexist">>}),
    ?assertEqual([], Result2),
    Result3 = gen_server:call(DiscoveryPid, {lookup, <<"tpicpeer">>}),
    ?assertNotEqual(0, length(Result3)).


discovery_unregister_by_name_test(_Config) ->
    DiscoveryPid =
      rpc:call(get_node(get_default_nodename()), erlang, whereis, [discovery]),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    gen_server:call(DiscoveryPid, {register, <<"test_service2">>, self()}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({ok, self(), <<"test_service">>}, Result1),
    gen_server:call(DiscoveryPid, {unregister, <<"test_service">>}),
    Result2 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({error,not_found,<<"test_service">>}, Result2),
    Result3 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({ok, self(), <<"test_service2">>}, Result3).


discovery_unregister_by_pid_test(_Config) ->
    DiscoveryPid =
      rpc:call(get_node(get_default_nodename()), erlang, whereis, [discovery]),
    MyPid = self(),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, MyPid}),
    gen_server:call(DiscoveryPid, {register, <<"test_service2">>, MyPid}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({ok, MyPid, <<"test_service">>}, Result1),
    Result2 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({ok, MyPid, <<"test_service2">>}, Result2),
    gen_server:call(DiscoveryPid, {unregister, MyPid}),
    Result3 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertEqual({error, not_found, <<"test_service">>}, Result3),
    Result4 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service2">>}),
    ?assertEqual({error, not_found, <<"test_service2">>}, Result4).


build_announce(Name) when is_binary(Name)->
  build_announce(#{name => Name});

% build announce as c4n3
build_announce(Options) when is_map(Options) ->
  Now = os:system_time(second),
  Name = maps:get(name, Options, <<"service_name">>),
  Proto =  maps:get(proto, Options, api),
  Port = maps:get(port, Options, 1234),
  Hostname = utils:make_list(maps:get(hostname, Options, "c4n3.pwr.local")),
  Scopes = maps:get(scopes, Options, [api, xchain]),
  Ttl = maps:get(ttl, Options, 600),
  Created = maps:get(created, Options, Now),
  Chain = maps:get(chain, Options, 4),
  Ip = utils:make_binary(maps:get(ip, Options, <<"127.0.0.1">>)),
  Announce = #{
    name => Name,
    address => #{
      address => Ip,
      hostname => Hostname,
      port => Port,
      proto => Proto
    },
    created => Created,
    ttl => Ttl,
    scopes => Scopes,
    nodeid => <<"28AFpshz4W4YD7tbLj1iu4ytpPzQ">>, % id from c4n3
    chain => Chain
  },
  meck:new(nodekey),
  % priv key from c4n3 node
  meck:expect(nodekey, get_priv, fun() ->
    hex:parse("2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0") end),
  AnnounceBin = discovery:pack(Announce),
  meck:unload(nodekey),
  {Announce, AnnounceBin}.

discovery_ssl_test(_Config) ->
  DiscoveryC4N1 = rpc:call(get_node(get_default_nodename()), erlang, whereis, [discovery]),
  ServiceName = <<"apispeer">>,
  {Announce, AnnounceBin} =
    build_announce(#{
      name => ServiceName,
      proto => apis
    }),
  NodeId = maps:get(nodeid, Announce, unknown),
  Address = maps:get(address, Announce, unknown),
  Hostname = utils:make_binary(maps:get(hostname, Address, unknown)),
  IpAddr = utils:make_binary(maps:get(address, Address, unknown)),
  PortNo = maps:get(port, Address, 1234),
  Host = <<"https://", Hostname/binary, ":", (integer_to_binary(PortNo))/binary>>,
  Ip =  <<"https://", IpAddr/binary, ":", (integer_to_binary(PortNo))/binary>>,
  gen_server:cast(DiscoveryC4N1, {got_announce, AnnounceBin}),
  timer:sleep(2000),  % wait for announce propagation
  Result = rpc:call(get_node(get_default_nodename()), tpnode_httpapi, get_nodes, [4]),
  logger("get_nodes answer: ~p~n", [Result]),
  ?assertMatch(#{NodeId := #{ host := _, ip := _}}, Result),
  AddrInfo = maps:get(NodeId, Result, #{}),
  Hosts = maps:get(host, AddrInfo, []),
  Ips = maps:get(ip, AddrInfo, []),
  ?assertEqual(true, lists:member(Host, Hosts)),
  ?assertEqual(true, lists:member(Ip, Ips)).
  
  


discovery_got_announce_test(_Config) ->
    DiscoveryC4N1 = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    DiscoveryC4N2 = rpc:call(get_node(<<"test_c4n2">>), erlang, whereis, [discovery]),
    %DiscoveryC4N3 = rpc:call(get_node(<<"test_c4n3">>), erlang, whereis, [discovery]),
    DiscoveryC5N2 = rpc:call(get_node(<<"test_c5n2">>), erlang, whereis, [discovery]),
    Rnd = integer_to_binary(rand:uniform(100000)),
    ServiceName = <<"looking_glass_", Rnd/binary>>,
    {Announce, AnnounceBin} = build_announce(ServiceName),
    gen_server:cast(DiscoveryC4N1, {got_announce, AnnounceBin}),
    timer:sleep(2000),  % wait for announce propagation
    Result = gen_server:call(DiscoveryC4N1, {lookup, ServiceName, 4}),
    NodeId = maps:get(nodeid, Announce, <<"">>),
    Address = maps:get(address, Announce),
    Experted = [
        maps:put(nodeid, NodeId, Address)
    ],
    ?assertEqual(Experted, Result),
    % c4n1 should forward the announce to c4n2
    Result1 = gen_server:call(DiscoveryC4N2, {lookup, ServiceName, 4}),
    ?assertEqual(Experted, Result1),
    Result2 = gen_server:call(DiscoveryC4N2, {lookup, ServiceName, 5}),
    ?assertEqual([], Result2),
    % c4n3 should discard self announce
    %Result3 = gen_server:call(DiscoveryC4N3, {lookup, ServiceName, 4}),
    %?assertEqual([], Result3),
    % c5n2 should get info from xchain announce
    Result4 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 4}),
    ?assertEqual(Experted, Result4),
    Result5 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 5}),
    ?assertEqual([], Result5).

api_get_tx_status(TxId) ->
    api_get_tx_status(TxId, get_base_url(), 40).

api_get_tx_status(TxId, N) when is_integer(N) ->
    api_get_tx_status(TxId, get_base_url(), N).

api_get_tx_status(TxId, BaseUrl, Timeout) ->
    Status = tpapi:get_tx_status(TxId, BaseUrl, Timeout),
    case Status of
      {ok, timeout, _} ->
        logger("got transaction ~p timeout~n", [TxId]),
        dump_testnet_state();
      {ok, #{<<"res">> := <<"ok">>}, _} ->
        logger("got transaction ~p res=ok~n", [TxId]);
      {ok, #{<<"res">> := <<"bad_seq">>}, _} ->
        logger("got transaction ~p badseq~n", [TxId]),
        dump_testnet_state();
      _ ->
        ok
    end,
    Status.


%% wait for transaction commit using distribution
wait_for_tx(TxId, NodeName) ->
    wait_for_tx(TxId, NodeName, 30).

wait_for_tx(_TxId, _NodeName, 0 = _TrysLeft) ->
    dump_testnet_state(),
    {timeout, _TrysLeft};

wait_for_tx(TxId, NodeName, TrysLeft) ->
    Status = rpc:call(NodeName, txstatus, get, [TxId]),
    logger("got tx status: ~p ~n", [Status]),
    case Status of
        undefined ->
            timer:sleep(1000),
            wait_for_tx(TxId, NodeName, TrysLeft - 1);
        {true, ok} ->
            logger("transaction ~p commited~n", [TxId]),
            {ok, TrysLeft};
        {false, Error} ->
            dump_testnet_state(),
            {error, Error}
    end.


get_wallet_priv_key() ->
    address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>).

get_register_wallet_transaction() ->
    PrivKey = get_wallet_priv_key(),
    tpapi:get_register_wallet_transaction(PrivKey, #{promo => <<"TEST5">>}).

register_wallet_test(_Config) ->
    RegisterTx = get_register_wallet_transaction(),
    Res = api_post_transaction(RegisterTx),
    ?assertEqual(<<"ok">>, maps:get(<<"result">>, Res, unknown)),
    TxId = maps:get(<<"txid">>, Res, unknown),
    ?assertNotEqual(unknown, TxId),
    logger("got txid: ~p~n", [TxId]),
    ?assertMatch(#{<<"result">> := <<"ok">>}, Res),
    {ok, Status, _TrysLeft} = api_get_tx_status(TxId),
    logger("transaction status: ~p ~n trys left: ~p", [Status, _TrysLeft]),
    ?assertNotEqual(timeout, Status),
    ?assertMatch(#{<<"ok">> := true}, Status),
    Wallet = maps:get(<<"res">>, Status, unknown),
    ?assertNotEqual(unknown, Wallet),
    % chech wallet status via API
    Res2 = api_get_wallet(Wallet),
    logger("Info for wallet ~p: ~p", [Wallet, Res2]),
    ?assertMatch(#{<<"result">> := <<"ok">>, <<"txtaddress">> := Wallet}, Res2),
    WalletInfo = maps:get(<<"info">>, Res2, unknown),
    ?assertNotEqual(unknown, WalletInfo),
    PubKeyFromAPI = maps:get(<<"pubkey">>, WalletInfo, unknown),
    ?assertNotEqual(unknown, PubKeyFromAPI).

% base url for c4n1 rpc
get_base_url() ->
  DefaultUrl = "http://pwr.local:49841",
  os:getenv("API_BASE_URL", DefaultUrl).


% get info for wallet
api_get_wallet(Wallet) ->
    tpapi:get_wallet_info(Wallet, get_base_url()).

% post encoded and signed transaction using API
api_post_transaction(Transaction) ->
    api_post_transaction(Transaction, get_base_url()).

api_post_transaction(Transaction, Url) ->
    tpapi:commit_transaction(Transaction, Url).

% post transaction using distribution
dist_post_transaction(Node, Transaction) ->
    rpc:call(Node, txpool, new_tx, [Transaction]).

% register new wallet using API
api_register_wallet() ->
    RegisterTx = get_register_wallet_transaction(),
    Res = api_post_transaction(RegisterTx),
    ?assertEqual(<<"ok">>, maps:get(<<"result">>, Res, unknown)),
    TxId = maps:get(<<"txid">>, Res, unknown),
    ?assertMatch(#{<<"result">> := <<"ok">>}, Res),
    {ok, Status, _} = api_get_tx_status(TxId),
    logger("register wallet transaction status: ~p ~n", [Status]),
    ?assertMatch(#{<<"ok">> := true}, Status),
    Wallet = maps:get(<<"res">>, Status, unknown),
    ?assertNotEqual(unknown, Wallet),
    logger("new wallet has been registered: ~p ~n", [Wallet]),
    Wallet.


% get current sequence for wallet
get_sequence(Node, Wallet) ->
    Ledger = rpc:call(Node, mledger, get, [naddress:decode(Wallet)]),
    case mbal:get(seq, Ledger) of
        Seq when is_integer(Seq) ->
          logger(
            "node ledger seq for wallet ~p (via rpc:call): ~p~n",
            [Wallet, Seq]
          ),
          NewSeq = max(Seq, os:system_time(millisecond)),
          logger("new wallet [~p] seq chosen: ~p~n", [Wallet, NewSeq]),
          NewSeq;
        _ ->
          logger("new wallet [~p] seq chosen: 0~n", [Wallet]),
          0
    end.


make_transaction(From, To, Currency, Amount, Message) ->
    Node = get_node(get_default_nodename()),
    make_transaction(Node, From, To, Currency, Amount, Message).

make_transaction(Node, From, To, Currency, Amount, Message) ->
    Seq = get_sequence(Node, From),
    logger("seq for wallet ~p is ~p ~n", [From, Seq]),
    Tx = tx:construct_tx(#{
                           ver=>2,
                           kind=>generic,
                           from => naddress:decode(From),
                           to => naddress:decode(To),
                           t => os:system_time(millisecond),
                           payload => [
                                       #{purpose=>transfer, amount => Amount, cur => Currency}
                                      ],
                           txext =>#{
                                     msg=>Message
                                    },
                           seq=> Seq + 1
                          }),
    logger("transaction body ~p ~n", [Tx]),
    SignedTx = tx:pack(tx:sign(Tx, get_wallet_priv_key())),
    Res4 = api_post_transaction(SignedTx),
    maps:get(<<"txid">>, Res4, unknown).

new_wallet() ->
  PrivKey = get_wallet_priv_key(),
  PubKey = tpecdsa:calc_pub(PrivKey, true),
  case tpapi:register_wallet(PrivKey, get_base_url()) of
    {error, timeout, TxId} ->
      logger(
        "wallet registration timeout, txid: ~p, pub key: ~p~n",
        [TxId, PubKey]
      ),
      dump_testnet_state(),
      throw(wallet_registration_timeout);
    {ok, Wallet, _TxId} ->
      Wallet;
    Other ->
      logger("wallet registration error: ~p, pub key: ~p ~n", [Other, PubKey]),
      dump_testnet_state(),
      throw(wallet_registration_error)
  end.

% -----------------------------------------------------------------------------

dump_node_state(Parent, NodeName) ->
  States =
    [
      {Module, rpc:call(get_node(NodeName), Module, get_state, [])} ||
      Module <- [blockvote, txpool, txqueue, txstorage]
    ] ++
    [{lastblock, rpc:call(get_node(NodeName), blockchain, last, [])}],
  Parent ! {states, NodeName, States}.

% -----------------------------------------------------------------------------

dump_testnet_state() ->
  logger("dump testnet state ~n"),

  Pids = [
    erlang:spawn(?MODULE, dump_node_state, [self(), NodeName]) ||
    NodeName <- get_testnet_nodenames()
  ],
  
  wait_for_dumpers(Pids),
  ok.
% -----------------------------------------------------------------------------

get_testnet_nodenames() ->
  ?TESTNET_NODES.

% -----------------------------------------------------------------------------

get_default_nodename() ->
  <<"test_c4n1">>.

% -----------------------------------------------------------------------------

wait_for_dumpers(Pids) ->
  wait_for_dumpers(Pids, #{}).


wait_for_dumpers(Pids, StatesAcc) ->
  receive
    {states, NodeName, States} ->
      wait_for_dumpers(Pids, maps:put(NodeName, States, StatesAcc))
  after 500 ->
    case lists:member(true, [is_process_alive(Pid) || Pid <- Pids]) of
      true ->
        wait_for_dumpers(Pids, StatesAcc);
      _ ->
        logger("------ testnet states data ------"),
        
        maps:filter(
          fun
            (NodeName, NodeStates) ->
              [
                logger("~p state of node ~p:~n~p~n", [Module, NodeName, State]) ||
                {Module, State} <- NodeStates
              ],
              false
          end,
          StatesAcc
        ),
        
        logger("------ end of data ------"),
        ok
    end
  end.
% -----------------------------------------------------------------------------
patch_gasprice_test(_Config) ->
%  Privs=[
%         "CF2BD71347FA5D645FD6586CD4FE426AF5DCC2A604C5CC2529AB6861DC948D54",
%         "15A48B170FBDAC808BA80D1692305A8EFC758CBC11252A4338131FC68AFAED6B",
%         "2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0"
%        ],
  Privs=[
         "302E020100300506032B657004220420DE88EBB5ACE713A45B4ADFA6856239DF798E573A8D84543A6DE2F5312C447072",
         "302E020100300506032B657004220420440521F8B059A5D64AB83DC2AF5C955D73A81D29BFBA1278861053449213F5F7",
         "302E020100300506032B657004220420E317848D05354A227200800CF932219840080C832D0D6F57F40B95DA5B5ABCED"
        ],

  PatchTx=tx:construct_tx(
              #{ver=>2,
                kind=>patch,
                patches => [#{
                              <<"p">>=>[<<"current">>,<<"gas">>,<<"FTT">>],
                              <<"t">>=><<"set">>,
                              <<"v">>=>1000
                             }]
               }
             ),
  Patch=tx:pack(lists:foldl(fun(Key,Acc) ->
                                tx:sign(Acc, hex:decode(Key))
                            end, PatchTx, Privs)
               ),

  #{<<"txid">>:=TxID1} = api_post_transaction(Patch),
  {ok, Status1, _} = api_get_tx_status(TxID1),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status1).

mkstring(Bin) when size(Bin)<32 ->
  PadL=32-size(Bin),
  <<Bin/binary,0:(PadL*8)/integer>>.


evm_test(_Config) ->

  {ok,EAddr}=application:get_env(tptest,endless_addr),
%  {ok,EPriv}=application:get_env(tptest,endless_addr_pk),
  ?assertMatch(true, is_binary(EAddr)),
%  ?assertMatch(true, is_binary(EPriv)),
  Priv = get_wallet_priv_key(),

  Wallet = new_wallet(),
  Addr=naddress:decode(Wallet),
  io:format("New wallet ~p / ~p~n",[Wallet,Addr]),
  TxId0 = make_transaction(naddress:encode(EAddr), Wallet, <<"FTT">>, 1000000, <<"hello to EVM">>),
  _TxId1 = make_transaction(naddress:encode(EAddr), Wallet, <<"SK">>, 200, <<"Few SK 4 U">>),
  logger("TxId0: ~p", [TxId0]),
  {ok, Status0, _} = api_get_tx_status(TxId0),
  logger("status: ~p", [Status0]),

  HexCode="606060405260008060146101000a81548160ff0219169083151502179055506000600355600060045534156200003457600080fd5b60405162002d7a38038062002d7a83398101604052808051906020019091908051820191906020018051820191906020018051906020019091905050336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff160217905550836001819055508260079080519060200190620000cf9291906200017a565b508160089080519060200190620000e89291906200017a565b508060098190555083600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000600a60146101000a81548160ff0219169083151502179055505050505062000229565b828054600181600116156101000203166002900490600052602060002090601f016020900481019282601f10620001bd57805160ff1916838001178555620001ee565b82800160010185558215620001ee579182015b82811115620001ed578251825591602001919060010190620001d0565b5b509050620001fd919062000201565b5090565b6200022691905b808211156200022257600081600090555060010162000208565b5090565b90565b612b4180620002396000396000f30060606040523615610194576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff16806306fdde03146101995780630753c30c14610227578063095ea7b3146102605780630e136b19146102a25780630ecb93c0146102cf57806318160ddd1461030857806323b872dd1461033157806326976e3f1461039257806327e235e3146103e7578063313ce56714610434578063353907141461045d5780633eaaf86b146104865780633f4ba83a146104af57806359bf1abe146104c45780635c658165146105155780635c975abb1461058157806370a08231146105ae5780638456cb59146105fb578063893d20e8146106105780638da5cb5b1461066557806395d89b41146106ba578063a9059cbb14610748578063c0324c771461078a578063cc872b66146107b6578063db006a75146107d9578063dd62ed3e146107fc578063dd644f7214610868578063e47d606014610891578063e4997dc5146108e2578063e5b5019a1461091b578063f2fde38b14610944578063f3bdc2281461097d575b600080fd5b34156101a457600080fd5b6101ac6109b6565b6040518080602001828103825283818151815260200191508051906020019080838360005b838110156101ec5780820151818401526020810190506101d1565b50505050905090810190601f1680156102195780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b341561023257600080fd5b61025e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610a54565b005b341561026b57600080fd5b6102a0600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091908035906020019091905050610b71565b005b34156102ad57600080fd5b6102b5610cbf565b604051808215151515815260200191505060405180910390f35b34156102da57600080fd5b610306600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610cd2565b005b341561031357600080fd5b61031b610deb565b6040518082815260200191505060405180910390f35b341561033c57600080fd5b610390600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff16906020019091908035906020019091905050610ebb565b005b341561039d57600080fd5b6103a561109b565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b34156103f257600080fd5b61041e600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506110c1565b6040518082815260200191505060405180910390f35b341561043f57600080fd5b6104476110d9565b6040518082815260200191505060405180910390f35b341561046857600080fd5b6104706110df565b6040518082815260200191505060405180910390f35b341561049157600080fd5b6104996110e5565b6040518082815260200191505060405180910390f35b34156104ba57600080fd5b6104c26110eb565b005b34156104cf57600080fd5b6104fb600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506111a9565b604051808215151515815260200191505060405180910390f35b341561052057600080fd5b61056b600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506111ff565b6040518082815260200191505060405180910390f35b341561058c57600080fd5b610594611224565b604051808215151515815260200191505060405180910390f35b34156105b957600080fd5b6105e5600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611237565b6040518082815260200191505060405180910390f35b341561060657600080fd5b61060e611346565b005b341561061b57600080fd5b610623611406565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561067057600080fd5b61067861142f565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b34156106c557600080fd5b6106cd611454565b6040518080602001828103825283818151815260200191508051906020019080838360005b8381101561070d5780820151818401526020810190506106f2565b50505050905090810190601f16801561073a5780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b341561075357600080fd5b610788600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919080359060200190919050506114f2565b005b341561079557600080fd5b6107b4600480803590602001909190803590602001909190505061169c565b005b34156107c157600080fd5b6107d76004808035906020019091905050611781565b005b34156107e457600080fd5b6107fa6004808035906020019091905050611978565b005b341561080757600080fd5b610852600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611b0b565b6040518082815260200191505060405180910390f35b341561087357600080fd5b61087b611c50565b6040518082815260200191505060405180910390f35b341561089c57600080fd5b6108c8600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611c56565b604051808215151515815260200191505060405180910390f35b34156108ed57600080fd5b610919600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611c76565b005b341561092657600080fd5b61092e611d8f565b6040518082815260200191505060405180910390f35b341561094f57600080fd5b61097b600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611db3565b005b341561098857600080fd5b6109b4600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611e88565b005b60078054600181600116156101000203166002900480601f016020809104026020016040519081016040528092919081815260200182805460018160011615610100020316600290048015610a4c5780601f10610a2157610100808354040283529160200191610a4c565b820191906000526020600020905b815481529060010190602001808311610a2f57829003601f168201915b505050505081565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515610aaf57600080fd5b6001600a60146101000a81548160ff02191690831515021790555080600a60006101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055507fcc358699805e9a8b7f77b522628c7cb9abd07d9efb86b6fb616af1609036a99e81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b604060048101600036905010151515610b8957600080fd5b600a60149054906101000a900460ff1615610caf57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1663aee92d333385856040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050600060405180830381600087803b1515610c9657600080fd5b6102c65a03f11515610ca757600080fd5b505050610cba565b610cb9838361200c565b5b505050565b600a60149054906101000a900460ff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515610d2d57600080fd5b6001600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060006101000a81548160ff0219169083151502179055507f42e160154868087d6bfdc0ca23d96a1c1cfa32f1b72ba9ba27b69b98a0d819dc81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b6000600a60149054906101000a900460ff1615610eb257600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166318160ddd6000604051602001526040518163ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401602060405180830381600087803b1515610e9057600080fd5b6102c65a03f11515610ea157600080fd5b505050604051805190509050610eb8565b60015490505b90565b600060149054906101000a900460ff16151515610ed757600080fd5b600660008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff16151515610f3057600080fd5b600a60149054906101000a900460ff161561108a57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16638b477adb338585856040518563ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001828152602001945050505050600060405180830381600087803b151561107157600080fd5b6102c65a03f1151561108257600080fd5b505050611096565b6110958383836121a9565b5b505050565b600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b60026020528060005260406000206000915090505481565b60095481565b60045481565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614151561114657600080fd5b600060149054906101000a900460ff16151561116157600080fd5b60008060146101000a81548160ff0219169083151502179055507f7805862f689e2f13df9f062ff482ad3ad112aca9e0847911ed832e158c525b3360405160405180910390a1565b6000600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff169050919050565b6005602052816000526040600020602052806000526040600020600091509150505481565b600060149054906101000a900460ff1681565b6000600a60149054906101000a900460ff161561133557600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166370a08231836000604051602001526040518263ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001915050602060405180830381600087803b151561131357600080fd5b6102c65a03f1151561132457600080fd5b505050604051805190509050611341565b61133e82612650565b90505b919050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156113a157600080fd5b600060149054906101000a900460ff161515156113bd57600080fd5b6001600060146101000a81548160ff0219169083151502179055507f6985a02210a168e66602d3235cb6db0e70f92b3ba4d376a33c0f3d9434bff62560405160405180910390a1565b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b60088054600181600116156101000203166002900480601f0160208091040260200160405190810160405280929190818152602001828054600181600116156101000203166002900480156114ea5780601f106114bf576101008083540402835291602001916114ea565b820191906000526020600020905b8154815290600101906020018083116114cd57829003601f168201915b505050505081565b600060149054906101000a900460ff1615151561150e57600080fd5b600660003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff1615151561156757600080fd5b600a60149054906101000a900460ff161561168d57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16636e18980a3384846040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050600060405180830381600087803b151561167457600080fd5b6102c65a03f1151561168557600080fd5b505050611698565b6116978282612699565b5b5050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156116f757600080fd5b60148210151561170657600080fd5b60328110151561171557600080fd5b81600381905550611734600954600a0a82612a0190919063ffffffff16565b6004819055507fb044a1e409eac5c48e5af22d4af52670dd1a99059537a78b31b48c6500a6354e600354600454604051808381526020018281526020019250505060405180910390a15050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156117dc57600080fd5b60015481600154011115156117f057600080fd5b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205481600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054011115156118c057600080fd5b80600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008282540192505081905550806001600082825401925050819055507fcb8241adb0c3fdb35b70c24ce35c5eb0c17af7431c99f827d44a445ca624176a816040518082815260200191505060405180910390a150565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156119d357600080fd5b80600154101515156119e457600080fd5b80600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205410151515611a5357600080fd5b8060016000828254039250508190555080600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020600082825403925050819055507f702d5967f45f6513a38ffc42d6ba9bf230bd40e8f53b16363c7eb4fd2deb9a44816040518082815260200191505060405180910390a150565b6000600a60149054906101000a900460ff1615611c3d57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1663dd62ed3e84846000604051602001526040518363ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200192505050602060405180830381600087803b1515611c1b57600080fd5b6102c65a03f11515611c2c57600080fd5b505050604051805190509050611c4a565b611c478383612a3c565b90505b92915050565b60035481565b60066020528060005260406000206000915054906101000a900460ff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611cd157600080fd5b6000600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060006101000a81548160ff0219169083151502179055507fd7e9ec6e6ecd65492dce6bf513cd6867560d49544421d0783ddf06e76c24470c81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611e0e57600080fd5b600073ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff16141515611e8557806000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055505b50565b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611ee557600080fd5b600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff161515611f3d57600080fd5b611f4682611237565b90506000600260008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002081905550806001600082825403925050819055507f61e6e66b0d6339b2980aecc6ccc0039736791f0ccde9ed512e789a7fbdd698c68282604051808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019250505060405180910390a15050565b60406004810160003690501015151561202457600080fd5b600082141580156120b257506000600560003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205414155b1515156120be57600080fd5b81600560003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055508273ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040518082815260200191505060405180910390a3505050565b60008060006060600481016000369050101515156121c657600080fd5b600560008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054935061226e61271061226060035488612a0190919063ffffffff16565b612ac390919063ffffffff16565b92506004548311156122805760045492505b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84101561233c576122bb8585612ade90919063ffffffff16565b600560008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055505b61234f8386612ade90919063ffffffff16565b91506123a385600260008a73ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612ade90919063ffffffff16565b600260008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000208190555061243882600260008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000208190555060008311156125e2576124f783600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168773ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef856040518082815260200191505060405180910390a35b8573ffffffffffffffffffffffffffffffffffffffff168773ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040518082815260200191505060405180910390a350505050505050565b6000600260008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b6000806040600481016000369050101515156126b457600080fd5b6126dd6127106126cf60035487612a0190919063ffffffff16565b612ac390919063ffffffff16565b92506004548311156126ef5760045492505b6127028385612ade90919063ffffffff16565b915061275684600260003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612ade90919063ffffffff16565b600260003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506127eb82600260008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008773ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000831115612995576128aa83600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef856040518082815260200191505060405180910390a35b8473ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040518082815260200191505060405180910390a35050505050565b6000806000841415612a165760009150612a35565b8284029050828482811515612a2757fe5b04141515612a3157fe5b8091505b5092915050565b6000600560008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054905092915050565b6000808284811515612ad157fe5b0490508091505092915050565b6000828211151515612aec57fe5b818303905092915050565b6000808284019050838110151515612b0b57fe5b80915050929150505600a165627a7a72305820b998c49c782be6163974806b4787b7c008b8b8df9199674cea8c302ddfba7ee10029",
  Code0=hex:decode(HexCode),

  CoinSym=mkstring(<<"CoinSym">>),
  Code= <<Code0/binary,(131072):256/big,CoinSym/binary,CoinSym/binary,3:256/big>>,

  DeployTx=tx:pack(
             tx:sign(
             tx:construct_tx(
               #{ver=>2,
                 kind=>deploy,
                 from=>Addr,
                 seq=>os:system_time(millisecond),
                 t=>os:system_time(millisecond),
                 payload=>[#{purpose=>gas, amount=>150000, cur=><<"FTT">>}],
                 txext=>#{ "code"=> Code, "vm" => "evm" }
                }
              ),Priv)),

  #{<<"txid">>:=TxID1} = api_post_transaction(DeployTx),
  io:format("Deploy txid ~p~n",[TxID1]),
  {ok, Status1, _} = api_get_tx_status(TxID1),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status1),

  GenTx=tx:pack(
          tx:sign(
          tx:construct_tx(
            #{ver=>2,
              kind=>generic,
              to=>Addr,
              from=>Addr,
              seq=>os:system_time(millisecond),
              t=>os:system_time(millisecond),
              payload=>[#{purpose=>gas, amount=>150000, cur=><<"FTT">>}],
              call=>#{
                      args=>[<<12345:256/big>>, 1024],
                      function => "transfer(address,uint256)"
                     }
             }
           ),Priv)),

  #{<<"txid">>:=TxID2} = api_post_transaction(GenTx),
  io:format("ERC20 transfer txid ~p~n",[TxID2]),
  {ok, #{<<"block">>:=Blkid2}=Status2, _} = api_get_tx_status(TxID2),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),


  Block2=tpapi:get_fullblock(Blkid2,get_base_url()),

  io:format("Block2 ~p~n",[Block2]),

%  {ok, StatusDJ, _} = api_get_tx_status(DJTxID, 65),
%  io:format("DJ tx status ~p~n",[StatusDJ]),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, StatusDJ),
  ok.

%smartcontract_test(_Config) ->
%  {ok,Addr}=application:get_env(tptest,endless_addr),
%  {ok,Priv}=application:get_env(tptest,endless_addr_pk),
%  ?assertMatch(true, is_binary(Addr)),
%  ?assertMatch(true, is_binary(Priv)),
%
%  %spawn erltest VMs
%  _Pids=[ vm_erltest:run("127.0.0.1",P) || P<- [29841,29842,29843] ],
%  timer:sleep(1000),
%
%  %{ok, Code}=file:read_file("../examples/testcontract_emit.ec"),
%  Code=zlib:uncompress(base64:decode("eJzlVn+PozYQ/Z9PYRGtDu6cDZCQZCkgnSqlqq49nS5RVWmFIgecLF1ic2A2iaLsZ78xPwKXbbfttqee1FW8Nvb4zfObAc/VFeq/7qP8wATZO4hmCWEbOaUoMXfWPNsSoakfMvpAI7TO+Bbl4SNTddxd/pkShkS8pSjO0WMK6/hWzi1gKgDTI7/Hc0EEPSEPbfNNSsJ7p2Cy07YkzZ0NFZrrqrm0UX0fo59otKEZdl3Tmvq+DhjKx4J564IpCGkRTRN+wGrMYgGufoTuF5IEGC0Xex3t7igDIsuYCQogWr2so74PmxGSbJCa0bxIYDfqHV3X8H3k+ch1a1tnPBqs4o3vnzD6geQY3Qan7556XtYe/wKwcQHZN5+C0n1KWR4/0H+IbMDfE/TlJaa4y/hOe0WzjGev9NJ0QxnN4lAeLwRdn9G0q6frzlsOXieeQLEKO4RPGs5Nb268ga34Tw81N5/R60wzol+NZv+lNLvSn4l2IvvN0W0Jt3wZF/H6cCbbO8o33/Fmp+c5v6e7xd7rHR9o5vkWvo9Z5PkVFpYInj+rSEL2eb7RjHP6qfOUkkPCCWy8DZqpCgJmjuqdEKkzGJjGtWXXbWQMBM3FgLIo5UBLhc+GmpZfLIy2NIJexfKlHlr12YMS91TBv1/82sq74tEBi70TcpaLrAjFUuy18lh6I7fxXDD+WP25cf6WgMcLvVckeqnkwB4iaw4NbI5NbBoTbA1haMEQHs0pNkc2tDG2zAkewpIxgulx3SxsT/FoIn/2EI9uMBjCfxjbEzmWA7scgMFIGtsmHk2b3wTghrUnCSf7G2hGPQeubmDewpOajzGtGlgOrdq4NiyXDKAIkn49pem2vDL+hbxuIL9IbMHb4Tmnu/ndZnfvmBZZynMKUJIs2fKCwSa7eiXDAnxBIs8WC1WmbLU9JEni+cC7YKGIOfP887tKsk0OsLZpBadvLb8jmpDDb3z1XyoPOi1XFEoWKulqTX2CovgByc+gjt6g8f8wSm2YnpQIf/NmN19+ryvw8YYa752M79mPjDZGwAcrvaMUDjkeeosbVeXT7NSaS9WluXRZWoNHuEPO5vAIibgmktZJVpRXnRK2Kjib4rXE3MXijhdCu4X4hjwqC9NOkRrgao8efFkML/a/j1IGNY83AYYTXez5Hqijx1x7TPVy5wy/vbAAqRpYGMrFLvsPcdSs5jRZayW+cnURCSDP6G7ZVtndguVa+UhzD4ps7V0p+wyD1JX4XR5hwxRSqGyp7tWe5SUMGSsyEgpcgsAxMKBKMtBdK8pnhrKVtQ==")),
%
%  DeployTx=tx:pack(
%             tx:sign(
%             tx:construct_tx(
%               #{ver=>2,
%                 kind=>deploy,
%                 from=>Addr,
%                 seq=>os:system_time(millisecond),
%                 t=>os:system_time(millisecond),
%                 payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
%                 call=>#{function=>"init",args=>[1024]},
%                 txext=>#{ "code"=> Code,"vm" => "erltest"}}
%              ),Priv)),
%
%  #{<<"txid">>:=TxID1} = api_post_transaction(DeployTx),
%  {ok, Status1, _} = api_get_tx_status(TxID1),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, Status1),
%
%  GenTx=tx:pack(
%          tx:sign(
%          tx:construct_tx(
%            #{ver=>2,
%              kind=>generic,
%              to=>Addr,
%              from=>Addr,
%              seq=>os:system_time(millisecond),
%              t=>os:system_time(millisecond),
%              payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
%              call=>#{function=>"notify",args=>[1024]}
%             }
%           ),Priv)),
%
%  #{<<"txid">>:=TxID2} = api_post_transaction(GenTx),
%  {ok, Status2, _} = api_get_tx_status(TxID2),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
%
%  DJTx=tx:pack(
%         tx:sign(
%         tx:construct_tx(
%           #{ver=>2,
%             kind=>generic,
%             to=>Addr,
%             from=>Addr,
%             seq=>os:system_time(millisecond),
%             t=>os:system_time(millisecond),
%             payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
%             call=>#{function=>"delayjob",args=>[1024]}
%            }),Priv)),
%
%  #{<<"txid">>:=TxID3} = api_post_transaction(DJTx),
%  {ok, #{<<"block">>:=Blkid3}=Status3, _} = api_get_tx_status(TxID3),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, Status3),
%
%  Emit=tx:pack(
%         tx:sign(
%         tx:construct_tx(
%           #{ver=>2,
%             kind=>generic,
%             to=>Addr,
%             from=>Addr,
%             seq=>os:system_time(millisecond),
%             t=>os:system_time(millisecond),
%             payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
%             call=>#{function=>"emit",args=>[1024]}
%            }),Priv)),
%
%  #{<<"txid">>:=TxID4} = api_post_transaction(Emit),
%  {ok, Status4, _} = api_get_tx_status(TxID4),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, Status4),
%
%  BadResp=tx:pack(
%         tx:sign(
%         tx:construct_tx(
%           #{ver=>2,
%             kind=>generic,
%             to=>Addr,
%             from=>Addr,
%             seq=>os:system_time(millisecond),
%             t=>os:system_time(millisecond),
%             payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
%             call=>#{function=>"badnotify",args=>[1024]}
%            }),Priv)),
%
%  #{<<"txid">>:=TxID5} = api_post_transaction(BadResp),
%  {ok, Status5, _} = api_get_tx_status(TxID5),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, Status5),
%
%  #{etxs:=[{DJTxID,_}|_]}=Block3=tpapi:get_fullblock(Blkid3,get_base_url()),
%
%  io:format("Block3 ~p~n",[Block3]),
%  io:format("Have to wait for DJ tx ~p~n",[DJTxID]),
%  ?assertMatch(#{etxs:=[{<<"8001400004",_/binary>>,#{not_before:=_}}]},Block3),
%
%  {ok, StatusDJ, _} = api_get_tx_status(DJTxID, 65),
%  io:format("DJ tx status ~p~n",[StatusDJ]),
%  ?assertMatch(#{<<"res">> := <<"ok">>}, StatusDJ),
%  ok.

check_blocks_test(_Config) ->
  lists:map(
    fun(Node) ->
        RF=rpc:call(get_node(list_to_binary(Node)), erlang, whereis, [blockchain_reader]),
        R=test_blocks_verify(RF, last,0),
        io:format("Node ~p block verify ok, verified blocks ~p~n",[RF,R])
    end, ?TESTNET_NODES),
  ok.

test_blocks_verify(_, <<0,0,0,0,0,0,0,0>>, C) ->
  C;

test_blocks_verify(Reader, Pos, C) ->
 Blk=gen_server:call(Reader,{get_block,Pos}),
 if(is_map(Blk)) ->
     ok;
   true ->
     throw({noblock,Pos})
 end,
 {true,_}=block:verify(Blk),
 case block:verify(block:unpack(block:pack(Blk))) of
   false ->
     io:format("bad block ~p (depth ~w)~n",[Pos,C]),
     throw('BB');
   {true,_} -> 
     case Blk of
       #{header:=#{parent:=PBlk}} ->
         test_blocks_verify(Reader, PBlk, C+1);
       _ ->
         C+1
     end
 end.

crashme_test(_Config) ->
  ?assertMatch(crashme,ok).

transaction_test(_Config) ->
    % register new wallets
    Wallet = new_wallet(),
    Wallet2 = new_wallet(),
    logger("wallet: ~p, wallet2: ~p ~n", [Wallet, Wallet2]),
    %%%%%%%%%%%%%%%% make Wallet endless %%%%%%%%%%%%%%
    Cur = <<"FTT">>,
    EndlessAddress = naddress:decode(Wallet),
    TxpoolPidC4N1 =
      rpc:call(get_node(get_default_nodename()), erlang, whereis, [txpool]),
    C4N1NodePrivKey =
      rpc:call(get_node(get_default_nodename()), nodekey, get_priv, []),
  
    PatchTx = tx:sign(
                tx:construct_tx(
                  #{kind=>patch,
                    ver=>2,
                    patches=>
                    [#{<<"t">>=><<"set">>,
                       <<"p">>=>[<<"current">>, <<"endless">>, EndlessAddress, Cur],
                       <<"v">>=>true},
                     #{<<"t">>=><<"set">>,
                       <<"p">>=>[<<"current">>, <<"endless">>, EndlessAddress, <<"SK">>],
                       <<"v">>=>true}]
                   }
                 ), C4N1NodePrivKey),
  
    {ok, PatchTxId} = gen_server:call(TxpoolPidC4N1, {new_tx, PatchTx}),
    logger("PatchTxId: ~p~n", [PatchTxId]),
    {ok, _} = wait_for_tx(PatchTxId, get_node(get_default_nodename())),
    ChainSettngs = rpc:call(get_node(get_default_nodename()), chainsettings, all, []),
    logger("ChainSettngs: ~p~n", [ChainSettngs]),
    Amount = max(1000, rand:uniform(100000)),

    LTxId = make_lstore_transaction(Wallet),
    logger("lstore txid: ~p ~n", [LTxId]),
    {ok, LStatus, _} = api_get_tx_status(LTxId),
    ?assertMatch(#{<<"res">> := <<"ok">>}, LStatus),
    logger("lstore transaction status: ~p ~n", [LStatus]),

    % send money from endless to Wallet2
    Message = <<"preved from common test">>,
    TxId3 = make_transaction(Wallet, Wallet2, Cur, Amount, Message),
    {ok, Status3, _} = api_get_tx_status(TxId3),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status3),
    logger("transaction status3: ~p ~n", [Status3]),
    Wallet2Data = api_get_wallet(Wallet2),
    logger("destination wallet [step 3]: ~p ~n", [Wallet2Data]),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := Amount}}}, Wallet2Data),

    % make transactions from Wallet2 where we haven't SK
    Message4 = <<"without sk">>,
    TxId4 = make_transaction(Wallet2, Wallet, Cur, 1, Message4),
    logger("TxId4: ~p", [TxId4]),
    {ok, Status4, _} = api_get_tx_status(TxId4),
    logger("Status4: ~p", [Status4]),
    ?assertMatch(#{<<"res">> := <<"no_sk">>}, Status4),
    Wallet2Data4 = api_get_wallet(Wallet2),
    logger("wallet [step 4, without SK]: ~p ~n", [Wallet2Data4]),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := Amount}}}, Wallet2Data4),

    % send SK from endless to Wallet2
    Message5 = <<"sk">>,
    TxId5 = make_transaction(Wallet, Wallet2, <<"SK">>, 1, Message5),
    logger("TxId5: ~p", [TxId5]),
    {ok, Status5, _} = api_get_tx_status(TxId5),
    logger("Status5: ~p", [Status5]),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status5),
    Wallet2Data5 = api_get_wallet(Wallet2),
    logger("wallet [step 5, received 2 SK]: ~p ~n", [Wallet2Data5]),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{<<"SK">> := 1}}}, Wallet2Data5),

    % transaction from Wallet2 should be successful, because Wallet2 got 1 SK
    Message6 = <<"send money back">>,
    TxId6 = make_transaction(Wallet2, Wallet, Cur, 1, Message6),
    logger("TxId6: ~p", [TxId6]),
    {ok, Status6, _} = api_get_tx_status(TxId6),
    logger("Status6: ~p", [Status6]),
    Wallet2Data6 = api_get_wallet(Wallet2),
    logger("wallet [step 6, sk present]: ~p ~n", [Wallet2Data6]),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status6),
    NewAmount6 = Amount - 1,
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := NewAmount6}}}, Wallet2Data6),

    % second transaction from Wallet2 should be failed, because Wallet2 spent all SK for today
    Message7 = <<"sk test">>,
    TxId7 = make_transaction(Wallet2, Wallet, Cur, 1, Message7),
    logger("TxId7: ~p", [TxId7]),
    {ok, Status7, _} = api_get_tx_status(TxId7),
    logger("Status7: ~p", [Status7]),
    Wallet2Data7 = api_get_wallet(Wallet2),
    logger("wallet [step 7, all sk are used today]: ~p ~n", [Wallet2Data7]),
    ?assertMatch(#{<<"res">> := <<"sk_limit">>}, Status7),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := NewAmount6}}}, Wallet2Data7),

    LSData = api_get_wallet(Wallet),
    logger("wallet [lstore]: ~p ~n", [LSData]),

    application:set_env(tptest,endless_addr,EndlessAddress),
    application:set_env(tptest,endless_addr_pk,get_wallet_priv_key()),

    dump_testnet_state().

make_lstore_transaction(From) ->
  Node = get_node(get_default_nodename()),
  Seq = get_sequence(Node, From),
  logger("seq for wallet ~p is ~p ~n", [From, Seq]),
  Tx = tx:construct_tx(
         #{
         kind => lstore,
         payload => [ ],
         patches => [
                     #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"b">>], <<"v">>=>$b},
                     #{<<"t">>=><<"set">>, <<"p">>=>[<<"a">>,<<"c">>], <<"v">>=>$c}
                    ],
         ver => 2,
         t => os:system_time(millisecond),
         seq=> Seq + 1,
         from => naddress:decode(From)
        }
  ),
  SignedTx = tx:sign(Tx, get_wallet_priv_key()),
  Res = api_post_transaction(tx:pack(SignedTx)),
  maps:get(<<"txid">>, Res, unknown).

tpiccall(TPIC, Handler, Object, Atoms) ->
    Res=tpic:call(TPIC, Handler, msgpack:pack(Object)),
    lists:filtermap(
      fun({Peer, Bin}) ->
              case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
                  {ok, Decode} ->
                      {true, {Peer, Decode}};
                  _ -> false
              end
      end, Res).

%instant_sync_test(_Config) ->
%  %instant synchronization
%  rdb_dispatcher:start_link(),
%  TPIC=rpc:call(get_node(get_default_nodename()),erlang,whereis,[tpic]),
%  Cs=tpiccall(TPIC, <<"blockchain">>,
%              #{null=><<"sync_request">>},
%              [last_hash, last_height, chain]
%             ),
%  [{Handler, Candidate}|_]=lists:filter( %first suitable will be the quickest
%                             fun({_Handler, #{chain:=_Ch,
%                                              last_hash:=_,
%                                              last_height:=_,
%                                              null:=<<"sync_available">>}}) -> true;
%                                (_) -> false
%                             end, Cs),
%  #{null:=Avail,
%    chain:=Chain,
%    last_hash:=Hash,
%    last_height:=Height}=Candidate,
%  logger("~s chain ~w h= ~w hash= ~s ~n",
%            [ Avail, Chain, Height, bin2hex:dbin2hex(Hash) ]),
%
%  Name=test_sync_ledger,
%  {ok, Pid}=ledger:start_link(
%              [{filename, "db/ledger_test_syncx2"},
%               {name, Name}
%              ]
%             ),
%  gen_server:call(Pid, '_flush'),
%  
%  Hash2=rpc:call(get_node(get_default_nodename()),ledger,check,[[]]),
%  Hash2=rpc:call(get_node(get_default_nodename()),ledger,check,[[]]),
%
%  ledger_sync:run_target(TPIC, Handler, Pid, undefined),
%
%  {ok, #{blk:=BinBlk}}=inst_sync_wait_more(#{}),
%  Hash0=case block:unpack(BinBlk) of
%          #{header:=#{ledger_hash:=V1LH}} -> V1LH;
%          #{header:=#{roots:=Roots}} -> proplists:get_value(ledger_hash,Roots)
%        end,
%  Hash1=ledger:check(Pid,[]),
%  logger("Hash ~p ~p~n",[Hash1,Hash2]),
%  ?assertMatch({ok,_},Hash1),
%  ?assertMatch({ok,_},Hash2),
%  ?assertEqual(Hash1,{ok,Hash0}),
%  ?assertEqual(Hash1,Hash2),
%  gen_server:cast(Pid, terminate),
%  done.
%  
%
%inst_sync_wait_more(A) ->
%  receive
%    {inst_sync, block, Blk} ->
%      logger("Block~n"),
%      inst_sync_wait_more(A#{blk=>Blk});
%    {inst_sync, settings} ->
%      logger("settings~n"),
%      inst_sync_wait_more(A);
%    {inst_sync, ledger} ->
%      logger("Ledger~n"),
%      inst_sync_wait_more(A);
%    {inst_sync, settings, _} ->
%      logger("Settings~n"),
%      inst_sync_wait_more(A);
%    {inst_sync, done, Res} ->
%      logger("Done ~p~n", [Res]),
%      {ok,A};
%    Any ->
%      logger("error: ~p~n", [Any]),
%      {error, Any}
%  after 10000 ->
%          timeout
%  end.


% -----------------------------------------------------------------------------

logger(Format) when is_list(Format) ->
  logger(Format, []).
  
logger(Format, Args) when is_list(Format), is_list(Args) ->
  utils:logger(Format, Args).

% -----------------------------------------------------------------------------

