-module(txstorage_tests).

-include_lib("eunit/include/eunit.hrl").

-export([handle_info/2]).

% catch timers
handle_info(timer_expire, State) ->
  {noreply, cancel_timers(State) }.

cancel_timers(State) ->
  Timers = [timer_expire],
  
  maps:map(
    fun(Key, Value) ->
      case lists:member(Key, Timers) of
        true when is_reference(Value) ->
          catch erlang:cancel_timer(Value),
          unknown;
        _ ->
          Value
      end
    end,
    State
  ).
  
put_state(State) ->
  erlang:put(txstorage_tests_state, State).

get_state() ->
  erlang:get(txstorage_tests_state).


get_table_name() ->
  ?MODULE.

init_state() ->
  EtsTableName = get_table_name(),
  catch ets:delete(EtsTableName),
  {ok, State} = txstorage:init(#{ets_name => EtsTableName}),
  put_state(cancel_timers(State)).


store_and_get_test() ->
  init_state(),
  State = get_state(),
  TxId = <<"tx_id">>,
  Tx = <<"tx_body">>,
  Nodes = [<<"node1 pub key">>, <<"node2 pub key">>],
  EtsTable = get_table_name(),

  % direct get error
  Get1 = txstorage:get_tx(TxId, EtsTable),
  ?assertEqual(error, Get1),
  
  % call get error
  {reply, Get2, State1} = txstorage:handle_call({get, TxId}, self(), State),
  ?assertEqual(error, Get2),
  
  % store
  {noreply, State2} = txstorage:handle_info({store, TxId, Tx, Nodes}, State1),
  
  % direct get success
  Get3 = txstorage:get_tx(TxId, EtsTable),
  ?assertEqual({ok, {TxId, Tx, Nodes}}, Get3),

  % call get success
  {reply, Get4, _State3} = txstorage:handle_call({get, TxId}, self(), State2),
  ?assertEqual({ok, {TxId, Tx, Nodes}}, Get4).
  

%%debug_ets_table() ->
%%  Table = get_table_name(),
%%  io:format("~ntable name: ~p~n", [Table]),
%%  io:format(
%%    "ets table content: ~p~n",
%%    [ets:match_object(Table, {'$0', '$1', '$2', '$3'})]
%%  ).


expiration_test() ->
  init_state(),
  State = get_state(),
  TxId = <<"tx_id">>,
  Tx = <<"tx_body">>,
  Nodes = [],
  EtsTable = get_table_name(),
  Ttl = -1,
  
  % store
  txstorage:store_tx({TxId, Tx, Nodes}, EtsTable, Ttl),
  
  % get success
  Get1 = txstorage:get_tx(TxId, EtsTable),
  ?assertEqual({ok, {TxId, Tx, Nodes}}, Get1),
  
  % expire
  {noreply, State1} = txstorage:handle_info(timer_expire, State),
  cancel_timers(State1),
  
  % get error
  Get2 = txstorage:get_tx(TxId, EtsTable),
  ?assertEqual(error, Get2).

