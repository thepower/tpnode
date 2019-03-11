-module(txqueue).

-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(MAX_REASSEMBLY_TRIES, 30).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, get_lbh/1, get_state/0, get_max_reassembly_tries/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok,
    #{
      queue => queue:new(),
      inprocess => hashqueue:new(),
      batch_state => #{
        holding_storage => #{},
        current_batch => 0,
        try_count => 0
      }
    }
  }.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.


handle_cast(
  {push, BatchNo, TxIds}, #{queue:=Queue, batch_state := BatchState} = State)
  when is_list(TxIds) and is_number(BatchNo) ->
  
  #{holding_storage := Holding, current_batch := CurrentBatch} = BatchState,
  
  case BatchNo of
    CurrentBatch ->
      stout:log(txqueue_push, [ {ids, TxIds}, {batch, BatchNo}, {storage, queue} ]),
  
      txlog:log(TxIds, #{where => queue_push_current}),
      
      % trying reassemble the hold storage after the last batch was added
      #{queue := NewQueue} = NewBatchState =
        reassembly_batch(
          BatchState#{
            queue => lists:foldl( fun queue:in/2, Queue, TxIds),
            current_batch => BatchNo + 1,
            try_count => 0
          }),

      {noreply, State#{
        queue => NewQueue,
        batch_state => maps:without([queue], NewBatchState)
      }};
    
    _ when BatchNo < CurrentBatch -> % skip batch with number less than current
      stout:log(txqueue_push, [ {ids, TxIds}, {batch, BatchNo}, {storage, skip} ]),
      {noreply, State};
    
    _ ->
      stout:log(txqueue_push, [ {ids, TxIds}, {batch, BatchNo}, {storage, hold} ]),
      
      txlog:log(TxIds, #{where => queue_push_hold}),
      
      % trying reassemble the hold storage
      % (we can exceed number of tries, so should force reassemble the hold storage)
  
      #{queue := NewQueue2} = NewBatchState2 =
        reassembly_batch(
          BatchState#{
            queue => Queue,
            holding_storage => maps:put(BatchNo, TxIds, Holding)
          }
        ),
  
      {noreply, State#{
        queue => NewQueue2,
        batch_state => maps:without([queue], NewBatchState2)
      }}
  end;

handle_cast({push_head, TxIds}, #{queue:=Queue} = State) when is_list(TxIds) ->
%%  lager:debug("push head ~p", [TxIds]),
  stout:log(txqueue_pushhead, [ {ids, TxIds} ]),

  RevIds = lists:reverse(TxIds),
  
  txlog:log(RevIds, #{where => queue_push_head}),
  
  {noreply, State#{
    queue=>lists:foldl( fun queue:in_r/2, Queue, RevIds)
  }};

handle_cast({done, Txs}, #{inprocess:=InProc0} = State) ->
  stout:log(txqueue_done, [ {result, true}, {ids, Txs} ]),
  InProc1 =
    lists:foldl(
      fun
        ({Tx, _}, Acc) ->
          lager:info("TX queue ext tx done ~p", [Tx]),
          hashqueue:remove(Tx, Acc);
        (Tx, Acc) ->
          lager:debug("TX queue tx done ~p", [Tx]),
          hashqueue:remove(Tx, Acc)
      end,
      InProc0,
      Txs),
  gen_server:cast(txstatus, {done, true, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, true, Txs}),
  {noreply,
    State#{
      inprocess => InProc1
    }};

handle_cast({failed, Txs}, #{inprocess:=InProc0} = State) ->
  stout:log(txqueue_done, [ {result, failed}, {ids, Txs} ]),
  InProc1 = lists:foldl(
    fun
      ({_, {overdue, Parent}}, Acc) ->
        lager:info("TX queue inbound block overdue ~p", [Parent]),
        hashqueue:remove(Parent, Acc);
      ({TxID, Reason}, Acc) ->
        lager:info("TX queue tx failed ~s ~p", [TxID, Reason]),
        hashqueue:remove(TxID, Acc)
    end,
    InProc0,
    Txs),
  gen_server:cast(txstatus, {done, false, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, false, Txs}),
  {noreply, State#{
    inprocess => InProc1
  }};


handle_cast({new_height, H}, State) ->
  {noreply, State#{height=>H}};

handle_cast(settings, State) ->
  {noreply, load_settings(State)};

handle_cast(prepare, #{mychain:=MyChain, inprocess:=InProc0, queue:=Queue} = State) ->
  
  Time = erlang:system_time(seconds),
  {InProc1, Queue1} = recovery_lost(InProc0, Queue, Time),
  ETime = Time + 1,
  
  {Queue2, TxIds} =
    txpool:pullx({txpool:get_max_pop_tx(), txpool:get_max_tx_size()}, Queue1, []),
  
  txlog:log(TxIds, #{where => txqueue_prepare}),
  
  stout:log(txqueue_prepare, [ {ids, TxIds}, {node, nodekey:node_name()} ]),
  
  PK =
    case maps:get(pubkey, State, undefined) of
      undefined -> nodekey:get_pub();
      FoundKey -> FoundKey
    end,
  
  try
    PreSig = maps:merge(
      gen_server:call(blockchain, lastsig),
      #{null=><<"mkblock">>,
        chain=>MyChain
      }),
    MResX = msgpack:pack(PreSig),
    gen_server:cast(mkblock, {tpic, PK, MResX}),
    tpic:cast(tpic, <<"mkblock">>, MResX),
    stout:log(txqueue_xsig, [ {ids, TxIds} ])
  catch
    Ec:Ee ->
      utils:print_error("Can't send xsig", Ec, Ee, erlang:get_stacktrace())
  end,
  
  try
    LBH = get_lbh(State),
    LastBlk=block:pack(blockchain:last_meta()),
    TxMap =
      lists:foldl(
        fun(Id, Acc) -> maps:put(Id, null, Acc) end,
        #{},
        TxIds
      ),
    lager:debug("txs for mkblock: ~p", [TxMap]),
    MRes = msgpack:pack(
      #{
        null=><<"mkblock">>,
        chain=>MyChain,
        lbh=>LBH,
        lastblk=>LastBlk,
        txs=>TxMap
      }
    ),
    gen_server:cast(mkblock, {tpic, PK, MRes}),
    tpic:cast(tpic, <<"mkblock">>, MRes),
    stout:log(txqueue_mkblock, [{ids, TxIds}, {lbh, LBH}])
  catch
    Ec1:Ee1 ->
      utils:print_error("Can't encode", Ec1, Ee1, erlang:get_stacktrace())
  end,
  
  {noreply,
    State#{
      queue=>Queue2,
      inprocess=>lists:foldl(
        fun(TxId, Acc) ->
          hashqueue:add(TxId, ETime, null, Acc)
        end,
        InProc1,
        TxIds
      )
    }};

handle_cast(prepare, State) ->
  lager:notice("TXQUEUE Blocktime, but I am not ready"),
  {noreply, load_settings(State)};


handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.

%%handle_info(getlb, State) ->
%%  {_Chain,Height}=gen_server:call(blockchain,last_block_height),
%%  {noreply, State#{height=>Height}};

handle_info(prepare, State) ->
  handle_cast(prepare, State);

handle_info({push, BatchNo, TxIds}, State) when is_list(TxIds) ->
  handle_cast({push, BatchNo, TxIds}, State);

handle_info({push_head, TxIds}, State) when is_list(TxIds) ->
  handle_cast({push_head, TxIds}, State);
  
handle_info(_Info, State) ->
  lager:notice("Unknown info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

push_queue_head(Txs, Queue) ->
%%  RevTxs = lists:reverse(Txs),
  RevTxs = Txs,
  txlog:log(lists:reverse(RevTxs), #{where => txqueue_recovery2}),
  lists:foldl(fun queue:in_r/2, Queue, RevTxs).


recovery_lost(InProc, Queue, Now) ->
  recovery_lost(InProc, Queue, Now, []).

recovery_lost(InProc, Queue, Now, AccTxs) ->
  case hashqueue:head(InProc) of
    empty ->
      {InProc, push_queue_head(AccTxs, Queue)};
    I when is_integer(I) andalso I >= Now ->
      {InProc, push_queue_head(AccTxs, Queue)};
    I when is_integer(I) ->
      case hashqueue:pop(InProc) of
        {InProc1, empty} ->
          {InProc1, push_queue_head(AccTxs, Queue)};
        {InProc1, {TxID, _TxBody}} ->
          txlog:log([TxID], #{where => txqueue_recovery1}),
          recovery_lost(InProc1, Queue, Now, [TxID | AccTxs])
      end
  end.

%% ------------------------------------------------------------------

load_settings(State) ->
  MyChain = blockchain:chain(),
  {_Chain, Height} = gen_server:call(blockchain, last_block_height),
  State#{
    mychain => MyChain,
    height => Height
  }.

%% ------------------------------------------------------------------

get_lbh(State) ->
  case maps:find(height, State) of
    error ->
      {_Chain, H1} = gen_server:call(blockchain, last_block_height),
      gen_server:cast(self(), {new_height, H1}), % renew height cache in state
      H1;
    {ok, H1} ->
      H1
  end.

%% ------------------------------------------------------------------

get_state() ->
  gen_server:call(?MODULE, state).

%% ------------------------------------------------------------------

reassembly_batch(#{try_count := ?MAX_REASSEMBLY_TRIES} = BatchState) ->
  #{holding_storage := Holding} = BatchState,
  
  case lists:sort(maps:keys(Holding)) of
    [] ->
      BatchState#{try_count => 0};
    [FirstBatchNo | _] ->
      % if tries count reached, then patch current batch number to restart processes
      reassembly_batch(BatchState#{current_batch => FirstBatchNo, try_count => 0})
  end;

reassembly_batch(#{
    queue := Queue,
    current_batch := CurrentBatch,
    holding_storage := Holding,
    try_count := TryCount
  } = BatchState) ->

    case maps:get(CurrentBatch, Holding, undefined) of
      undefined -> BatchState#{try_count := TryCount + 1};
      TxIds ->
        txlog:log(TxIds,
          #{where => reassembly_batch,
            batchno => CurrentBatch,
            trycount => TryCount}),
  
        reassembly_batch(
          BatchState#{
            queue => lists:foldl(fun queue:in/2, Queue, TxIds),
            holding_storage => maps:remove(CurrentBatch, Holding),
            current_batch => CurrentBatch + 1,
            try_count => 0
          }
        )
    end;

reassembly_batch(#{try_count := TryCount} = BatchState) ->
  BatchState#{try_count := TryCount + 1}.


%% ------------------------------------------------------------------

get_max_reassembly_tries() ->
  ?MAX_REASSEMBLY_TRIES.

