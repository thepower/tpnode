-module(chain1_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


all() ->
    [
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
get_node(Name) when is_atom(Name) ->
    get_node(atom_to_list(Name));

get_node(Name) when is_list(Name) ->
    get_node(list_to_binary(Name));

get_node(Name) when is_binary(Name) ->
    [_,NodeHost]=binary:split(atom_to_binary(erlang:node(),utf8),<<"@">>),
    binary_to_atom(<<Name/binary, "@", NodeHost/binary>>, utf8).

% ------------------------------------------------------------------

% base url for chain1 rpc
get_base_url() ->
    "http://wallet.thepower.io/api/chain/1".

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
    logger("seq for wallet ~p is ~p ~n", [From, Seq]),
    Tx = tx:construct_tx(
        #{
            kind => generic,
            ver => 2,
            t => os:system_time(millisecond),
            seq=> Seq + 1,
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

transaction_ping_pong_test(_Config) ->
    Wallet = <<"AA100000001677894510">>,  % endless here
    Wallet2 = <<"AA100000001677894616">>,
    Cur = <<"TEST">>,
    Amount = 10,

    % get height
    Height = api_get_height(),

    % get balance of destination wallet
    #{<<"info">> := #{<<"amount">> := AmountWallet2}} = api_get_wallet(Wallet2),
    AmountPrev = maps:get(Cur, AmountWallet2, 0),
    logger("destination wallet ammount: ~p ~n ~p ~n", [AmountPrev, AmountWallet2]),

    % send money from endless to Wallet2
    Message = <<"ping">>,
    TxId = make_transaction(Wallet, Wallet2, Cur, Amount, Message),
    logger("txid: ~p ~n", [TxId]),
    {ok, Status, _} = api_get_tx_status(TxId),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status),
    logger("money send transaction status: ~p ~n", [Status]),

    timer:sleep(5000), % wait 5 sec for wallet data update across all network
    Height2 = api_get_height(),
    ?assertMatch(true, Height2>Height),

    Wallet2Data = api_get_wallet(Wallet2),
    logger("destination wallet after money sent: ~p ~n", [Wallet2Data]),
    NewAmount = AmountPrev + Amount,
    logger("expected new amount: ~p ~n", [NewAmount]),
    ?assertMatch(
        #{<<"info">> := #{<<"amount">> := #{Cur := NewAmount}}},
        Wallet2Data
    ),

    
    % send money back
    Message2 = <<"pong">>,
    TxId2 = make_transaction(Wallet2, Wallet, Cur, Amount, Message2),
    {ok, Status2, _} = api_get_tx_status(TxId2),
    ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
    logger("money send back transaction status: ~p ~n", [Status2]),

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

% -----------------------------------------------------------------------------
