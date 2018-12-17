-module(chain4_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% <<128,1,64,0,4,0,0,1>>
-define(FROM_WALLET, <<"AA100000006710886518">>).

%% <<128,1,64,0,4,0,0,2>>
-define(TO_WALLET, <<"AA100000006710886608">>).

% each transaction fee
-define(TX_FEE, 0).

% transaction count
% we'll send TX_COUNT*2 + 1 transactions: fee + TX_COUNT*ping + TX_COUNT*pong
-define(TX_COUNT, 2000).

% transaction waiting timeout, seconds
-define(TX_WAIT_TIMEOUT_SEC, 60).


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

% base url for chain rpc
get_base_url() ->
    DefaultUrl = "http://pwr.local:49741",
    os:getenv("API_BASE_URL", DefaultUrl).

% ------------------------------------------------------------------

api_get_tx_status(TxId) ->
    tpapi:get_tx_status(TxId, get_base_url()).

% ------------------------------------------------------------------

api_get_tx_status(TxId, TimeoutSec) ->
  tpapi:get_tx_status(TxId, get_base_url(), TimeoutSec).

% ------------------------------------------------------------------

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


make_transaction(From, To, Currency, Amount, _Fee, Message) ->
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
                #{amount => Amount, cur => Currency, purpose => transfer}
%%                #{amount => Fee, cur => <<"SK">>, purpose => srcfee}
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
      logger("register new wallet, base_url = ~p", [get_base_url()]),
      WalletAddress = api_register_wallet(),
      ?assertEqual(Address, WalletAddress),
      
      % TODO: when we'll have added endless checking, remove this code
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



check_chain_settings(_Endless, _Wallet2, _Cur) ->
  logger("wallets: ~p, ~p", [_Endless, _Wallet2]),
  logger("cur: ~p", [_Cur]),
  
  % check wallets existing
  ensure_wallet_exist(?FROM_WALLET),
  ensure_wallet_exist(?TO_WALLET),
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
      "./examples/test_chain4/c4n?.conf"),
  logger("PK ~p~n", [tx:verify(Patch)]),
  Patch.

% --------------------------------------------------------------------------------

wallets_check_test(_Config) ->
  Wallet = ?FROM_WALLET,  % endless here
  Wallet2 = ?TO_WALLET,
  Cur = <<"SK">>,
  
  check_chain_settings(Wallet, Wallet2, Cur),
  ok.


mass_transaction_sender(From, To, Cur, Message, Count) ->
  Fee = ?TX_FEE,
  Sender =
    fun(Amount) ->
      TxId = make_transaction(From, To, Cur, Amount, Fee, Message),
      logger("tx ~p -> ~p [~p]: ~p ~n", [From, To, Amount, TxId]),
      TxId
    end,
  [
    Sender(Amount) || Amount <- lists:seq(1, Count)
  ].
  
  

transaction_ping_pong_test(_Config) ->
    Wallet = ?FROM_WALLET,  % endless here
    Wallet2 = ?TO_WALLET,
    Cur = <<"SK">>,
    TransactionCount = ?TX_COUNT,
  
    check_chain_settings(Wallet, Wallet2, Cur),
  
    % get height
    Height = api_get_height(),

    % get balances
    Wallet1Data = api_get_wallet(Wallet),
    Wallet2Data = api_get_wallet(Wallet2),
  
    logger("initial wallet state.~n"),
    logger("source (endless) wallet data: ~p~n", [Wallet1Data]),
    logger("destination wallet data: ~p~n", [Wallet2Data]),
  
    % get balance of destination wallet
    #{<<"info">> := #{<<"amount">> := AmountWallet2}} = Wallet2Data,
    AmountPrev = maps:get(Cur, AmountWallet2, 0),
    logger("destination wallet ammount: ~p ~n ~p ~n", [AmountPrev, AmountWallet2]),

  
    % first of all, send money for fee from endless to Wallet2
    FeeAmount = ?TX_FEE * TransactionCount,
    logger(
      "Send additional money which will be used as transaction fee on sent money back stage.~n" ++
      "Additional money for fee: ~p",
      [FeeAmount]
    ),
    
    TxId = make_transaction(Wallet, Wallet2, Cur, FeeAmount, ?TX_FEE, <<"for fee">>),
    logger("txid: ~p ~n", [TxId]),
    {ok, Status, _} = api_get_tx_status(TxId),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status),
  
    % send money from endless to Wallet2
    Message = <<"ping">>,
    
    TxIds = mass_transaction_sender(Wallet, Wallet2, Cur, Message, TransactionCount),
    StatusChecker =
      fun(TxId4Check) ->
        logger("check status of transaction ~p ~n", [TxId4Check]),
        TxStatus =
          case api_get_tx_status(TxId4Check) of
            {ok, StatusFromServer, _Tries} ->
              StatusFromServer;
            Other ->
              Other
          end,
        logger("got status [~p]: ~p ~n", [TxId4Check, TxStatus]),
        ?assertMatch(#{<<"ok">> := true, <<"res">> := <<"ok">>}, TxStatus)
      end,

    logger("Statuses of money send transactions (ping).~n"),
    [ StatusChecker(CurTxId) || CurTxId <- TxIds ],
  
    % check height
    timer:sleep(5000), % wait 5 sec for wallet data update across all network
    Height2 = api_get_height(),
    ?assertMatch(true, Height2>Height),
  
    % check amount of transfered tokens
    Wallet2Data1 = api_get_wallet(Wallet2),
    logger("destination wallet after money sent: ~p ~n", [Wallet2Data1]),
    TransferedMoney = lists:sum(lists:seq(1, TransactionCount)),
    logger("transfered money: ~p ~n", [TransferedMoney]),
    logger("fee amount: ~p ~n", [FeeAmount]),
  
    NewAmount = AmountPrev + TransferedMoney + FeeAmount,
    logger("expected new amount: ~p ~n", [NewAmount]),
    ?assertMatch(
        #{<<"info">> := #{<<"amount">> := #{Cur := NewAmount}}},
        Wallet2Data1
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
  
    logger("Statuses of money send transactions (pong).~n"),

    timer:sleep(5000), % wait 5 sec for wallet data update across all network
    Height3 = api_get_height(),
    ?assertMatch(true, Height3>Height2),

    Wallet2Data2 = api_get_wallet(Wallet2),
    logger("destination wallet after the money were sent back: ~p ~n", [Wallet2Data2]),
    logger("expected amount (prev dest wallet amount): ~p~n", [AmountPrev]),
  
    ?assertMatch(
        #{<<"info">> := #{<<"amount">> := #{Cur := AmountPrev}}},
        Wallet2Data2
    ).


% -----------------------------------------------------------------------------

logger(Format) when is_list(Format) ->
  logger(Format, []).

logger(Format, Args) when is_list(Format), is_list(Args) ->
  utils:logger(Format, Args).
