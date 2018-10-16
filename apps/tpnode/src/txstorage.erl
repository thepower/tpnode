-module(txstorage).

-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-export([store_tx/3, get_tx/2, get_tx/1]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init_table(EtsTableName) ->
  Table =
    ets:new(
      EtsTableName,
      [named_table, protected, set, {read_concurrency, true}]
    ),
  lager:info("Table created: ~p", [Table]).

init(Args) ->
  EtsTableName = maps:get(ets_name, Args, ?MODULE),
  init_table(EtsTableName),
  ExpireTickSec = maps:get(expire_check_sec, Args, 60*60),
  {ok, #{
    expire_tick_ms => ExpireTickSec * 1000,
    timer_expire => erlang:send_after(10*1000, self(), timer_expire),
    ets_name => EtsTableName,
    ets_ttl_sec => 60*60
  }}.

handle_call(get_table_name, _From, #{ets_name:=EtsName} = State) ->
  {reply, EtsName, State};

handle_call({get, TxId}, _From, #{ets_name:=EtsName} = State) ->
  lager:notice("Get tx ~p", [TxId]),
  {reply, get_tx(TxId, EtsName), State};

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast(
  {tpic, FromPubKey, Peer, PayloadBin},
  #{ets_ttl_sec:=Ttl, ets_name:=EtsName} = State) ->
  
  lager:info(
    "txstorage got txbatch from ~p payload ~p",
    [ FromPubKey, PayloadBin]
  ),
  try
%% Payload
%%    #{
%%      null => <<"mkblock">>,
%%      chain => MyChain,
%%      lbh => LBH,
%%      txbatch => BatchBin,
%%      batchid => BatchId
%%    }
    
    {BatchId, BatchBin} =
      case
        msgpack:unpack(
          PayloadBin,
          [
            {known_atoms, [txbatch, batchid] },
            {unpack_str, as_binary}
          ])
      of
        {ok, Payload} ->
          case Payload of
            #{
              null := <<"mkblock">>,
              txbatch := Bin,
              batchid := Id
             } ->
                {Id, Bin};
            _InvalidPayload ->
              lager:error(
                "txstorage got invalid transaction batch payload: ~p",
                [_InvalidPayload]
              ),
              throw(invalid_payload)
          end;
        _ ->
          lager:error("txstorage can't unpack msgpack: ~p", [ PayloadBin ])
      end,

    {BatchId, Txs} =
      case txsync:parse_batch(BatchBin) of
        {[], _} ->
          throw(empty_batch);
        {_, <<"">>} ->
          throw(empty_batch);
        Batch ->
          Batch
      end,
    ValidUntil = os:system_time(second) + Ttl,
    TxIds = store_tx_batch(Txs, FromPubKey, EtsName, ValidUntil),
    tpic:cast(tpic, Peer, BatchId),
    txqueue ! {push, TxIds}
    
  catch
    Ec:Ee ->
      utils:print_error(
        "can't place transaction into storage",
        Ec, Ee, erlang:get_stacktrace()
      )
  end,
  {noreply, State};

handle_cast({store, Txs, Nodes}, State) ->
  handle_cast({store, Txs, Nodes, #{}}, State);

handle_cast({store, Txs, Nodes, Options}, #{ets_ttl_sec:=Ttl, ets_name:=EtsName} = State) ->
  lager:info("Store txs ~p", [ Txs ]),
  try
    ValidUntil = os:system_time(second) + Ttl,
    TxIds = store_tx_batch(Txs, Nodes, EtsName, ValidUntil),
    ParseOptions =
      fun
        (#{push_queue := _}) when length(TxIds) > 0 ->
          gen_server:cast(txqueue, {push, TxIds});
        (#{push_head_queue := _}) when length(TxIds) > 0 ->
          gen_server:cast(txqueue, {push_head, TxIds});
        (_) ->
          ok
      end,
    ParseOptions(Options)

  catch
    Ec:Ee ->
      utils:print_error(
        "can't place transaction into storage",
        Ec, Ee, erlang:get_stacktrace()
      )
  end,
  {noreply, State};

handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(timer_expire,
  #{ets_name:=EtsName, timer_expire:=Tmr, expire_tick_ms:=Delay} = State) ->
  
  catch erlang:cancel_timer(Tmr),
  lager:info("remove expired records"),
  Now = os:system_time(second),
  ets:select_delete(
    EtsName,
    [{{'_', '_', '_', '$1'}, [{'<', '$1', Now}], [true]}]
  ),
  {noreply,
    State#{
      timer_expire => erlang:send_after(Delay, self(), timer_expire)
    }
  };


%%handle_info({store, TxId, Tx, Nodes}, #{ets_ttl_sec:=Ttl, ets_name:=EtsName} = State) ->
%%  lager:info("store tx ~p", [TxId]),
%%  try
%%    store_tx({TxId, Tx, Nodes}, EtsName, Ttl)
%%  catch
%%    Ec:Ee ->
%%      utils:print_error(
%%        "can't place transaction into storage",
%%        Ec, Ee, erlang:get_stacktrace()
%%      )
%%  end,
%%  {noreply, State};


handle_info(_Info, State) ->
  lager:notice("Unknown info  ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

store_tx({TxId, Tx, Nodes}, Table, ValidUntil) ->
%%  lager:info("store tx ~p to ets", [TxId]),
%%  TODO: vaildate transaction before store it
  ets:insert(Table, {TxId, Tx, Nodes, ValidUntil}),
  TxId;

store_tx(Invalid, _Table, _ValidUntil) ->
  lager:error("can't store invalid transaction: ~p", [Invalid]),
  error.

%% ------------------------------------------------------------------

store_tx_batch(Txs, FromPubKey, Table, ValidUntil) ->
  store_tx_batch(Txs, FromPubKey, Table, ValidUntil, []).

store_tx_batch([], _FromPubKey, _Table, _ValidUntil, StoredIds) ->
  StoredIds;

store_tx_batch([{TxId, Tx}|Rest], Nodes, Table, ValidUntil, StoredIds)
  when is_list(Nodes) ->
    NewStoredIds = StoredIds ++ store_tx({TxId, Tx, Nodes}, Table, ValidUntil),
    store_tx_batch(Rest, Nodes, Table, ValidUntil, NewStoredIds);

store_tx_batch([{TxId, Tx}|Rest], FromPubKey, Table, ValidUntil, StoredIds)
  when is_binary(FromPubKey) ->
    NewStoredIds = StoredIds ++ store_tx({TxId, Tx, [FromPubKey]}, Table, ValidUntil),
    store_tx_batch(Rest, FromPubKey, Table, ValidUntil, NewStoredIds).

%% ------------------------------------------------------------------

get_tx(TxId) ->
  get_tx(TxId, ?MODULE).

get_tx(TxId, Table) ->
  case ets:lookup(Table, TxId) of
    [{TxId, Tx, Nodes, _Timeout}] ->
      {ok, {TxId, Tx, Nodes}};
    [] ->
      error
  end.

