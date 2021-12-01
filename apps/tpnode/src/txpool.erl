-module(txpool).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(SYNC_TIMER_MS, 100).
-define(SYNC_TX_COUNT_PER_PROCESS, 50).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([new_tx/1, get_pack/0, inbound_block/1, get_max_tx_size/0, get_max_pop_tx/0, pullx/3]).
-export([get_state/0, sort_txs/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([encode_int/1,decode_ints/1]).
-export([decode_txid/1]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

new_tx(BinTX) ->
    gen_server:call(txpool, {new_tx, BinTX}).

inbound_block(Blk) ->
  gen_server:cast(txpool, {inbound_block, Blk}).

get_pack() ->
    gen_server:call(txpool, get_pack).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  State = #{
    queue => queue:new(),
    batch_no => 0,
    nodeid => nodekey:node_id(),
    pubkey => nodekey:get_pub(),
    sync_timer => undefined
  },
  {ok, load_settings(State)}.

handle_call(state, _Form, State) ->
    {reply, State, State};

handle_call({portout, #{
               from:=Address,
               portout:=PortTo,
               seq:=Seq,
               timestamp:=Timestamp,
               public_key:=HPub,
               signature:=HSig
              }
            }, _From, #{sync_timer:=Tmr, queue:=Queue}=State) ->
    lager:notice("TODO: Check keys"),
    case generate_txid(State) of
      error ->
        {reply, {error,cant_gen_txid}, State};
      {ok, TxID} ->
        BinTx = tx:pack(
          #{
            from=>Address,
            portout=>PortTo,
            seq=>Seq,
            timestamp=>Timestamp,
            public_key=>HPub,
            signature=>HSig
          }
        ),
        {reply,
         {ok, TxID},
         State#{
           queue=>queue:in({TxID, BinTx}, Queue),
           sync_timer => update_sync_timer(Tmr)
         }
        }
    end;

handle_call({new_tx, Tx}, _From, State) when is_map(Tx) ->
  handle_call({new_tx, tx:pack(Tx)}, _From, State);

handle_call({new_tx, BinTx}, _From, #{sync_timer:=_Tmr, queue:=_Queue}=State)
  when is_binary(BinTx) ->
    try
        case tx:verify(BinTx) of
            {ok, _Tx} ->
            case generate_txid(State) of
              error ->
                {reply, {error, cant_gen_txid}, State};
              {ok, TxID} ->
                case gen_server:call(txstorage, {new_tx, TxID, BinTx}) of
                  ok ->
                    {reply, {ok, TxID}, State};
                  {error, Any} ->
                    {reply, {error, Any}, State}
                end

%                Res=gen_server:cast(txqueue, {push_tx, TxID, BinTx}),
%                lager:info("New TX ~s cast in to queue ~p",[TxID,Res]),
%                {reply, {ok, TxID},
%                 State#{
%                   %queue=>queue:in({TxID, BinTx}, Queue),
%                   %sync_timer => update_sync_timer(Tmr)
%                  }}
            end;
            Err ->
                {reply, {error, Err}, State}
        end
    catch
      Ec:Ee:S ->
        %S=erlang:get_stacktrace(),
        utils:print_error("error while processing new tx", Ec, Ee, S),
        {reply, {error, {Ec, Ee}}, State}
    end;

handle_call(txid, _From, State) ->
  {reply, generate_txid(State), State};

handle_call(status, _From, #{nodeid:=Node, queue:=Queue}=State) ->
  {reply, {Node, queue:len(Queue)}, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast({new_height, H}, State) ->
  {noreply, State#{height=>H}};

handle_cast({inbound_block, #{hash:=Hash} = Block}, #{sync_timer:=Tmr, queue:=Queue} = State) ->
  TxId = bin2hex:dbin2hex(Hash),
  lager:info("Inbound block ~p", [{TxId, Block}]),
  % we need synchronise inbound blocks as well as incoming transaction from user
  % inbound blocks may arrive at two nodes or more at the same time
  % so, we may already have this inbound block in storage
  NewQueue =
    case tpnode_txstorage:get_tx(TxId) of
      error ->
        % we don't have this block in storage. process it as usual
        BinTx = tx:pack(Block),
        queue:in({TxId, BinTx}, Queue);
      {ok, {TxId, _, _}} ->
        % we already have this block in storage. we only need add its txid to outbox
        gen_server:cast(txqueue, {push, [TxId]}),
        Queue
    end,
  
  
  {noreply,
    State#{
      queue=>NewQueue,
      sync_timer => update_sync_timer(Tmr)
    }
  };

handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(sync_tx,
  #{sync_timer:=Tmr, mychain:=_MyChain,
    minsig:=MinSig, queue:=Queue, batch_no:=BatchNo} = State) ->
  
  catch erlang:cancel_timer(Tmr),
  lager:info("run tx sync"),
  MaxPop = chainsettings:get_val(<<"poptxs">>, ?SYNC_TX_COUNT_PER_PROCESS),
  
  % do nothing in case peers count less than minsig
  Peers = tpic2:cast_prepare(<<"mkblock">>),
  SingleNodeTest=case nodekey:get_privs() of
                   [_,_|_] -> true;
                   _ -> false
                 end,
  case length(Peers) of
    _ when MinSig == undefined ->
      % minsig unknown
      lager:error("minsig is undefined, we can't run transaction synchronizer"),
      {noreply, load_settings(State#{ sync_timer => update_sync_timer(undefined)})};
    PeersCount when not SingleNodeTest andalso PeersCount+1<MinSig ->
      % nodes count is less than we need, do nothing  (nodes = peers + 1)
      lager:info("nodes count ~p is less than minsig ~p", [PeersCount+1, MinSig]),
      {noreply, State#{ sync_timer => update_sync_timer(undefined) }};
    _ ->
      % peers count is OK, sync transactions
      {NewQueue, Transactions} = pullx({MaxPop, get_max_tx_size()}, Queue, []),
  
      txlog:log(
        [TxId1 || {TxId1, _TxBody1} <- Transactions],
        #{where => txpool}
      ),
      
      NewBatchNo =
        case Transactions of
          [] ->
            BatchNo; % don't increase batch id number
          _ ->
            erlang:spawn(txsync, do_sync, [Transactions, #{ batch_no => BatchNo }]),
            self() ! sync_tx,
            BatchNo + 1   % increase batch id
        end,
      {noreply,
        State#{
          sync_timer => undefined,
          queue => NewQueue,
          batch_no => NewBatchNo
        }
      }
  end;

handle_info(prepare, State) ->
  handle_cast(prepare, State);


handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

decode_int(<<0:1/big,X:7/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<2:2/big,X:14/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<6:3/big,X:29/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<14:4/big,X:60/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<15:4/big,S:4/big,BX:S/binary,Rest/binary>>) ->
  {binary:decode_unsigned(BX),Rest}.

%% ------------------------------------------------------------------

encode_int(X) when X<128 ->
  <<X:8/integer>>;
encode_int(X) when X<16384 ->
  <<2:2/big,X:14/big>>;
encode_int(X) when X<536870912 ->
  <<6:3/big,X:29/big>>;
encode_int(X) when X<1152921504606846977 ->
  <<14:4/big,X:60/big>>;
encode_int(X) ->
  B=binary:encode_unsigned(X),
  true=(size(B)<15),
  <<15:4/big,(size(B)):4/big,B/binary>>.

%% ------------------------------------------------------------------

decode_ints(Bin) ->
  case decode_int(Bin) of
    {Int, <<>>} ->
      [Int];
    {Int, Rest} ->
     [Int|decode_ints(Rest)]
  end.

%% ------------------------------------------------------------------
decode_txid(TxId) when is_binary(TxId) ->
  case binary:split(TxId, <<"-">>) of
    [N0, N1] ->
      Bin = base58:decode(N0),
      {ok, N1, decode_ints(Bin)};
    _ ->
      {error, invalid_tx_id}
  end.

%% ------------------------------------------------------------------

generate_txid(#{mychain:=MyChain}=State) ->
  LBH=get_lbh(State),
  T=os:system_time(),
%  N=erlang:unique_integer([positive]),
  P=nodekey:node_name(),
  %  Timestamp=base58:encode(binary:encode_unsigned(os:system_time())),
  %  Number=base58:encode(binary:encode_unsigned(erlang:unique_integer([positive]))),
  %  iolist_to_binary([Timestamp, "-", Node, "-", Number]).
  I=base58:encode(
      iolist_to_binary(
        [encode_int(MyChain),
         encode_int(LBH),
         encode_int(T) ])),
  {ok,<<I/binary,"-",P/binary>>};
%<<MyChain:32/big,T:64/big,P/binary>>.

generate_txid(#{}) ->
  error.

%% ------------------------------------------------------------------
sort_txs([]) ->
  [];

sort_txs(Txs) when is_list(Txs) ->
  Unpacked =
    lists:map(
      fun(TxId) ->
        case decode_txid(TxId) of
          {ok, _NodeId, [_Chain, _Height, Timestamp]} ->
            {Timestamp, TxId};
          _ ->
            {0, TxId}
        end
      end,
      Txs
    ),
  Sorted = lists:keysort(1, Unpacked),
  [TxId2 || {_, TxId2} <- Sorted ].
  


%% ------------------------------------------------------------------

pullx({0, _}, Q, Acc) ->
    {Q, lists:reverse(Acc)};

pullx({N, MaxSize}, Q, Acc) ->
    {Element, Q1}=queue:out(Q),
    case Element of
        {value, E1} ->
          MaxSize1 = MaxSize - txsize(E1),
          if
            MaxSize1 < 0 ->
              {Q, lists:reverse(Acc)};
            true ->
              %lager:debug("Pull tx ~p", [E1]),
              pullx({N - 1, MaxSize1}, Q1, [E1 | Acc])
          end;
        empty ->
            {Q, lists:reverse(Acc)}
    end.

txsize(Bin) when is_binary(Bin) ->
  size(Bin);
txsize({TxID, Bin}) when is_binary(TxID), is_binary(Bin) ->
  size(TxID)+size(Bin);
txsize(_) ->
  0.


%% ------------------------------------------------------------------

load_settings(State) ->
  MyChain = blockchain:chain(),
  #{header:=#{height:=Height}}=blockchain:last_meta(),
  State#{
    mychain=>MyChain,
    height=>Height,
    minsig => chainsettings:get_val(minsig, undefined)
  }.

%% ------------------------------------------------------------------

update_sync_timer(Tmr) ->
  case Tmr of
    undefined ->
      erlang:send_after(?SYNC_TIMER_MS, self(), sync_tx);
    _ ->
      Tmr
  end.

%% ------------------------------------------------------------------

get_max_tx_size() ->
  get_max_tx_size(4*1024*1024).

get_max_tx_size(Default) ->
  chainsettings:get_val(<<"maxtxsize">>, Default).


%% ------------------------------------------------------------------

get_max_pop_tx() ->
  get_max_pop_tx(200).

get_max_pop_tx(Default) ->
  chainsettings:get_val(<<"poptxs">>, Default).

%% ------------------------------------------------------------------

get_lbh(State) ->
  txqueue:get_lbh(State).

%% ------------------------------------------------------------------

get_state() ->
  gen_server:call(?MODULE, state).

