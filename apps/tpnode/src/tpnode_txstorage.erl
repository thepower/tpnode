-module(tpnode_txstorage).
-include("include/tplog.hrl").

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([get_tx/1, get_tx/2, get_unpacked/1, exists/1]).
-export([get_txm/1, get_txm/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
  Name=maps:get(name,Args,txstorage),
  gen_server:start_link({local, Name}, ?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init_table(EtsTableName) ->
  Table =
    ets:new(
      EtsTableName,
      [named_table, protected, set, {read_concurrency, true}]
    ),
  ?LOG_INFO("Table created: ~p", [Table]).

init(Args) ->
  EtsTableName = maps:get(ets_name, Args, txstorage),
  init_table(EtsTableName),
  {ok, #{
    expire_tick_ms => 1000 * maps:get(expire_check_sec, Args, 60), % default: 1 minute
    timer_expire => erlang:send_after(10*1000, self(), timer_expire), % first timer fires after 10 seconds
    ets_name => EtsTableName,
    my_ttl => maps:get(my_ttl, Args, 30*60),  % default: 30 min
    ets_ttl_sec => maps:get(ets_ttl_sec, Args, 20*60)  % default: 20 min
  }}.

handle_call(#{ null := <<"txsync_refresh">>, <<"txid">> := TxID}, _From, State) ->
  case refresh_tx(TxID, State) of
    {ok, State2} ->
      {reply, ok, State2};
    not_found ->
      {reply, {error,not_found}, State}
  end;

handle_call(#{from:=FromPubKey, null := <<"txsync_push">>, <<"txid">> := TxID, <<"body">> := TxBin}, _From, State) ->
  case store_tx(TxID, TxBin, FromPubKey, State) of
    {ok, State2} ->
      {reply, ok, State2};
    {error, body_mismatch} ->
      {reply, {error,body_mismatch}, State}
  end;

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(get_table_name, _From, #{ets_name:=EtsName} = State) ->
  {reply, EtsName, State};

handle_call({new_tx, TxID, TxBin}, _From, State) ->
  case new_tx(TxID, TxBin, sync, State) of
    {ok, S1} ->
      {reply, ok, S1};
    Any ->
      ?LOG_ERROR("Can't add tx: ~p",[Any]),
      {reply, {error, Any}, State}
  end;

handle_call(_Request, _From, State) ->
  ?LOG_NOTICE("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast({tpic, FromPubKey, Peer, PayloadBin}, State) ->
  ?LOG_DEBUG( "txstorage got txbatch from ~p payload ~p", [ FromPubKey, PayloadBin]),
  case msgpack:unpack(PayloadBin, [ {unpack_str, as_binary} ]) of
    {ok, MAP} ->
      case handle_tpic(MAP, FromPubKey, State) of
        {noreply, State1} ->
          {noreply, State1};
        {reply, Reply, State1} ->
          tpic2:cast(Peer, msgpack:pack(Reply)),
          {noreply, State1}
      end;
    _ ->
      ?LOG_ERROR("txstorage can't unpack msgpack: ~p", [ PayloadBin ]),
      {noreply, State}
  end;

handle_cast({store_etxs, Txs}, State) ->
  S1=lists:foldl(
    fun({TxID, TxBin},A) ->
        case new_tx(TxID, TxBin, nosync, A) of
          {ok, S1} ->
            ?LOG_INFO("Store Injected tx ~p",[TxID]),
            S1;
          Any ->
            ?LOG_ERROR("Can't add tx: ~p",[Any]),
            State
        end
    end, State, Txs),
  {noreply, S1};

handle_cast(_Msg, State) ->
  ?LOG_NOTICE("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(timer_expire,
  #{ets_name:=EtsName, timer_expire:=Tmr, expire_tick_ms:=Delay} = State) ->

  catch erlang:cancel_timer(Tmr),
  ?LOG_DEBUG("remove expired records"),
  Now = os:system_time(second),
  ets:select_delete(
    EtsName,
    [{{'_', '_', '_', '_', '$1'}, [{'<', '$1', Now}], [true]}]
  ),
  {noreply,
    State#{
      timer_expire => erlang:send_after(Delay, self(), timer_expire)
    }
  };

handle_info({txsync_done, true, TxID, Peers}, State) ->
  case update_tx_peers(TxID, Peers, State) of
    {ok, S1} ->
      ?LOG_INFO("Tx ~p ready",[TxID]),
      gen_server:cast(txqueue, {push_tx, TxID}),
      {noreply, S1};
    Any ->
      ?LOG_ERROR("Can't update peers for tx ~p: ~p",[TxID,Any]),
      {noreply, State}
  end;

handle_info({txsync_done, false, TxID, _Peers}, State) ->
  ?LOG_NOTICE("Tx ~s sync failed, insufficient peers ~p",[TxID,_Peers]),
  gen_server:cast(txstatus, {done, false, [{TxID, insufficient_nodes_confirmed}]}),
  {noreply, State};

handle_info(_Info, State) ->
  ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
  {noreply, State}.

handle_tpic(#{ null := <<"txsync_refresh">>, <<"txid">> := TxID}, _FromPubKey, State) ->
  case refresh_tx(TxID, State) of
    {ok, State2} ->
      {reply, #{
         null => <<"txsync_refresh_res">>,
         <<"res">> => <<"ok">>,
         <<"txid">> => TxID
        }, State2};
    not_found ->
      {reply, #{
         null => <<"txsync_refresh_res">>,
         <<"res">> => <<"error">>,
         <<"txid">> => TxID
        }, State}
  end;

handle_tpic(#{ null := <<"txsync_push">>, <<"txid">> := TxID, <<"body">> := TxBin}, FromPubKey, State) ->
  case store_tx(TxID, TxBin, FromPubKey, State) of
    {ok, State2} ->
      {reply, #{
         null => <<"txsync_res">>,
         <<"res">> => <<"ok">>,
         <<"txid">> => TxID
        }, State2}
  end;

handle_tpic(_, _, State) ->
  {reply, #{ null => <<"unknown_command">> }, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
update_tx_peers(TxID, Peers, #{ets_name:=Table} = State) ->
  case ets:lookup(Table, TxID) of
    [{TxID, TxBody, FromPeer, _, ValidUntil}] ->
      ets:insert(Table, {TxID, TxBody, FromPeer, Peers, ValidUntil}),
      {ok, State};
    [] ->
      not_found
  end.

refresh_tx(TxID, #{ets_ttl_sec:=TTL, ets_name:=Table} = State) ->
  case ets:lookup(Table, TxID) of
    [{TxID, TxBody, FromPeer, Nodes, _ValidUntil}] ->
      ValidUntil = os:system_time(second) + TTL,
      ets:insert(Table, {TxID, TxBody, FromPeer, Nodes, ValidUntil}),
      {ok, State};
    [] ->
      not_found
  end.

new_tx(TxID, TxBody, nosync, #{my_ttl:=TTL, ets_name:=Table} = State) ->
  ValidUntil = os:system_time(second) + TTL,
  ets:insert(Table, {TxID, TxBody, me, [], ValidUntil}),
  {ok, State};


new_tx(TxID, TxBody, sync, #{my_ttl:=TTL, ets_name:=Table} = State) ->
  ValidUntil = os:system_time(second) + TTL,
  ?LOG_ERROR("Store tx ~p",[TxID]),
  case application:get_env(tpnode,store_txs_path) of
    {ok,L} when is_list(L) ->
      ?LOG_ERROR("save tx ~p: ~p",[filename:join(L,TxID),
                                   file:write_file(filename:join(L,TxID),TxBody)]);
    _ -> ok
  end,
  ets:insert(Table, {TxID, TxBody, me, [], ValidUntil}),
  MS=chainsettings:get_val(minsig,30),
  %chainsettings:by_path([<<"current">>,<<"chain">>,<<"minsig">>]),
  true=is_integer(MS),
  case length(nodekey:get_privs()) >= MS of
    true ->
      tpnode_txsync:synchronize(TxID, #{min_peers=>0});
    false ->
      tpnode_txsync:synchronize(TxID, #{min_peers=>max(MS-1,0)})
  end,
  {ok, State}.

store_tx(TxID, TxBody, FromPeer, #{ets_ttl_sec:=TTL, ets_name:=Table} = State) ->
  ValidUntil = os:system_time(second) + TTL,
  ?LOG_ERROR("Store tx ~p",[TxID]),
  case ets:lookup(Table, TxID) of
    [] ->
      case application:get_env(tpnode,store_txs_path) of
        {ok,L} when is_list(L) ->
          ?LOG_ERROR("save tx ~p: ~p",[filename:join(L,TxID),
                                file:write_file(filename:join(L,TxID),TxBody)]);
        _ -> ok
      end,
      ets:insert(Table, {TxID, TxBody, FromPeer, [], ValidUntil}),
      {ok, State};
    [{TxID, TxBody1, _, _, _}] when TxBody1 =/= TxBody ->
      {error, body_mismatch};
    [{TxID, _TxBody, me, Nodes, _ValidUntil1}] ->
      ets:insert(Table, {TxID, TxBody, me, Nodes, ValidUntil}),
      {ok, State};
    [{TxID, _TxBody, _Origin, _Nodes, _ValidUntil1}] ->
      ets:insert(Table, {TxID, TxBody, FromPeer, [], ValidUntil}),
      {ok, State}
  end.

get_unpacked(TxID) ->
  case ets:lookup(txstorage, TxID) of
    [{TxID, Tx, Origin, _Nodes, _ValidUntil}] ->
      UTX=if(Origin==me) ->
          tx:unpack(Tx,[trusted]);
        true ->
          tx:unpack(Tx)
      end,
      {TxID, UTX};
    [] ->
      error
  end.

get_txm(TxID) ->
  get_txm(TxID, txstorage).

get_tx(TxID) ->
  get_tx(TxID, txstorage).

exists(TxID) ->
  case ets:lookup(txstorage, TxID) of
    [{TxID, _Tx, _Origin, _Nodes, ValidUntil1}] ->
      Now=os:system_time(second),
      if(ValidUntil1 > Now+10) ->
          true;
        true ->
          expiring
      end;
    [] ->
      false
  end.

get_tx(TxID, Table) ->
  case ets:lookup(Table, TxID) of
    [{TxID, Tx, _Origin, Nodes, _ValidUntil}] ->
      {ok, {TxID, Tx, Nodes}};
    [] ->
      error
  end.

get_txm(TxID, Table) ->
  case ets:lookup(Table, TxID) of
    [{TxID, Tx, Origin, Nodes, ValidUntil}] ->
      {ok, #{id=>TxID,
            body=>Tx,
            origin=>Origin,
            nodes=>Nodes,
            valid=>ValidUntil}};
    [] ->
      error
  end.

