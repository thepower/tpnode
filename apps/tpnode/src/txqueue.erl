-module(txqueue).
-include_lib("include/tplog.hrl").

-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(MAX_REASSEMBLY_TRIES, 30).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, get_lbh/1, get_state/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-export([recovery_lost/4]).

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
      lost_cnt => #{},
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
  ?LOG_NOTICE("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast({push_tx, TxId, TxBody},
            #{queue:=Queue} = State) when is_binary(TxId), is_binary(TxBody) ->
  ?LOG_INFO("Pushed TX ~s",[TxId]),
  {noreply, State#{
              queue => queue:in({TxId, TxBody},Queue)
             }
  };

handle_cast({push_tx, TxId},
            #{queue:=Queue} = State) when is_binary(TxId) ->
  ?LOG_INFO("Pushed TX ~s without body",[TxId]),
  {noreply, State#{
              queue => queue:in({TxId,null},Queue)
             }
  };

handle_cast({push_head, TxIds}, #{queue:=Queue} = State) when is_list(TxIds) ->
  ?LOG_INFO("push head ~p", [TxIds]),
  stout:log(txqueue_pushhead, [ {ids, TxIds} ]),

  RevIds = lists:reverse(TxIds),

  txlog:log(RevIds, #{where => queue_push_head}),

  {noreply, State#{
    queue=>lists:foldl( fun queue:in_r/2, Queue, RevIds)
  }};

handle_cast({done, Txs}, #{inprocess:=InProc0,
                           lost_cnt:=LCnt
                          } = State) ->
  stout:log(txqueue_done, [ {result, true}, {ids, Txs} ]),
  InProc1 =
    lists:foldl(
      fun
        ({Tx, _}, Acc) ->
          ?LOG_INFO("TX queue ext tx done ~p", [Tx]),
          hashqueue:remove(Tx, Acc);
        (Tx, Acc) ->
          ?LOG_DEBUG("TX queue tx done ~p", [Tx]),
          hashqueue:remove(Tx, Acc)
      end,
      InProc0,
      Txs),
    LCnt1 = lists:foldl(
              fun
                ({TxID, _}, Acc) ->
                  maps:remove(TxID, Acc);
                (TxID, Acc) ->
                  maps:remove(TxID, Acc)
              end,
              LCnt,
              Txs
             ),
  gen_server:cast(txstatus, {done, true, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, true, Txs}),
  {noreply,
    State#{
      lost_cnt=>LCnt1,
      inprocess => InProc1
    }};

handle_cast({failed, Txs}, #{inprocess:=InProc0,
                             lost_cnt:=LCnt
                            } = State) ->
  stout:log(txqueue_done, [ {result, failed}, {ids, Txs} ]),
  InProc1 = lists:foldl(
    fun
      ({_, {overdue, Parent}}, Acc) ->
        ?LOG_INFO("TX queue inbound block overdue ~p", [Parent]),
        hashqueue:remove(Parent, Acc);
      ({TxID, Reason}, Acc) ->
        ?LOG_INFO("TX queue tx failed ~s ~p", [TxID, Reason]),
        hashqueue:remove(TxID, Acc)
    end,
    InProc0,
    Txs),
  LCnt1 = lists:foldl(
            fun
              ({_, {overdue, Parent}}, Acc) ->
                maps:remove(Parent, Acc);
              ({TxID, _}, Acc) ->
                maps:remove(TxID, Acc)
            end,
            LCnt,
            Txs
           ),
  gen_server:cast(txstatus, {done, false, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, false, Txs}),
  {noreply, State#{
              lost_cnt=>LCnt1,
              inprocess => InProc1
  }};


handle_cast({new_height, H}, State) ->
  {noreply, State#{height=>H}};

handle_cast(settings, State) ->
  {noreply, load_settings(State)};

handle_cast(prepare, #{mychain:=MyChain, inprocess:=InProc0, queue:=Queue, lost_cnt:=LCnt} = State) ->

  Time = erlang:system_time(seconds),
  {InProc1, {Queue1,LCnt1}} = recovery_lost(InProc0, Queue, Time, LCnt),
  ETime = Time + 20,

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
    LBH = get_lbh(State),
    LastBlk=block:pack(blockchain:last_meta()),
    TxMap =
    lists:foldl(
      fun
        ({Id, Body}, Acc) ->
          maps:put(Id, Body, Acc);
        (Id, Acc) ->
          maps:put(Id, null, Acc)
      end,
      #{},
      TxIds
     ),
    ?LOG_DEBUG("txs for mkblock: ~p", [TxMap]),
    Entropy = crypto:strong_rand_bytes(32),

    SentTo=[ begin
              {ed25519,Pub} = tpecdsa:cmp_pubkey(RPK),
              Pub
            end || {RPK,_,_} <- tpic2:cast_prepare(<<"mkblock">>)
          ],

    MRes = msgpack:pack(
             #{
             null=><<"mkblock">>,
             chain=>MyChain,
             lbh=>LBH,
             lastblk=>LastBlk,
             entropy=>Entropy,
             timestamp=>os:system_time(millisecond),
             txs=>TxMap,
             sent_to=>SentTo
            }
            ),
    ?LOG_DEBUG("Going to send ~p",[[disp(KK) || KK <- SentTo]]),
    gen_server:cast(mkblock, {tpic, PK, MRes}),
    tpic2:cast(<<"mkblock">>, MRes),
    stout:log(txqueue_mkblock, [{ids, TxIds}, {lbh, LBH}])
  catch
    Ec1:Ee1:S1 ->
      %S1=erlang:get_stacktrace(),
      utils:print_error("Can't encode", Ec1, Ee1, S1)
  end,

  {noreply,
   State#{
     queue=>Queue2,
     lost_cnt=>LCnt1,
     inprocess=>lists:foldl(
                  fun({TxId,TxB}, Acc) ->
                      hashqueue:add(TxId, ETime, TxB, Acc)
                  end,
                  InProc1,
                  TxIds
                 )
    }};

handle_cast(prepare, State) ->
  ?LOG_NOTICE("TXQUEUE Blocktime, but I am not ready"),
  {noreply, load_settings(State)};


handle_cast(_Msg, State) ->
  ?LOG_NOTICE("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(prepare, State) ->
  handle_cast(prepare, State);

handle_info({push, BatchNo, TxIds}, State) when is_list(TxIds) ->
  handle_cast({push, BatchNo, TxIds}, State);

handle_info({push_head, TxIds}, State) when is_list(TxIds) ->
  handle_cast({push_head, TxIds}, State);

handle_info(_Info, State) ->
  ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

push_queue_head([], Queue, LCnt) ->
  {Queue, LCnt};

push_queue_head(Txs, Queue, LCnt) ->
  {Txs1, LCnt1} = lists:foldl(
                    fun({TxID, TxBody}, {Q0,LC0}) ->
                        Recovered=maps:get(TxID,LC0,0),
                        if(Recovered>5) ->
                            ?LOG_ERROR("Giving up tx ~p",[TxID]),
                            {Q0,maps:remove(TxID, LC0)};
                          true ->
                            {[{TxID, TxBody}|Q0],maps:put(TxID, Recovered+1, LC0)}
                        end
                    end, {[], LCnt}, Txs),
  RevTxs = lists:reverse(Txs1),
  %  RevTxs = Txs,
  txlog:log(lists:reverse(RevTxs), #{where => txqueue_recovery2}),
  {lists:foldl(fun queue:in_r/2, Queue, RevTxs),
   LCnt1}.


recovery_lost(InProc, Queue, Now, LCnt) ->
  recovery_lost(InProc, Queue, Now, LCnt, []).

recovery_lost(InProc, Queue, Now, LCnt, AccTxs) ->
  case hashqueue:head(InProc) of
    empty ->
      {InProc, push_queue_head(AccTxs, Queue, LCnt)};
    I when is_integer(I) andalso I >= Now ->
      {InProc, push_queue_head(AccTxs, Queue, LCnt)};
    I when is_integer(I) ->
      case hashqueue:pop(InProc) of
        {InProc1, empty} ->
          {InProc1, push_queue_head(AccTxs, Queue, LCnt)};
        {InProc1, {TxID, TxBody}} ->
          txlog:log([TxID], #{where => txqueue_recovery1}),
          recovery_lost(InProc1, Queue, Now, LCnt, [{TxID,TxBody} | AccTxs])
      end
  end.

%% ------------------------------------------------------------------

load_settings(State) ->
  MyChain = blockchain:chain(),
  #{header:=#{height:=Height}}=blockchain:last_meta(),
  State#{
    mychain => MyChain,
    height => Height
  }.

%% ------------------------------------------------------------------

get_lbh(State) ->
  case maps:find(height, State) of
    error ->
      #{header:=#{height:=H1}}=blockchain:last_meta(),
      gen_server:cast(self(), {new_height, H1}), % renew height cache in state
      H1;
    {ok, H1} ->
      H1
  end.

%% ------------------------------------------------------------------

get_state() ->
  gen_server:call(?MODULE, state).

%% ------------------------------------------------------------------

disp(Key) ->
  hex:encodex(Key).
  %case chainsettings:is_our_node(Key) of
  %  false -> hex:encodex(Key);
  %  Any -> Any
  %end.

