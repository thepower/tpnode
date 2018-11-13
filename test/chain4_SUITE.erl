-module(chain4_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


all() ->
    [
%%      wallets_check_test
        transaction_ping_pong_test
    ].

init_per_suite(Config) ->
    application:ensure_all_started(inets),
    Config.

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

end_per_suite(Config) ->
    Config.

% ------------------------------------------------------------------
get_node(Name) ->
    NameBin = utils:make_binary(Name),
    [_,NodeHost]=binary:split(atom_to_binary(erlang:node(),utf8),<<"@">>),
    binary_to_atom(<<NameBin/binary, "@", NodeHost/binary>>, utf8).

% ------------------------------------------------------------------

% base url for chain4 rpc
get_base_url() ->
    DefaultUrl = "http://pwr.local:49841",
    os:getenv("API_BASE_URL", DefaultUrl).

% ------------------------------------------------------------------

api_get_tx_status(TxId) ->
    tpapi:get_tx_status(TxId, get_base_url()).

% get info for wallet
api_get_wallet(Wallet) ->
    tpapi:get_wallet_info(Wallet, get_base_url()).

% post encoded and signed transaction using API
api_post_transaction(Transaction) ->
    tpapi:commit_transaction(Transaction, get_base_url()).

% get current wallet seq
api_get_wallet_seq(Wallet) ->
    tpapi:get_wallet_seq(Wallet, get_base_url()).

% get network height
api_get_height() ->
    tpapi:get_height(get_base_url()).

% --------------------------------------------------------------------------------

get_wallet_priv_key() ->
    address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>).

% --------------------------------------------------------------------------------

make_transaction(From, To, Currency, Amount, Message) ->
    Seq = api_get_wallet_seq(From),
    TxSeq = max(Seq, os:system_time(millisecond)),
    logger("seq for wallet ~p is ~p, use ~p for transaction ~n", [From, Seq, TxSeq]),
    Tx = tx:construct_tx(
        #{
            kind => generic,
            ver => 2,
            t => os:system_time(millisecond),
            seq=> TxSeq,
            from => naddress:decode(From),
            to => naddress:decode(To),
            txext => #{
                <<"message">> => Message
            },
            payload => [
                #{amount => Amount,cur => Currency, purpose => transfer}
            ]
        }
    ),
    SignedTx = tx:sign(Tx, get_wallet_priv_key()),
    Res = api_post_transaction(tx:pack(SignedTx)),
    maps:get(<<"txid">>, Res, unknown).

% --------------------------------------------------------------------------------

get_all_nodes_keys(Wildcard) ->
  lists:filtermap(
    fun(Filename) ->
      try
        {ok, E} = file:consult(Filename),
        case proplists:get_value(privkey, E) of
          undefined -> false;
          Val -> {true, hex:decode(Val)}
        end
      catch _:_ ->
        false
      end
    end,
    filelib:wildcard(Wildcard)
  ).

% --------------------------------------------------------------------------------

sign_patchv2(Patch) ->
  sign_patchv2(Patch, "c4*.config").

sign_patchv2(Patch, Wildcard) ->
  PrivKeys = lists:usort(get_all_nodes_keys(Wildcard)),
  lists:foldl(
    fun(Key, Acc) ->
      tx:sign(Acc, Key)
    end, Patch, PrivKeys).

% --------------------------------------------------------------------------------

ensure_wallet_exist(Address) ->
  ensure_wallet_exist(Address, false).

ensure_wallet_exist(Address, EndlessCur) ->
  % check existing
  WalletData =
    try
      tpapi:get_wallet_info(Address, get_base_url())
    catch
      Ec:Ee ->
        utils:print_error("error getting wallet data", Ec, Ee, erlang:get_stacktrace()),
        logger("Wallet not exists: ~p", [Address]),
        undefined
    end,
  
  % register new wallet in case of error
  case WalletData of
    undefined ->
      WalletAddress = api_register_wallet(),
      ?assertEqual(Address, WalletAddress),
      
      % TODO: then we have added endless checking, remove this code
      case EndlessCur of
        false ->
          ok;
        CurName ->
          % make that wallet endless
          make_endless(Address, CurName)
      end;
    _ ->
      ok
  end,

  
%%  case EndlessCur of
%%    false ->
%%      ok;
%%    CurName ->

% TODO: check endless here, uncomment this code

%%      % make that wallet endless
%%      make_endless(Address, CurName)
%%  end;
  
  
  ok.



check_chain_settings(Endless, Wallet2, Cur) ->
  logger("wallets: ~p, ~p", [Endless, Wallet2]),
  logger("cur: ~p", [Cur]),
  
  % check wallets existing
  ensure_wallet_exist(Endless, Cur),
  ensure_wallet_exist(Wallet2),
  
  ok.


% --------------------------------------------------------------------------------

get_register_wallet_transaction() ->
  PrivKey = get_wallet_priv_key(),
  tpapi:get_register_wallet_transaction(PrivKey, #{promo => <<"TEST5">>}).

% --------------------------------------------------------------------------------

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

% --------------------------------------------------------------------------------

make_endless(Address, Cur) ->
  Patch =
    sign_patchv2(
      tx:construct_tx(
        #{kind=>patch,
          ver=>2,
          patches=>
          [
            #{
              <<"t">> => <<"set">>,
              <<"p">> => [
                <<"current">>,
                <<"endless">>, Address, Cur],
              <<"v">> => true}
          ]
        }
      ),
      "../examples/test_chain4/c4n?.config"),
  logger("PK ~p~n", [tx:verify(Patch)]),
  Patch.

% --------------------------------------------------------------------------------

wallets_check_test(_Config) ->
  Wallet = <<"AA100000006710886518">>,  % endless here
  Wallet2 = <<"AA100000006710886608">>,
  Cur = <<"SK">>,
  
  check_chain_settings(Wallet, Wallet2, Cur),
  ok.


mass_transaction_sender(From, To, Cur, Message, Count) ->
  Sender =
    fun(Amount) ->
      TxId = make_transaction(From, To, Cur, Amount, Message),
      logger("tx ~p -> ~p [~p]: ~p ~n", [From, To, Amount, TxId]),
      TxId
    end,
  [
    Sender(Amount) || Amount <- lists:seq(1, Count)
  ].
  
  

transaction_ping_pong_test(_Config) ->
    Wallet = <<"AA100000006710886518">>,  % endless here
    Wallet2 = <<"AA100000006710886608">>,
    Cur = <<"SK">>,
    TransactionCount = 10,
%%    Amount = 10,
  
    check_chain_settings(Wallet, Wallet2, Cur),
  
    % get height
    Height = api_get_height(),

    % get balance of destination wallet
    #{<<"info">> := #{<<"amount">> := AmountWallet2}} = api_get_wallet(Wallet2),
    AmountPrev = maps:get(Cur, AmountWallet2, 0),
    logger("destination wallet ammount: ~p ~n ~p ~n", [AmountPrev, AmountWallet2]),

    % send money from endless to Wallet2
    Message = <<"ping">>,
    TxIds = mass_transaction_sender(Wallet, Wallet2, Cur, Message, TransactionCount),
    StatusChecker =
      fun(TxId) ->
        logger("check status of transaction ~p ~n", [TxId]),
        {ok, Status, _} = api_get_tx_status(TxId),
        logger("got status [~p]: ~p ~n", [TxId, Status]),
        ?assertMatch(#{<<"res">> := <<"ok">>}, Status)
      end,
%%    TxId = make_transaction(Wallet, Wallet2, Cur, Amount, Message),
%%    logger("txid: ~p ~n", [TxId]),
%%    {ok, Status, _} = api_get_tx_status(TxId),
%%    ?assertMatch(#{<<"res">> := <<"ok">>}, Status),
%%    logger("money send transaction status: ~p ~n", [Status]),
    [ StatusChecker(CurTxId) || CurTxId <- TxIds ],

    timer:sleep(5000), % wait 5 sec for wallet data update across all network
    Height2 = api_get_height(),
    ?assertMatch(true, Height2>Height),

    Wallet2Data = api_get_wallet(Wallet2),
    logger("destination wallet after money sent: ~p ~n", [Wallet2Data]),
    NewAmount = AmountPrev + lists:sum(lists:seq(1, TransactionCount)),
    logger("expected new amount: ~p ~n", [NewAmount]),
    ?assertMatch(
        #{<<"info">> := #{<<"amount">> := #{Cur := NewAmount}}},
        Wallet2Data
    ),

    
    % send money back
    Message2 = <<"pong">>,
    logger("send money back"),
    TxIds2 = mass_transaction_sender(Wallet2, Wallet, Cur, Message2, TransactionCount),
    [ StatusChecker(CurTxId2) || CurTxId2 <- TxIds2 ],

%%    TxId2 = make_transaction(Wallet2, Wallet, Cur, Amount, Message2),
%%    {ok, Status2, _} = api_get_tx_status(TxId2),
%%    ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
%%    logger("money send back transaction status: ~p ~n", [Status2]),

    timer:sleep(5000), % wait 5 sec for wallet data update across all network
    Height3 = api_get_height(),
    ?assertMatch(true, Height3>Height2),

    Wallet2Data2 = api_get_wallet(Wallet2),
    logger("destination wallet after money sent back: ~p ~n", [Wallet2Data2]),
    ?assertMatch(
        #{<<"info">> := #{<<"amount">> := #{Cur := AmountPrev}}},
        Wallet2Data2
    ).


% -----------------------------------------------------------------------------

logger(Format) when is_list(Format) ->
  logger(Format, []).

logger(Format, Args) when is_list(Format), is_list(Args) ->
  utils:logger(Format, Args).
