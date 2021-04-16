-module(tpnode_dtx_runner).

-export([prepare/0,ready4run/0,run/0]).

run() ->
  ok.

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
          end, Acc, Txs)
    end, [], Timestamps),

  EmitBTXs=[{TxID, tx:pack(Tx,[withext])} || {TxID,Tx} <- ET ],
  Push=gen_server:cast(txstorage, {store_etxs, EmitBTXs}),
  {Push, ET}.

ready4run() ->
  Timestamps=[ Ready || Ready <- lists:sort(
                                   maps:keys(
                                     chainsettings:by_path([<<"current">>,<<"delaytx">>])
                                    )
                                  ),
                        is_integer(Ready),
                        Ready<os:system_time(second)
             ],
  lists:foldl(
    fun(Timestamp, Acc) ->
        Txs=chainsettings:by_path([<<"current">>,<<"delaytx">>,Timestamp]),
        lists:foldl(
          fun([BH, BP, TxID], Acc1) ->
              case blockchain:rel(BP,child) of
                #{header:=#{height:=H},hash:=Hash,etxs:=ETxs} when H==BH ->
                  case lists:keyfind(TxID, 1, ETxs) of
                    {TxID, TxBody} ->
                      Body1=tx:set_ext(origin_height,H,
                                       tx:set_ext(origin_block,Hash,
                                                  TxBody
                                                 )
                                      ),
                      [{TxID, Body1}|Acc1];
                    false ->
                      Acc1
                  end;
                _ ->
                  Acc1
              end
          end, Acc, Txs)
    end, [], Timestamps).


