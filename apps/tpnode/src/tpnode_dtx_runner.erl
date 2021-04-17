-module(tpnode_dtx_runner).

-export([prepare/0,ready4run/0,run/0]).

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
  Timestamps=[ Ready || Ready <- lists:sort(
                                   maps:keys(
                                     chainsettings:by_path([<<"current">>,<<"delaytx">>])
                                    )
                                  ),
                        is_integer(Ready),
                        Ready<os:system_time(second)+60
             ],
  ET=lists:foldl(
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
    end, [], Timestamps),

  EmitBTXs=[{TxID, tx:pack(Tx,[withext])} || {TxID,Tx} <- ET ],
  Push=gen_server:cast(txstorage, {store_etxs, EmitBTXs}),
  {Push, ET}.

cast_ready() ->
  IDs = ready4run(),
  [ gen_server:cast(txqueue, {push_tx, TxID}) || TxID <- IDs ].

ready4run() ->
  Timestamps=[ Ready || Ready <- lists:sort(
                                   maps:keys(
                                     chainsettings:by_path([<<"current">>,<<"delaytx">>])
                                    )
                                  ),
                        is_integer(Ready),
                        Ready<os:system_time(second)
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


