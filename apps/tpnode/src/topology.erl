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

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([state/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
%    gen_server:cast(self(), settings),
  TickMs = 10000, % announce interval
%%  InitialTick = (rand:uniform(10) + 10) * 1000, % initial tick is in period from 10 to 20 seconds from node start
  InitialTick = 1000, % TODO: remove this debug
%%  InitialRelayTick = (rand:uniform(10) * 1000) + InitialTick, % initial relay tick is occurs later up to 10 seconds after InitialTick
  InitialRelayTick = 2000, % TODO: remove this debug
%%  InitialDecideTick = (rand:uniform(10) * 1000) + InitialRelayTick, % initial decide tick is occurs later up to 10 seconds after InitialRelayTick
  InitialDecideTick = 3000, % TODO: remove this debug
  {ok, #{
    timer_announce => erlang:send_after(InitialTick, self(), timer_announce), % announcer (round 1 send)
    timer_relay => erlang:send_after(InitialRelayTick, self(), timer_relay),  % collection announce (round 2 send)
    timer_decide => erlang:send_after(InitialDecideTick, self(), timer_decide),  % collection announce (round 2 send)
    tickms => TickMs,     % tick interval for all 3 rounds
    beacon_ttl => 30,     % beacon ttl in seconds for each round validators
    node_pub_key => nodekey:get_pub(),  % cached own node id
    prev_announce => 0,   % timestamp of last single beacon announce (round 1 send)
    prev_relay => 0,      % timestamp of last collection announce (round 2 send)
    prev_decide => 0,      % timestamp of last network topology decision (round 3)
    beacon_cache => #{},  % beacon collection (round 1 receive, round 2 send)
    collection_cache => #{} % collection of beacon collections (round 2 receive, round 3)
  }}.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

% handle beacon collection from another node (round 2 receive)
handle_cast({got_beacon2, _PeerID, <<16#be, _/binary>> = PayloadBin}, #{collection_cache:=Cache}=State) ->
  try
    lager:info("TOPO got beacon relay from ~p : ~p", [_PeerID, PayloadBin]),
    {Me, BeaconTtl, Now} = get_beacon_settings(State),
    
    CollectionValidator =
      fun
        (Col4Validate) when is_map(Col4Validate) ->
          maps:filter(
            fun(_Origin, Timestamp) ->
              (Timestamp >= (Now - BeaconTtl))
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
          lager:info("TOPO packed beacon relay: ~p", [Packed]),
          case msgpack:unpack(Packed, [{spec, new}]) of
            {ok, Unpacked} ->
              lager:info("TOPO: before validate: ~p", [Unpacked]),
              % Unpacked = #{Round1From1 => timestamp1, Round1From2 => timestamp2}
              ValidatedCollection = CollectionValidator(Unpacked),
              % From = Round2From = Round1To
              % {Round1To, #{Round1From1 => timestamp1, Round1From2 => timestamp2}}
              {From, ValidatedCollection};
            Err ->
              lager:error("can't unpack msgpack: ~p", [Err]),
              error
          end;
        Err1 ->
          lager:error("TOPO unmatched parse_relayed: ~p", [Err1]),
          Err1
      end,
    lager:info("TOPO parsed beacon collection: ~p", [Collection]),
    {noreply, State#{
      collection_cache => add_collection_to_cache(Collection, Cache)
    }}
  catch
    Ec:Ee ->
      StackTrace = erlang:get_stacktrace(),
      EcEe = iolist_to_binary(io_lib:format("~p:~p", [Ec, Ee])),
      lager:error("TOPO ~p beacon2 parse problem for payload ~p", [_PeerID, PayloadBin]),
      lager:error("TOPO ~p ~p", [EcEe, StackTrace]),
      {noreply, State}
  end;

% handle single beacon from another node (round 1 receive)
handle_cast({got_beacon, _PeerID, <<16#be, _/binary>> = Payload}, #{beacon_cache := Collection} = State) ->
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
      false ->
        lager:info("TOPO can't verify beacon from ~p", [_PeerID]),
        {noreply, State};
      Beacon ->
        lager:info("TOPO beacon from ~p: ~p", [_PeerID, Beacon]),
        
        {noreply, State#{
          beacon_cache => add_beacon_to_cache(Beacon, Collection)
        }}
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
handle_info(timer_decide, #{timer_decide:=Tmr, tickms:=Delay, collection_cache:=Cache} = State) ->
  catch erlang:cancel_timer(Tmr),
  {_Me, BeaconTtl, Now} = get_beacon_settings(State),

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
  
  lager:info("TOPO: decision matrix ~p", [Matrix]),
  lager:info("TOPO: decision matrix list ~p", [ maps:to_list(Matrix) ]),
  
  NetworkState = bron_kerbosch:max_clique(maps:to_list(Matrix)),
  
  lager:info("TOPO: network state ~p", [ NetworkState ]),
  
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
        lager:info("TOPO sent ~p: ~p", [Peer, DstNodePubKey]),
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
  {noreply,
    State#{
      beacon_cache => relay_beacons(Cache),
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
% #{ origin => timestamp }
add_beacon_to_cache(#{timestamp:=Timestamp, from:=Origin} = _Beacon, Collection) when is_map(Collection) ->
  add_or_update_item(Origin, Timestamp, Collection);

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
relay_beacons(Collection) ->
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
