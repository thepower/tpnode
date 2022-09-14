-module(tpnode_dtx_runner).
-include("include/tplog.hrl").

-export([ready2prepare/0,prepare/0,ready4run/0,run/0]).

run() ->
  case whereis(dtx_runner) of
    undefined ->
      spawn(fun() ->
                register(dtx_runner, self()),
                prepare(),
                timer:sleep(1000),
                cast_ready()
            end);
    _ -> already_running
  end.


prepare() ->
  ET=ready2prepare(),
  EmitBTXs=[{TxID, tx:pack(Tx,[withext])} || {TxID,Tx} <- ET ],
  if(EmitBTXs =/= []) ->
      ?LOG_INFO("Prepare dtxs ~p",[proplists:get_keys(EmitBTXs)]);
    true ->
      ok
  end,
  Push=gen_server:cast(txstorage, {store_etxs, EmitBTXs}),
  {Push, ET}.

cast_ready() ->
  IDs = ready4run(),
  %?LOG_INFO("cast ready dtxs ~p",[IDs]),
  [ gen_server:cast(txqueue, {push_tx, TxID}) || TxID <- IDs ].

ready4run() ->
  Now=os:system_time(second),
  Timestamps=[ Ready || Ready <- lists:sort(
                                   maps:keys(
                                     chainsettings:by_path([<<"current">>,<<"delaytx">>])
                                    )
                                  ),
                        is_integer(Ready),
                        Ready<Now
             ],
  IDs=lists:foldl(
    fun(Timestamp, Acc) ->
        Txs=chainsettings:by_path([<<"current">>,<<"delaytx">>,Timestamp]),
        lists:foldl(
          fun([_BH, _BP, TxID], Acc1) ->
              [TxID|Acc1]
          end, Acc, Txs)
    end, [], Timestamps),
  IDs.


ready2prepare() ->
  MinFuture = os:system_time(second)+60,
  Timestamps=[ Ready || Ready <- lists:sort(
                                   maps:keys(
                                     chainsettings:by_path([<<"current">>,<<"delaytx">>])
                                    )
                                  ),
                        is_integer(Ready),
                        Ready<MinFuture
             ],
  lists:foldl(
    fun(Timestamp, Acc) ->
        Txs=chainsettings:by_path([<<"current">>,<<"delaytx">>,Timestamp]),
        lists:foldl(
          fun([BH, BP, TxID], Acc1) ->
              case tpnode_txstorage:exists(TxID) of
                true -> Acc1;
                _ -> %false or expiring
                  case blockchain:rel(BP,child) of
                    #{header:=#{height:=H},hash:=Hash,etxs:=ETxs} when H==BH ->
                      case lists:keyfind(TxID, 1, ETxs) of
                        {TxID, TxBody} ->
                          TxBody1=tx:sign(
                                    tx:set_ext(origin_height,H,
                                               tx:set_ext(origin_block,Hash,
                                                          TxBody
                                                         )
                                              ),
                                    nodekey:get_priv()),
                          [{TxID, TxBody1}|Acc1];
                        false ->
                          Acc1
                      end;
                    _ ->
                      Acc1
                  end
              end
          end, Acc, Txs)
    end, [], Timestamps).

