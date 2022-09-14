-module(txlog).
-include("include/tplog.hrl").

%% API
-export([log/2]).


%%init() ->
%%  init(txlog).
%%
%%init(EtsTableName) ->
%%  Table =
%%    ets:new(
%%      EtsTableName,
%%      [named_table, protected, set, {read_concurrency, true}]
%%    ),
%%  ?LOG_INFO("table ~p was created", [Table]).
%%


%%get_base_timestamp(Timestamp) ->
%%  case application:get_env(tpnode, base_tx_ts, undefined) of
%%    undefined ->
%%      NowDiff = os:system_time() - Timestamp,
%%      if
%%        NowDiff > 1000000000000 ->
%%          undefined;
%%        true ->
%%          application:set_env(tpnode, base_tx_ts, Timestamp),
%%          Timestamp
%%      end;
%%    BaseTS ->
%%      BaseTS
%%  end.

log([], _) ->
  ok;

log(TxIds, Options) when is_list(TxIds) ->
%%  TxTimes =
%%    lists:map(
%%      fun(TxId) ->
%%        {ok,_,[_,_,T1]} = txpool:decode_txid(TxId),
%%        T1
%%      end,
%%      TxIds),
%%  BaseTS = get_base_timestamp(lists:min(TxTimes)),
%%  TranslatedTxTimes =
%%    lists:map(
%%      fun(TxTS) ->
%%        case BaseTS of
%%          undefined ->
%%            0;
%%          _ ->
%%            TxTS - BaseTS
%%        end
%%      end,
%%      TxTimes
%%    ),

  stout:log(txlog, [{ts, TxIds}, {options, Options}]).
%%stout:log(txlog, [{ts, TranslatedTxTimes}, {options, Options}]).

