-module(tpnode_txsync).
-include("include/tplog.hrl").

-export([synchronize/2, run_sync/3]).

synchronize(TxID, #{min_peers:=_}=Opts0) ->
  Opts=maps:merge(
         #{
         timeout=>90,
         retry=>3,
         notify=>self()
        },
         Opts0),
  Parent=self(),
  Pid=erlang:spawn(
    fun() ->
        {ok, {TxID, TxBin, _}}=tpnode_txstorage:get_tx(TxID),
        Parent ! {self(), ok},
        run_sync(TxID, TxBin, Opts)
    end),
  receive 
    {Pid, ok} -> ok;
    {Pid, Other} -> {error, Other}
  after 2000 ->
          {error, timeout}
  end.


run_sync(TxID, TxBin, #{retry:=Retry}=Opts) ->
  Peers2Sync=tpic2:cast_prepare(<<"txpool">>),
  PList=[ {Peer, Retry} || Peer <- Peers2Sync ],
  ?LOG_DEBUG("Tx sync ~p Prepared ~p~n",[TxID, PList]),
  PushBin=msgpack:pack(
            #{ null => <<"txsync_push">>,
               <<"txid">> => TxID,
               <<"body">> => TxBin}),
  PList1=cast_peers(TxID, PushBin, PList),
  sync_loop(TxID, PushBin, PList1, [], Opts).

sync_loop(TxID, _PushBin, [], Done, #{min_peers:=MP, notify:=Notify} = _Opts) ->
  if is_pid(Notify) ->
       Notify ! {txsync_done, length(Done)>=MP, TxID, Done};
     is_function(Notify) ->
       Notify(length(Done)>=MP, TxID, Done);
     true ->
       ?LOG_NOTICE("Bad notifier ~p",[Notify])
  end;

sync_loop(TxID, PushBin, PList, Done, #{min_peers:=MP}=Opts) ->
  Timeout = if(length(Done) >= MP) ->
                1000;
              true ->
                5000
            end,
  receive
    {'$gen_cast',{tpic,{Peer, <<"txpool">>, _ReqID}, _Response}} ->
      ?LOG_DEBUG("Tx ~p Peer ~p done!~n",[TxID, Peer]),
      PList1=lists:filter(fun({{MPeer,_,_},_}) ->
                              MPeer=/=Peer
                          end, PList),
      sync_loop(TxID, PushBin, PList1, [Peer|Done], Opts)
  after Timeout ->
          PList1=cast_peers(TxID, PushBin, PList),
          sync_loop(TxID, PushBin, PList1, Done, Opts)
  end.

cast_peers(TxID, PushBin, PL) ->
  lists:filtermap(
    fun({Peer, Retry}) ->
        if Retry==0 ->
             ?LOG_NOTICE("tx ~p peer ~p sync try count exceeded, abandon peer",
                         [TxID, Peer]),
             false;
           Retry>0 ->
             io:format("Cast to ~p~n",[Peer]),
             tpic2:cast(Peer, PushBin),
             {true, {Peer, Retry-1}}
        end
    end, PL).

