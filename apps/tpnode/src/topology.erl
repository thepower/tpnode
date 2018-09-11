-module(topology).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% This module sends beacons. There are 3 rounds. In the first one, we sends and receives
%% simple beacons (from, to, timestamp). In the second one, we sends collection of beacons
%% from the previous round and receives collections from other nodes. The third round is used
%% for make decision on data from the received collections. The state of the network goes to
%% the ETS storage after the third round.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

-export([state/0]).

-export([get_node/1, get_node/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%-ifndef(TEST).
%%-define(TEST, 1).
%%-endif.
%%
%%-ifdef(TEST).
%%-export([init/2]).
%%-endif.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------


init_common(EtsTableName) ->
  Table = ets:new(EtsTableName, [named_table, protected, bag, {read_concurrency, true}]),
  lager:info("Table created: ~p", [Table]).

%%init(_Args, tests) ->
%%  init_common(),
%%  {ok, #{
%%    tickms => 30,     % tick interval for all 3 rounds
%%    beacon_ttl => 30,     % beacon ttl in seconds for each round validators
%%    node_pub_key => nodekey:get_pub(),  % cached own node id
%%    prev_announce => 0,   % timestamp of last single beacon announce (round 1 send)
%%    prev_relay => 0,      % timestamp of last collection announce (round 2 send)
%%    prev_decide => 0,      % timestamp of last network topology decision (round 3)
%%    beacon_cache => #{},  % beacon collection (round 1 receive, round 2 send), format: #{ origin => {timestamp, binary_beacon_from_round1} }
%%    collection_cache => #{} % collection of beacon collections (round 2 receive, round 3)
%%  }}.
%%



init(Args) ->
  EtsTableName =
    case Args of
      ArgsMap when is_map(ArgsMap) ->
        maps:get(ets_table_name, ArgsMap, ?MODULE);
      _ ->
        ?MODULE
    end,
  
  init_common(EtsTableName),
  
%    gen_server:cast(self(), settings),
  TickMs = 10000, % announce interval
%%  InitialTick = (rand:uniform(10) + 10) * 1000, % initial tick is in period from 10 to 20 seconds from node start
  InitialTick = 1000, % TODO: remove this debug
%%  InitialRelayTick = (rand:uniform(10) * 1000) + InitialTick, % initial relay tick is occurs later up to 10 seconds after InitialTick
  InitialRelayTick = 2000, % TODO: remove this debug
%%  InitialDecideTick = (rand:uniform(10) * 1000) + InitialRelayTick, % initial decide tick is occurs later up to 10 seconds after InitialRelayTick
  InitialDecideTick = 3000, % TODO: remove this debug
  {ok, #{
    ets_table_name => EtsTableName,
    timer_announce => erlang:send_after(InitialTick, self(), timer_announce), % announcer (round 1 send)
    timer_relay => erlang:send_after(InitialRelayTick, self(), timer_relay),  % collection announce (round 2 send)
    timer_decide => erlang:send_after(InitialDecideTick, self(), timer_decide),  % collection announce (round 2 send)
    tickms => TickMs,     % tick interval for all 3 rounds
    beacon_ttl => 30,     % beacon ttl in seconds for each round validators
    node_pub_key => nodekey:get_pub(),  % cached own node id
    prev_announce => 0,   % timestamp of last single beacon announce (round 1 send)
    prev_relay => 0,      % timestamp of last collection announce (round 2 send)
    prev_decide => 0,      % timestamp of last network topology decision (round 3)
    beacon_cache => #{},  % beacon collection (round 1 receive, round 2 send), format: #{ origin => {timestamp, binary_beacon_from_round1} }
    collection_cache => #{} % collection of beacon collections (round 2 receive, round 3)
  }}.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

% handle beacon collection from another node (round 2 receive)
handle_cast(
  {got_beacon2, _PeerID, <<16#be, _/binary>> = PayloadBin},
  #{collection_cache:=Cache} = State) ->
  
  try
    lager:debug("TOPO got beacon relay from ~p : ~p", [_PeerID, PayloadBin]),
    {Me, BeaconTtl, Now} = get_beacon_settings(State, round2),

    BeaconValidator =
      fun
        (#{timestamp := TimeStamp} = _Beacon) when TimeStamp < (Now - BeaconTtl) ->
          lager:error("TOPO: collection validator: too old beacon with timestamp: ~p ~p ~p", [TimeStamp, (Now - BeaconTtl), _Beacon]),
          error;
        (Beacon) when is_map(Beacon) ->
          Beacon;
        (_Invalid) ->
          lager:error("invalid beacon: ~p", [_Invalid]),
          error
      end,
    
    CollectionValidator =
      fun
        (Col4Validate) when is_map(Col4Validate) ->
          maps:filter(
            fun
              % filter expired
              (_Origin, Timestamp) when (Timestamp < (Now - BeaconTtl)) ->
                false;
              % filter nodes from other chains
              (Origin, _Timestamp) ->
                (chainsettings:is_our_node(Origin) =/= false)
            end,
            Col4Validate
          );
        
        (_InvalidCollection) ->
          lager:error("Invalid beacon collection: ~p", [_InvalidCollection]),
          #{}
      end,
      
    Collection =
      case beacon:parse_relayed(PayloadBin) of
        #{collection:=Packed, from:=From, to:=Me} ->
%%          lager:info("TOPO packed beacon relay: ~p", [Packed]),
          case chainsettings:is_our_node(From) of
            false ->
              lager:error("TOPO got beacon collection from wrong node: ~p, ~p", [From, Packed]),
              error;
            _ ->
              case unpack_collection_bin(Packed, BeaconValidator, CollectionValidator) of
                error ->
                  error;
                ValidatedCollection ->
                  % From = Round2From = Round1To
                  % ValidatedCollection = #{Round1From1 => timestamp1, Round1From2 => timestamp2}
                  {From, ValidatedCollection}
              end
          end;
        _Err1 ->
          lager:error("TOPO unmatched parse_relayed: ~p", [_Err1]),
          error
      end,
    lager:debug("TOPO parsed beacon collection: ~p", [Collection]),
    {noreply, State#{
      collection_cache => add_collection_to_cache(Collection, Cache)
    }}
  catch
    pass ->
      {noreply, State};
    Ec:Ee ->
      StackTrace = erlang:get_stacktrace(),
      lager:error("TOPO ~p beacon2 parse problem for payload ~p", [_PeerID, hex:encode(PayloadBin)]),
      lager:error("TOPO ~p:~p", [Ec, Ee]),
      lists:foreach(
        fun(SE) -> lager:error("@ ~p", [SE]) end,
        StackTrace
      ),
      {noreply, State}
  end;

% handle single beacon from another node (round 1 receive)
handle_cast(
  {got_beacon, _PeerID, <<16#be, _/binary>> = Payload},
  #{beacon_cache := Collection, collection_cache := Collection2} = State) ->
  
  try
    {Me, BeaconTtl, Now} = get_beacon_settings(State),
    
    Validator =
      fun
        (#{timestamp := TimeStamp} = _Beacon) when TimeStamp < (Now - BeaconTtl) ->
          lager:error("too old beacon with timestamp: ~p ~p ~p", [TimeStamp, (Now - BeaconTtl), _Beacon]),
          error;
        (#{to := DestNodeId} = _Beacon) when DestNodeId =/= Me ->
          lager:error("wrong destination node: ~p ~p", [DestNodeId, _Beacon]),
          error;
        (Beacon) when is_map(Beacon) ->
          Beacon;
        (_Invalid) ->
          lager:error("invalid beacon: ~p", [_Invalid]),
          error
      end,
    
    case beacon:check(Payload, Validator) of
      #{from := BeaconOrigin, to := Me, timestamp := BeaconTimestamp} = Beacon ->
        lager:debug("TOPO beacon from ~p: ~p", [_PeerID, Beacon]),
        
        {noreply, State#{
          beacon_cache => add_beacon_to_cache(Beacon, Collection),
  
          % also add this beacon to collection of collections
          % Collection2 = #{ {Origin, Round1From1} => timestamp1, {Origin, Round1From1} => timestamp2 }
          % {Origin, Collection} = {Round1To, #{Round1From1 => timestamp1, Round1From2 => timestamp2}}
          collection_cache =>
            add_collection_to_cache({Me, #{BeaconOrigin => BeaconTimestamp}}, Collection2)
        }};
      _ ->
        lager:error("TOPO can't verify beacon from ~p", [_PeerID]),
        {noreply, State}
    end
  catch
    Ec:Ee ->
      StackTrace = erlang:get_stacktrace(),
      EcEe = iolist_to_binary(io_lib:format("~p:~p", [Ec, Ee])),
      lager:error("TOPO ~p beacon check problem for payload ~p", [_PeerID, Payload]),
      lager:error("TOPO ~p ~p", [EcEe, StackTrace]),
      {noreply, State}
  end;


handle_cast({got_beacon, _PeerID, _Payload}, State) ->
  lager:error("Bad TPIC beacon received from peer ~p", [_PeerID]),
  {noreply, State};


handle_cast({got_beacon2, _PeerID, _Payload}, State) ->
  lager:error("Bad TPIC beacon relay received from peer ~p ~p", [_PeerID, _Payload]),
  {noreply, State};


handle_cast(_Msg, State) ->
  lager:error("Unknown cast ~p", [_Msg]),
  {noreply, State}.


% make network topology decision (round 3)
handle_info(timer_decide,
  #{timer_decide:=Tmr,
    tickms:=Delay,
    collection_cache:=Cache,
    ets_table_name:=EtsTableName} = State) ->
  catch erlang:cancel_timer(Tmr),
  {_Me, BeaconTtl, Now} = get_beacon_settings(State, round3),
  
  % Cache = #{ {Origin, Round1From1} => timestamp1, {Origin, Round1From1} => timestamp2 }
  Worker =
    fun
      ({Origin, Dest}, Timestamp, {MatrixAcc, CacheAcc}) when Timestamp>=(Now-BeaconTtl) ->
        DestNodesOld = maps:get(Origin, MatrixAcc, []),
        DestNodesNew =
          case lists:member(Dest, DestNodesOld) of
            true ->
              DestNodesOld;
            _ ->
              [Dest | DestNodesOld]
          end,
        {
          maps:put(Origin, DestNodesNew, MatrixAcc),
          maps:put({Origin, Dest}, Timestamp, CacheAcc)
        };
      (_K, _V, Acc) ->
        lager:debug("TOPO: skip collection member: ~p, ~p", [_K, _V]),
        Acc
    end,
  {Matrix, NewCache} = maps:fold(Worker, {#{}, #{}}, Cache),
  
  lager:debug("TOPO: decision matrix ~p", [
    maps:fold(
      fun(N1, Nodes2, Acc) ->
        maps:put(chainsettings:is_our_node(N1), [chainsettings:is_our_node(N2) || N2 <- Nodes2], Acc)
      end,
      #{},
      Matrix)
  ]),
%%  lager:info("TOPO: decision matrix list ~p", [maps:to_list(Matrix)]),
  
  NetworkState = bron_kerbosch:max_clique(maps:to_list(Matrix)),
  lager:info("TOPO: network state ~p", [[chainsettings:is_our_node(N3) || N3 <- NetworkState] ]),

  nodes_to_ets(NetworkState, EtsTableName),
  
  {noreply,
    State#{
      timer_decide => erlang:send_after(Delay, self(), timer_decide),
      prev_decide => Now,
      collection_cache => NewCache
    }
  };


% announce single beacon to other nodes (round 1 send)
handle_info(timer_announce, #{timer_announce:=Tmr, tickms:=Delay} = State) ->
  Now = erlang:system_time(second),
  catch erlang:cancel_timer(Tmr),
  Peers = tpic:cast_prepare(tpic, <<"mkblock">>),
  lists:foreach(
    fun
      ({Peer, #{authdata:=AD}}) ->
        DstNodePubKey = proplists:get_value(pubkey, AD, <<>>),
        lager:debug("TOPO sent ~p: ~p", [Peer, DstNodePubKey]),
        tpic:cast(
          tpic,
          Peer,
          {<<"beacon">>, beacon:create(DstNodePubKey)}
        );
      (_) -> ok
    end,
    Peers),
  
  {noreply,
    State#{
      timer_announce => erlang:send_after(Delay, self(), timer_announce),
      prev_announce => Now
    }
  };

% announce beacon collection to other nodes (round 2 send)
handle_info(timer_relay, #{timer_relay:=Tmr, tickms:=Delay, beacon_cache:=Cache} = State) ->
  Now = erlang:system_time(second),
  catch erlang:cancel_timer(Tmr),
  Collection =
    maps:fold(
      fun
        (_Origin,{_Timestamp, BinBeacon}, Acc) ->
          [BinBeacon | Acc];
        (_Origin, _Invalid, Acc) ->
          Acc
      end,
      [],
      Cache
    ),
  {noreply,
    State#{
      beacon_cache => relay_beacons(Collection),
      timer_relay => erlang:send_after(Delay, self(), timer_relay),
      prev_relay => Now
    }
  };


handle_info(_Info, State) ->
  lager:info("Unknown info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


state() ->
  gen_server:call(?MODULE, state).


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


% adds one beacon to collection (round 1 receive)
% beacon collection format:
% #{ origin => {timestamp, binary_beacon_from_round1} }
add_beacon_to_cache(#{timestamp:=Timestamp, from:=Origin, bin:=Bin} = _Beacon, Collection) when is_map(Collection) ->
%%  add_or_update_item(Origin, Timestamp, Collection);
  case maps:find(Origin, Collection) of
    error ->
      maps:put(Origin, {Timestamp, Bin}, Collection); % new item
    {ok, {OldTimestamp, _}} when OldTimestamp < Timestamp ->
      maps:put(Origin, {Timestamp, Bin}, Collection); % update old item
    {ok, _} ->
      Collection % don't touch anything
  end;


add_beacon_to_cache(_Beacon, _Collection) ->
  lager:error("invalid beacon: ~p", [_Beacon]).


%% ------------------------------------------------------------------

add_collection_to_cache(error, Cache) ->
  Cache;

% {Origin, Collection} = {Round1To, #{Round1From1 => timestamp1, Round1From2 => timestamp2}}
% Cache = #{ {Origin, Round1From1} => timestamp1, {Origin, Round1From1} => timestamp2 }
add_collection_to_cache({Origin, Collection}, Cache) when is_map(Collection) andalso is_map(Cache) ->
  Updater =
    fun
      (NodeId, Timestamp, CacheIn) ->
        Key = {Origin, NodeId},
        add_or_update_item(Key, Timestamp, CacheIn)
    end,
  
  maps:fold(Updater, Cache, Collection);

add_collection_to_cache(_Invalid, Cache) ->
  lager:error("TOPO: invalid collection: ~p", [_Invalid]),
  Cache.
  
%% ------------------------------------------------------------------

% relays beacon collection to all peers (round 2 send)
relay_beacons([]) ->
  #{};

relay_beacons(Collection) when is_list(Collection) ->
  Peers = tpic:cast_prepare(tpic, <<"mkblock">>),
  Payload = msgpack:pack(Collection, [{spec, new}]),
  lists:foreach(
    fun
      ({Peer, #{authdata:=AD}}) ->
        lager:debug("TOPO sending beacon collection to peer ~p", [Peer]),
        DstNodePubKey = proplists:get_value(pubkey, AD, <<>>),
        tpic:cast(
          tpic,
          Peer,
          {<<"beacon2">>, beacon:relay(DstNodePubKey, Payload)}
        );
      (_) -> ok
    end,
    Peers),
  #{}.


%% ------------------------------------------------------------------

get_beacon_settings(State, round2) ->
  {Me, BeaconTtl, Now} = get_beacon_settings(State),
  {Me, BeaconTtl * 2 + 2, Now};

get_beacon_settings(State, round3) ->
  {Me, BeaconTtl, Now} = get_beacon_settings(State),
  {Me, BeaconTtl * 3 + 3, Now}.

get_beacon_settings(State) ->
  Me = case maps:get(node_pub_key, State, unknown) of
    unknown ->
      nodekey:get_pub();
    NodeKey ->
      NodeKey
  end,
  
  BeaconTtl = maps:get(beacon_ttl, State, 30),
  Now = os:system_time(seconds),
  
  {Me, BeaconTtl, Now}.


%% ------------------------------------------------------------------

% add or update item for collection of format #{ Key => Timestamp }
add_or_update_item(Key, Timestamp, Collection) when is_map(Collection) ->
  case maps:find(Key, Collection) of
    error ->
      maps:put(Key, Timestamp, Collection); % new item
    {ok, OldTimestamp} when OldTimestamp < Timestamp ->
      maps:put(Key, Timestamp, Collection); % update old item
    {ok, _} ->
      Collection % don't touch anything
  end.


%% ------------------------------------------------------------------

unpack_collection_bin(Packed, BeaconValidator, CollectionValidator) when is_binary(Packed) ->
  case msgpack:unpack(Packed, [{spec, new}]) of
    {ok, BinBeacons} ->
      lager:debug("TOPO: bin beacons: ~p", [BinBeacons]),
      
      Worker =
        fun
          (Beacon, Acc) when is_binary(Beacon)->
            case beacon:check(Beacon, BeaconValidator) of
              #{from := Round1From, timestamp := Round1Timestamp} ->
                maps:put(Round1From, Round1Timestamp, Acc);
              _ ->
                Acc
            end;
          (_, Acc) ->
            Acc
        end,
      % Collection = #{Round1From1 => timestamp1, Round1From2 => timestamp2}
      Collection = lists:foldl(Worker, #{}, BinBeacons),
      CollectionValidator(Collection);
    Err ->
      lager:error("can't unpack msgpack: ~p", [Err]),
      error
  end.




%% ------------------------------------------------------------------

%%nodes_to_ets(Nodes) when is_list(Nodes) ->
%%  nodes_to_ets(Nodes, ?MODULE).

nodes_to_ets(Nodes, EtsTableName) when is_list(Nodes) ->
  Ver = os:system_time(seconds),
  ets:insert(EtsTableName, [{Node, Ver} || Node <- Nodes]),
  ets:select_delete(
    EtsTableName,
    [{{'_', '$1'}, [{'<', '$1', Ver}], [true]}]
  ),
  ok.

%% ------------------------------------------------------------------

get_node(Node) ->
  get_node(Node, ?MODULE).


get_node(Node, EtsTableName) ->
  case ets:lookup(EtsTableName, Node) of
    [{Node, TimestampVer}] ->
      {ok, TimestampVer};
    [] ->
      error
  end.




