-module(txqueue_test).

-include_lib("eunit/include/eunit.hrl").

%%-export([handle_info/2]).


%%handle_cast(
%%  {push, BatchNo, TxIds}, #{queue:=Queue, batch_state := BatchState} = State)
%%  when is_list(TxIds) and is_number(BatchNo) ->


%init_state() ->
%  #{
%    queue => queue:new(),
%    inprocess => hashqueue:new(),
%    batch_state => #{
%      holding_storage => #{},
%      current_batch => 0
%    }
%  }.
%% ------------------------------------------------------------------

%get_queue(Queue, Cnt) ->
%  get_queue(Queue, Cnt, []).
%
%get_queue(Queue, 0, Acc) ->
%  {Queue, Acc};
%
%get_queue(Queue, Cnt, Acc) ->
%  {Element, Queue1}=queue:out(Queue),
%  case Element of
%    {value, E1} ->
%      get_queue(Queue1, Cnt-1, Acc ++ [E1]);
%    empty ->
%      {Queue1, Acc}
%  end.
  
%% ------------------------------------------------------------------

%%make_tx_list(TxIds) ->
%%  [ {TxId, null} || TxId <- TxIds].

%% ------------------------------------------------------------------

%%  {push, BatchNo, TxIds}, #{queue:=Queue, batch_state := BatchState} = State)

%storage_choose_test() ->
%  State0 = init_state(),
%  
%  %% batch 0, should choose queue as a storage for correct batch number
%  Tx1_0 = [1,2,3,4,5],
%  {noreply, #{queue := Queue1_0, batch_state := BatchState1} = State1} =
%    txqueue:handle_cast({push, 0, Tx1_0}, State0),
%  
%  ?assertMatch(#{holding_storage := #{}}, BatchState1),
%  ?assertMatch(#{current_batch := 1}, BatchState1),
%  
%  {_Queue1_1, Tx1_1} = get_queue(Queue1_0, length(Tx1_0)),
%  ?assertEqual(Tx1_0, Tx1_1),
%  
%  %% batch 2, should choose holding storage for batch with number from future
%  Tx2_0 = [ 26, 27, 28 ],
%  
%  {noreply, #{queue := Queue2_0, batch_state := BatchState2} = State2} =
%    txqueue:handle_cast({push, 2, Tx2_0}, State1),
%  
%  % queue should be kept untouched
%  ?assertEqual(Queue1_0, Queue2_0),
%  
%  % transaction ids should go to holding storage
%  ?assertMatch(#{holding_storage := #{ 2 := Tx2_0 }}, BatchState2),
%
%  %% batch 0, should skip obsolete batch
%  Tx3_0 = [ 6, 7, 8 ],
%
%  {noreply, #{queue := Queue3_0, batch_state := BatchState3} = State3} =
%    txqueue:handle_cast({push, 0, Tx3_0}, State2),
%  
%  % batch state shouldn't be changed
%  ?assertEqual(Queue2_0, Queue3_0),
%  ?assertEqual(BatchState2, BatchState3),
%  
%  %% batch 5, one more batch from the future
%  Tx4_0 = [ 51,52,53,54 ],
%  {noreply, #{queue := _Queue4_0, batch_state := _BatchState4} = State4} =
%    txqueue:handle_cast({push, 5, Tx4_0}, State3),
%  
%  
%  %% should reassemble txs from all batches when have the missing batch received
%  Tx5_0 = [ 11,12 ],
%  {noreply, #{queue := Queue5_0, batch_state := BatchState5} = State5} =
%    txqueue:handle_cast({push, 1, Tx5_0}, State4),
%  
%  AllTxs5 = Tx1_0 ++ Tx5_0 ++ Tx2_0, % without batch 5
%  {_Queue5_1, Tx5_1} = get_queue(Queue5_0, length(AllTxs5)),
%  ?assertEqual(AllTxs5, Tx5_1),
%  ?assertMatch(#{current_batch := 3}, BatchState5),
%  ?assertMatch(#{holding_storage := #{ 5 := Tx4_0 }}, BatchState5),
%  
%  %% should force reassemble txs if one batch is missing and we have exceeded tries count
%  #{queue := Queue6_0, batch_state := BatchState6} = _State6 =
%    lists:foldl(
%      fun(_TryNo, CurrentState) ->
%        {noreply, NewState6} =
%          txqueue:handle_cast({push, 100500, []}, CurrentState),
%        NewState6
%      end,
%      State5,
%      lists:seq(1, txqueue:get_max_reassembly_tries())
%    ),
%  
%  AllTxs6 = Tx1_0 ++ Tx5_0 ++ Tx2_0 ++ Tx4_0,
%  {_Queue6_1, Tx6_1} = get_queue(Queue6_0, length(AllTxs6)),
%  ?assertEqual(AllTxs6, Tx6_1),
%  ?assertMatch(#{current_batch := 6}, BatchState6).

