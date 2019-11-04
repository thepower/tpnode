-module(txsync).

% -behaviour(gen_server).
% -define(SERVER, ?MODULE).
-define(RESEND_BATCH_ATTEMPTS, 2).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([do_sync/2, make_batch/1, parse_batch/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

% -export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2,
%   terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

% start_link() ->
%   gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

% init(_Args) ->
%   {ok, #{
%     tx_storage => #{}
%   }}.

% handle_call(_Request, _From, State) ->
%   lager:notice("Unknown call ~p", [_Request]),
%   {reply, ok, State}.

% handle_cast({new_tx, _TxId, _TxBody}, State) ->
%   {noreply, State};
  
% handle_cast(_Msg, State) ->
%   lager:notice("Unknown cast ~p", [_Msg]),
%   {noreply, State}.

% handle_info(_Info, State) ->
%   lager:notice("Unknown info  ~p", [_Info]),
%   {noreply, State}.

% terminate(_Reason, _State) ->
%   ok.

% code_change(_OldVsn, State, _Extra) ->
%   {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------



do_sync([], _Options) ->
  lager:error("txsync: empty transactions list"),
  error;

do_sync(Transactions, #{batch_no := BatchNo} = _Options) when is_list(Transactions) ->
  try
    lager:info("txsync: start for batch ~p, txcount=~p", [BatchNo, length(Transactions)]),
    stout:log(batchsync, [{action, start}, {batch, BatchNo}]),
    
    {BatchId, BatchBin} =
      case make_batch(Transactions) of
        {<<"">>, _} ->
          throw(empty_batch);
        {_, <<"">>} ->
          throw(empty_batch);
        {_, _} = TransactionBatch ->
          TransactionBatch
      end,
      
    Peers = tpic:cast_prepare(tpic, <<"mkblock">>),
    
%%    lager:debug("tpic peers: ~p", [Peers]),
    
    RawBatch = msgpack:pack(
      #{
        null => <<"mkblock">>,
        txbatch => BatchBin,
        batchid => BatchId
      }
    ),
    
    % Unconfirmed = [ #{ tpic_handle => pub_key } ]
    Unconfirmed =
      lists:foldl(
        fun
          ({TpicHandle, #{authdata:=AD}}, Acc) ->
            case proplists:get_value(pubkey, AD, undefined) of
              undefined ->
                Acc;
              PeerPubKey ->
                maps:put(TpicHandle, PeerPubKey, Acc)
            end;
          (_, Acc) ->
            Acc
        end,
        #{},
        Peers),
    send_batch(
      #{
        unconfirmed => Unconfirmed,
        confirmed => #{},
        conf_timeout_ms => get_wait_confs_timeout_ms(),
        batchid => BatchId,
        batchno => BatchNo,
        txs => maps:from_list(Transactions),
        attempts_left => ?RESEND_BATCH_ATTEMPTS,
        raw_batch => RawBatch
      }
    )
  catch
    throw:empty_batch ->
      lager:error("do_sync: empty batch"),
      error;
      
    Ec:Ee ->
      utils:print_error("do_sync error", Ec, Ee, erlang:get_stacktrace()),
      error
  end.

send_batch(#{attempts_left := 0, batchid := BatchId, batchno := BatchNo, txs := Txs}) ->
  lager:error("send_batch: timeout, id: ~p, no: ~p, lost txs: ~p", [BatchId, BatchNo, maps:keys(Txs)]),
  error;

send_batch(#{raw_batch := RawBatch} = State) ->
    tpic:cast(tpic, <<"mkblock">>, {<<"txbatch">>, RawBatch}),
    wait_response(State),
    ok.



%% ------------------------------------------------------------------
wait_response(
  #{unconfirmed := Unconfirmed,
    confirmed := Confirmed,
    conf_timeout_ms := TimeoutMs,
    batchid := BatchId,
    batchno := BatchNo,
    attempts_left := Attempts,
    txs := TxMap} = State) ->
  
  receive
%% {'$gen_cast',{tpic,{61,4,<<5,102,134,118,0,0,5,193>>},<<"fake_tx_id">>}}
    {'$gen_cast', {tpic, From, BatchId}}  ->
      Handle = get_tpic_handle(From),
      Confirmed1 =
        case maps:get(Handle, Unconfirmed, unknown) of
          unknown ->
            Confirmed; % don't touch confirmations
          PubKey ->
            lager:info("got confirmation from ~p", [PubKey]),
            maps:put(PubKey, 1, Confirmed)
        end,
      Unconfirmed1 = maps:remove(Handle, Unconfirmed),
      case maps:size(Unconfirmed1) of
        0 ->
          % all confirmations received
          lager:info("got all confirmations of ~p", [BatchId]),
          store_batch(TxMap, Confirmed, #{push_queue => true, batch_no => BatchNo}),
          stout:log(batchsync, [{action, done_ok}, {batch, BatchNo}]),
          ok;
        _ ->
          wait_response(
            State#{
              unconfirmed => Unconfirmed1,
              confirmed => Confirmed1
            }
          )
      end;
    Any ->
      lager:error("tx_sync unhandled message: ~p", [Any]),
      wait_response(State)
    after TimeoutMs ->
      % confirmations waiting cycle timeout
      case is_enough_confirmations(Unconfirmed, Confirmed) of
        true ->
          stout:log(batchsync, [{action, timeout_done}, {batch, BatchNo}, {attempts_left, Attempts}]),
          lager:info("batch ~p timeout, but got ~p confirmations", [BatchId, maps:size(Confirmed)]),
          store_batch(TxMap, Confirmed, #{push_queue => true, batch_no => BatchNo}),
          ok;
        _ ->
          stout:log(batchsync, [{action, timeout_retry}, {batch, BatchNo}, {attempts_left, Attempts-1}]),
          lager:error("EOF for batch ~p, attemps left: ~p", [BatchId, Attempts-1]),
          send_batch(State#{attempts_left := Attempts - 1}) % try to send it again
      end
  end,
  ok.

is_enough_confirmations(Unconfirmed, Confirmed) ->
  ConfCnt = maps:size(Confirmed),
  PeersCnt = trunc((maps:size(Unconfirmed) + ConfCnt)*2/3),
  MinSig = chainsettings:get_val(minsig, PeersCnt),
  Threshold = max(MinSig, PeersCnt),
  if 
    ConfCnt < Threshold -> false;
    true -> true
  end.


%% ------------------------------------------------------------------
% Txs = [ #{ TxId => TxBody } ]
% Nodes = #{ PubKey => 1 }
%%store_batch(Txs, Nodes) ->
%%  store_batch(Txs, Nodes, #{}).

store_batch(Txs, Nodes, Options) ->
  % txs order may be invalid after maps:to_list.
  % we'll sort txids at the moment of adding to queue in txstorage store cast
  TxsPList = maps:to_list(Txs),
%%  txlog:log([ K || {K,_} <- TxsPList ], #{where => store_batch}),
  gen_server:cast(txstorage, {store, TxsPList, maps:keys(Nodes), Options}).


%% ------------------------------------------------------------------
%% {61,4,<<5,102,134,118,0,0,5,193>>} -> {61,4}
get_tpic_handle({A, B, _}) ->
  {A, B}.

%% ------------------------------------------------------------------
get_wait_confs_timeout_ms() ->
  case chainsettings:get_val(<<"conf_timeout">>, undefined) of
    undefined ->
      BlockTime = chainsettings:get_val(blocktime, 3),
      BlockTime * 20;
    TimeoutMs -> TimeoutMs  
  end.

%% ------------------------------------------------------------------
make_batch(Transactions) when is_list(Transactions) ->
  make_batch(Transactions, <<"">>, <<"">>).

make_batch([], Batch, BatchId) ->
  {BatchId, Batch};

make_batch([{TxId, TxBody} | Rest], Batch, _BatchId)
  when is_binary(TxBody), is_binary(TxId) ->
  
  make_batch(
    Rest,
    <<Batch/binary,
      (size(TxId)):8/big,
      (size(TxBody)):32/big,
      TxId/binary, TxBody/binary>>,
    TxId   % we use the last transaction id as batch id
  );

make_batch([Invalid | Rest], Batch, BatchId) ->
  lager:info("skip invalid transaction from batch: ~p", [Invalid]),
  make_batch(Rest, Batch, BatchId).

%% ------------------------------------------------------------------

parse_batch(Batch) when is_binary(Batch) ->
  parse_batch(Batch, [], <<"">>).

parse_batch(<<"">>, ParsedTxs, BatchId) ->
  {BatchId, ParsedTxs};

parse_batch(
  <<S1:8/big, S2:32/big, TxId:S1/binary, TxBody:S2/binary, Rest/binary>>,
  Parsed,
  _BatchId) ->
  
  parse_batch(Rest, Parsed ++ [{TxId, TxBody}], TxId).


