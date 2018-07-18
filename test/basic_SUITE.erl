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
    "test_c5n3"
]).

%%-define(TESTNET_NODES, [
%%    "test_c4n1",
%%    "test_c4n2",
%%    "test_c4n3"
%%]).


all() ->
    [
        transaction_test,
        register_wallet_test,
        discovery_got_announce_test,
        discovery_register_test,
        discovery_lookup_test,
        discovery_unregister_by_name_test,
        discovery_unregister_by_pid_test,
        instant_sync_test
    ].

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

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

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


save_bckups() ->
    io:format("saving bckups"),
    SaveBckupForNode =
        fun(Node) ->
            BckupDir = "/tmp/ledger_bckups/" ++ Node ++ "/",
%%        filelib:ensure_dir("../../../../" ++ BckupDir),
            filelib:ensure_dir(BckupDir),
            io:format("saving bckup for node ~p to dir ~p", [Node, BckupDir]),
            rpc:call(get_node(Node), blockchain, backup, [BckupDir])
        end,
    lists:foreach(SaveBckupForNode, ?TESTNET_NODES),
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
%%        end, [], ?TESTNET_NODES
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


cover_finish() ->
    io:format("going to flush coverage data~n"),
    io:format("nodes: ~p~n", [nodes()]),
    erlang:register(ctester, self()),
    ct_cover:remove_nodes(nodes()),
%%    cover:stop(nodes()),
%%    cover:stop(),
    cover:flush(nodes()),
    cover:analyse_to_file([{outdir,"cover1"}]).
%%    timer:sleep(1000).
%%    cover:analyse_to_file([{outdir,"cover"},html]).



get_node(Name) when is_atom(Name) ->
    get_node(atom_to_list(Name));

get_node(Name) when is_list(Name) ->
    get_node(list_to_binary(Name));

get_node(Name) when is_binary(Name) ->
    [_,NodeHost]=binary:split(atom_to_binary(erlang:node(),utf8),<<"@">>),
    binary_to_atom(<<Name/binary, "@", NodeHost/binary>>, utf8).


wait_for_testnet(Trys) ->
    NodesCount = length(?TESTNET_NODES),
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
        end, 0, ?TESTNET_NODES),

    if
        Trys<1 ->
            timeout;
        Alive =/= NodesCount ->
            io:fwrite("testnet hasn't started yet, alive ~p, need ~p", [Alive, NodesCount]),
            timer:sleep(1000),
            wait_for_testnet(Trys-1);
        true -> ok
    end.


discovery_register_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    Answer = gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    ?assertEqual(ok, Answer).


discovery_lookup_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    gen_server:call(DiscoveryPid, {register, <<"test_service">>, self()}),
    Result1 = gen_server:call(DiscoveryPid, {get_pid, <<"test_service">>}),
    ?assertMatch({ok, _, <<"test_service">>}, Result1),
    Result2 = gen_server:call(DiscoveryPid, {lookup, <<"nonexist">>}),
    ?assertEqual([], Result2),
    Result3 = gen_server:call(DiscoveryPid, {lookup, <<"tpicpeer">>}),
    ?assertNotEqual(0, length(Result3)).


discovery_unregister_by_name_test(_Config) ->
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
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
    DiscoveryPid = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
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


% build announce as c4n3
build_announce(Name) ->
    Now = os:system_time(second),
    Announce = #{
        name => Name,
        address => #{
            address => <<"127.0.0.1">>,
            hostname => "c4n3.pwr.local",
            port => 1234,
            proto => api
        },
        created => Now,
        ttl => 600,
        scopes => [api, xchain],
        nodeid => <<"28AFpshz4W4YD7tbLj1iu4ytpPzQ">>, % id from c4n3
        chain => 4
    },
    meck:new(nodekey),
    % priv key from c4n3 node
    meck:expect(nodekey, get_priv, fun() -> hex:parse("2ACC7ACDBFFA92C252ADC21D8469CC08013EBE74924AB9FEA8627AE512B0A1E0") end),
    AnnounceBin = discovery:pack(Announce),
    meck:unload(nodekey),
    {Announce, AnnounceBin}.


discovery_got_announce_test(_Config) ->
    DiscoveryC4N1 = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [discovery]),
    DiscoveryC4N2 = rpc:call(get_node(<<"test_c4n2">>), erlang, whereis, [discovery]),
    DiscoveryC4N3 = rpc:call(get_node(<<"test_c4n3">>), erlang, whereis, [discovery]),
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
    Result3 = gen_server:call(DiscoveryC4N3, {lookup, ServiceName, 4}),
    ?assertEqual([], Result3),
    % c5n2 should get info from xchain announce
    Result4 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 4}),
    ?assertEqual(Experted, Result4),
    Result5 = gen_server:call(DiscoveryC5N2, {lookup, ServiceName, 5}),
    ?assertEqual([], Result5).

api_get_tx_status(TxId) ->
    api_get_tx_status(TxId, get_base_url()).

api_get_tx_status(TxId, BaseUrl) ->
    Status = tpapi:get_tx_status(TxId, BaseUrl),
    case Status of
      {ok, timeout, _} ->
        dump_testnet_state();
      {ok, #{<<"res">> := <<"bad_seq">>}, _} ->
        dump_testnet_state();
      _ ->
        ok
    end,
    Status.


%% wait for transaction commit using distribution
wait_for_tx(TxId, NodeName) ->
    wait_for_tx(TxId, NodeName, 10).

wait_for_tx(_TxId, _NodeName, 0 = _TrysLeft) ->
    dump_testnet_state(),
    {timeout, _TrysLeft};

wait_for_tx(TxId, NodeName, TrysLeft) ->
    Status = rpc:call(NodeName, txstatus, get, [TxId]),
    io:format("got tx status: ~p ~n", [Status]),
    case Status of
        undefined ->
            timer:sleep(1000),
            wait_for_tx(TxId, NodeName, TrysLeft - 1);
        {true, ok} ->
            {ok, TrysLeft};
        {false, Error} ->
            dump_testnet_state(),
            {error, Error}
    end.


get_wallet_priv_key() ->
    address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>).

get_register_wallet_transaction() ->
    PrivKey = get_wallet_priv_key(),
    Promo = <<"TEST5">>,
    PubKey = tpecdsa:calc_pub(PrivKey, true),
    tpapi:get_register_wallet_transaction(PubKey, Promo).

register_wallet_test(_Config) ->
    RegisterTx = get_register_wallet_transaction(),
    Res = api_post_transaction(RegisterTx),
    ?assertEqual(<<"ok">>, maps:get(<<"result">>, Res, unknown)),
    TxId = maps:get(<<"txid">>, Res, unknown),
    ?assertNotEqual(unknown, TxId),
    io:format("got txid: ~p~n", [TxId]),
    ?assertMatch(#{<<"result">> := <<"ok">>}, Res),
    {ok, Status, _TrysLeft} = api_get_tx_status(TxId),
    io:format("transaction status: ~p ~n trys left: ~p", [Status, _TrysLeft]),
    ?assertNotEqual(timeout, Status),
    ?assertMatch(#{<<"ok">> := true}, Status),
    Wallet = maps:get(<<"res">>, Status, unknown),
    ?assertNotEqual(unknown, Wallet),
    % проверяем статус кошелька через API
    Res2 = api_get_wallet(Wallet),
    io:format("Info for wallet ~p: ~p", [Wallet, Res2]),
    ?assertMatch(#{<<"result">> := <<"ok">>, <<"txtaddress">> := Wallet}, Res2),
    WalletInfo = maps:get(<<"info">>, Res2, unknown),
    ?assertNotEqual(unknown, WalletInfo),
    PubKeyFromAPI = maps:get(<<"pubkey">>, WalletInfo, unknown),
    ?assertNotEqual(unknown, PubKeyFromAPI).

% base url for c4n1 rpc
get_base_url() ->
    "http://pwr.local:49841".

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
    % регистрируем кошелек
    RegisterTx = get_register_wallet_transaction(),
    Res = api_post_transaction(RegisterTx),
    ?assertEqual(<<"ok">>, maps:get(<<"result">>, Res, unknown)),
    TxId = maps:get(<<"txid">>, Res, unknown),
    ?assertMatch(#{<<"result">> := <<"ok">>}, Res),
    {ok, Status, _} = api_get_tx_status(TxId),
    io:format("register wallet transaction status: ~p ~n", [Status]),
    ?assertMatch(#{<<"ok">> := true}, Status),
    Wallet = maps:get(<<"res">>, Status, unknown),
    ?assertNotEqual(unknown, Wallet),
    io:format("new wallet has been registered: ~p ~n", [Wallet]),
    Wallet.


% get current sequence for wallet
get_sequence(Node, Wallet) ->
    Ledger = rpc:call(Node, ledger, get, [naddress:decode(Wallet)]),
    case bal:get(seq, Ledger) of
        Seq when is_integer(Seq) -> max(Seq, os:system_time(millisecond));
        _ -> 0
    end.


make_transaction(From, To, Currency, Amount, Message) ->
    Node = get_node(<<"test_c4n1">>),
    make_transaction(Node, From, To, Currency, Amount, Message).

make_transaction(Node, From, To, Currency, Amount, Message) ->
    Seq = get_sequence(Node, From),
    io:format("seq for wallet ~p is ~p ~n", [From, Seq]),
    Tx = #{
        amount => Amount,
        cur => Currency,
        extradata =>jsx:encode(#{message=>Message}),
        from => naddress:decode(From),
        to => naddress:decode(To),
        seq=> Seq + 1,
        timestamp => os:system_time(millisecond)
    },
    io:format("transaction body ~p ~n", [Tx]),
    SignedTx = tx:sign(Tx, get_wallet_priv_key()),
    Res4 = api_post_transaction(SignedTx),
    maps:get(<<"txid">>, Res4, unknown).

new_wallet() ->
    PubKey = tpecdsa:calc_pub(get_wallet_priv_key(), true),
    case tpapi:register_wallet(PubKey, get_base_url()) of
        {ok, Wallet, _TxId} ->
            Wallet;
        timeout ->
            io:format("wallet registration timeout~n"),
            dump_testnet_state(),
            throw(wallet_registration_timeout);
        Other ->
            io:format("wallet registration error: ~p ~n", [Other]),
            dump_testnet_state(),
            throw(wallet_registration_error)
    end.


dump_testnet_state() ->
    io:format("dump testnet state ~n"),
    StateDumper =
        fun(NodeName) ->
            io:format("last block for node ~p ~n", [NodeName]),
            LastBlock = rpc:call(get_node(NodeName), blockchain, last, []),
            io:format("~p ~n", [LastBlock])
        end,
    lists:foreach(StateDumper, ?TESTNET_NODES),
    ok.
    

transaction_test(_Config) ->
    % регистрируем кошелек
    Wallet = new_wallet(),
    Wallet2 = new_wallet(),
    io:format("wallet: ~p, wallet2: ~p ~n", [Wallet, Wallet2]),
    %%%%%%%%%%%%%%%% make endless for Wallet %%%%%%%%%%%%%%
    Cur = <<"FTT">>,
    EndlessAddress = naddress:decode(Wallet),
    TxpoolPidC4N1 = rpc:call(get_node(<<"test_c4n1">>), erlang, whereis, [txpool]),
    C4N1NodePrivKey = rpc:call(get_node(<<"test_c4n1">>), nodekey, get_priv, []),
    Patch = settings:sign(
        [#{<<"t">>=><<"set">>,
            <<"p">>=>[<<"current">>, <<"endless">>, EndlessAddress, Cur],
            <<"v">>=>true},
        #{<<"t">>=><<"set">>,
            <<"p">>=>[<<"current">>, <<"endless">>, EndlessAddress, <<"SK">>],
            <<"v">>=>true}],
        C4N1NodePrivKey),
    {ok, PatchTxId} = gen_server:call(TxpoolPidC4N1, {patch, Patch}),
    io:format("PatchTxId: ~p~n", [PatchTxId]),
    {ok, _} = wait_for_tx(PatchTxId, get_node(<<"test_c4n1">>)),
    ChainSettngs = rpc:call(get_node(<<"test_c4n1">>), blockchain, get_settings, []),
    io:format("ChainSettngs: ~p~n", [ChainSettngs]),
    Amount = max(1000, rand:uniform(100000)),

    % send money from endless to Wallet2
    Message = <<"preved from common test">>,
    TxId3 = make_transaction(Wallet, Wallet2, Cur, Amount, Message),
    {ok, Status3, _} = api_get_tx_status(TxId3),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status3),
    io:format("transaction status3: ~p ~n", [Status3]),
    Wallet2Data = api_get_wallet(Wallet2),
    io:format("destination wallet: ~p ~n", [Wallet2Data]),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := Amount}}}, Wallet2Data),

    % make transactions from Wallet2 where we haven't SK
    Message4 = <<"without sk">>,
    TxId4 = make_transaction(Wallet2, Wallet, Cur, 1, Message4),
    io:format("TxId4: ~p", [TxId4]),
    {ok, Status4, _} = api_get_tx_status(TxId4),
    io:format("Status4: ~p", [Status4]),
    ?assertMatch(#{<<"res">> := <<"no_sk">>}, Status4),
    Wallet2Data4 = api_get_wallet(Wallet2),
    io:format("wallet without SK: ~p ~n", [Wallet2Data4]),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := Amount}}}, Wallet2Data4),

    % send SK from endless to Wallet2
    Message5 = <<"sk">>,
    TxId5 = make_transaction(Wallet, Wallet2, <<"SK">>, 1, Message5),
    io:format("TxId5: ~p", [TxId5]),
    {ok, Status5, _} = api_get_tx_status(TxId5),
    io:format("Status5: ~p", [Status5]),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status5),
    Wallet2Data5 = api_get_wallet(Wallet2),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{<<"SK">> := 1}}}, Wallet2Data5),

    % transaction from Wallet2 should be successful, because Wallet2 got 1 SK
    Message6 = <<"send money back">>,
    TxId6 = make_transaction(Wallet2, Wallet, Cur, 1, Message6),
    io:format("TxId6: ~p", [TxId6]),
    {ok, Status6, _} = api_get_tx_status(TxId6),
    io:format("Status6: ~p", [Status6]),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status6),
    Wallet2Data6 = api_get_wallet(Wallet2),
    NewAmount6 = Amount - 1,
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := NewAmount6}}}, Wallet2Data6),

    % second transaction from Wallet2 should be failed, because Wallet2 spent all SK for today
    Message7 = <<"sk test">>,
    TxId7 = make_transaction(Wallet2, Wallet, Cur, 1, Message7),
    io:format("TxId7: ~p", [TxId7]),
    {ok, Status7, _} = api_get_tx_status(TxId7),
    io:format("Status7: ~p", [Status7]),
    ?assertMatch(#{<<"res">> := <<"sk_limit">>}, Status7),
    Wallet2Data7 = api_get_wallet(Wallet2),
    ?assertMatch(#{<<"info">> := #{<<"amount">> := #{Cur := NewAmount6}}}, Wallet2Data7).

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

instant_sync_test(_Config) ->
  %instant synchronization
  rdb_dispatcher:start_link(),
  TPIC=rpc:call(get_node(<<"test_c4n1">>),erlang,whereis,[tpic]),
  Cs=tpiccall(TPIC, <<"blockchain">>,
              #{null=><<"sync_request">>},
              [last_hash, last_height, chain]
             ),
  [{Handler, Candidate}|_]=lists:filter( %first suitable will be the quickest
                             fun({_Handler, #{chain:=_Ch,
                                              last_hash:=_,
                                              last_height:=_,
                                              null:=<<"sync_available">>}}) -> true;
                                (_) -> false
                             end, Cs),
  #{null:=Avail,
    chain:=Chain,
    last_hash:=Hash,
    last_height:=Height}=Candidate,
  io:format("~s chain ~w h= ~w hash= ~s ~n",
            [ Avail, Chain, Height, bin2hex:dbin2hex(Hash) ]),

  Name=test_sync_ledger,
  {ok, Pid}=ledger:start_link(
              [{filename, "db/ledger_test_syncx2"},
               {name, Name}
              ]
             ),
  gen_server:call(Pid, '_flush'),
  
  Hash2=rpc:call(get_node(<<"test_c4n1">>),ledger,check,[[]]),

  ledger_sync:run_target(TPIC, Handler, Pid, undefined),

  R=inst_sync_wait_more(),
  ?assertEqual(ok,R),
  Hash1=ledger:check(Pid,[]),
  io:format("Hash ~p ~p~n",[Hash1,Hash2]),
  ?assertMatch({ok,_},Hash1),
  ?assertMatch({ok,_},Hash2),
  ?assertEqual(Hash1,Hash2),
  gen_server:cast(Pid, terminate),
  done.
  

inst_sync_wait_more() ->
  receive
    {inst_sync, block, _} ->
      io:format("Block~n"),
      inst_sync_wait_more();
    {inst_sync, settings} ->
      io:format("settings~n"),
      inst_sync_wait_more();
    {inst_sync, ledger} ->
      io:format("Ledger~n"),
      inst_sync_wait_more();
    {inst_sync, settings, _} ->
      io:format("Settings~n"),
      inst_sync_wait_more();
    {inst_sync, done, Res} ->
      io:format("Done ~p~n", [Res]),
      ok;
    Any ->
      io:format("error: ~p~n", [Any]),
      {error, Any}
  after 10000 ->
          timeout
  end.

