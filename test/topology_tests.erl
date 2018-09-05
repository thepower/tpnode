-module(topology_tests).

-include_lib("eunit/include/eunit.hrl").

-export([handle_info/2]).


get_nodes() ->
  #{
    node1 => <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
      240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 1, 1>>,
    node2 => <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
      240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 2, 2>>,
    node3 => <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
      240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 3, 3>>,
    node4 => <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
      240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 4, 4>>,
    node5 => <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
      240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 5, 5>>
  }.

% ------------------------------------------------------------------------

get_node_names() ->
  Nodes = get_nodes(),
  maps:keys(Nodes).

% ------------------------------------------------------------------------

beacon_loss_test() ->
  % init emulator
  init_emulator(),

  % send beacons round1
  Nodes = get_node_names(),
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_announce)
    end,
    Nodes
  ),

  % drop packets for the first node on the list
  BrokenTo = hd(Nodes),
  
%%  _Dropped = drop_packets(BrokenTo, 1),
  [{BrokenFrom, _}] = drop_packets(BrokenTo, 1),
  
  % receive beacons round1
  process_packets(fun send_cast/1),
  
  % send collections round2
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_relay)
    end,
    Nodes
  ),
  
  % receive collections round2
  process_packets(fun send_cast/1),
  
  % make decision round3
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_decide)
    end,
    Nodes
  ),
  
  % at this point the network should think that BrokenFrom haven't full connectivity
%%  error_logger:info_msg("Broken node: ~p", [BrokenFrom]),
  
  % check matrix
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      lists:foreach(
        fun(NodeName1) ->
          EtsTableName = NodeName,
          Status = topology:get_node(get_pub(NodeName1), EtsTableName),
%%          error_logger:info_msg("Node ~p request ~p state ~p", [NodeName, NodeName1, Status]),
          if
            NodeName1 =:= BrokenFrom ->
              ?assertEqual(error, Status);   % node haven't full connectivity
            true ->
              ?assertMatch({ok, _}, Status)  % node have full connectivity
          end
        end,
        Nodes
      )
    end,
    Nodes
  ),
  
  % cleanup
  cleanup_emulator().

% ------------------------------------------------------------------------

collection_loss_test() ->
  % init emulator
  init_emulator(),
  
  % send beacons round1
  Nodes = get_node_names(),
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_announce)
    end,
    Nodes
  ),
  
  % receive beacons round1
  process_packets(fun send_cast/1),
  
  % send collections round2
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_relay)
    end,
    Nodes
  ),
  
  % drop packets for the first node on the list
  BrokenTo = hd(Nodes),

%%  _Dropped = drop_packets(BrokenTo, 1),
  [{BrokenFrom, _}] = drop_packets(BrokenTo, 1),
  
  % receive collections round2
  process_packets(fun send_cast/1),
  
  % make decision round3
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_decide)
    end,
    Nodes
  ),
  
  % at this point the network should think that BrokenFrom haven't full connectivity
%%  error_logger:info_msg("Skipped packet from ~p to ~p", [BrokenFrom, BrokenTo]),
  
  % check matrix
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      lists:foreach(
        fun(NodeName1) ->
          EtsTableName = NodeName,
          Status = topology:get_node(get_pub(NodeName1), EtsTableName),
%%          error_logger:info_msg("Node ~p request ~p state ~p", [NodeName, NodeName1, Status]),
          if
            NodeName1 =:= BrokenFrom andalso NodeName =:= BrokenTo ->
              ?assertEqual(error, Status);   % node haven't full connectivity
            true ->
              ?assertMatch({ok, _}, Status)  % node have full connectivity
          end
        end,
        Nodes
      )
    end,
    Nodes
  ),
  
  % cleanup
  cleanup_emulator().

% ------------------------------------------------------------------------


success_path_test() ->
  % init emulator
  init_emulator(),
  % send beacons round1
  Nodes = get_node_names(),
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_announce)
    end,
    Nodes
  ),
  
  % receive beacons round1
  process_packets(fun send_cast/1),
  
  % send collections round2
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_relay)
    end,
    Nodes
  ),
  
  % receive collections round2
  process_packets(fun send_cast/1),
  
  % make decision round3
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      send_info(timer_decide)
    end,
    Nodes
  ),

%%  show_states(),
  
  % check matrix
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      % all nodes should be in matrix
      lists:foreach(
        fun(NodeName1) ->
          EtsTableName = NodeName,
          Status = topology:get_node(get_pub(NodeName1), EtsTableName),
%%          error_logger:info_msg("Node ~p request ~p state ~p", [NodeName, NodeName1, Status]),
          ?assertNotEqual(error, Status),
          ?assertMatch({ok, _}, Status)
        end,
        Nodes
      )
    end,
    Nodes
  ),
  
  % cleanup
  cleanup_emulator().


% ------------------------------------------------------------------------

drop_packets(BrokenTo, PacketsCount) ->
  #{net:= Net} = EmulatorState = get(emulator_state),
  
  PacketQueue =  maps:get(BrokenTo, Net, []),
  {NewPacketQueue, AllSkippedPackets, _} =
    lists:foldl(
      fun
        ({_From, _} = Packet, {NewQueue, SkippedPackets, SkippedCount})
          when (SkippedCount < PacketsCount) ->
%%            error_logger:info_msg("Skip packet from ~p to ~p", [_From, BrokenTo]),
            {NewQueue, SkippedPackets ++ [Packet], SkippedCount+1};
        (Packet, {NewQueue, SkippedPackets, SkippedCount}) ->
          {NewQueue ++ [Packet], SkippedPackets, SkippedCount}
      end,
      {[], [], 0},
      PacketQueue
    ),
  
  NewNet = maps:put(BrokenTo, NewPacketQueue, Net),

%%  error_logger:info_msg("Skipped packets: ~p", [AllSkippedPackets]),
  
  put(emulator_state, EmulatorState#{ net => NewNet }),
  AllSkippedPackets.

% ------------------------------------------------------------------------

unmeck_all() ->
  meck:unload(nodekey),
  meck:unload(tpic),
  meck:unload(chainsettings).

% ------------------------------------------------------------------------

meck_it_all() ->
  meck:new(nodekey),
  meck:expect(
    nodekey,
    get_priv,
    fun get_current_priv/0
  ),
  meck:expect(
    nodekey,
    get_pub,
    fun get_current_pub/0
  ),
  meck:new(tpic),
  meck:expect(
    tpic,
    cast_prepare,
    fun tpic_cast_prepare/2
  ),
  meck:expect(
    tpic,
    cast,
    fun tpic_cast/3
  ),
  meck:new(chainsettings),
  meck:expect(
    chainsettings,
    is_our_node,
    fun chainsettings_is_our_node/1
  ).

% ------------------------------------------------------------------------

init_emulator() ->
  NodeNames = get_node_names(),
  
  Data =
    #{
      states => #{},  % nodekey => state
      net => #{},     % nodekey => queue of incoming network packets
      current_node => hd(NodeNames) % active node
    },
  
  put(emulator_state, Data),
  meck_it_all(),
  init_states().

% ------------------------------------------------------------------------


init_states() ->
  NodeNames = get_node_names(),
  lists:foreach(
    fun(NodeName) ->
      switch_node(NodeName),
      {ok, State} = topology:init(#{ets_table_name => NodeName}),
      set_state(State)
    end,
    NodeNames
  ).

% ------------------------------------------------------------------------

cleanup_emulator() ->
  Nodes = get_node_names(),
  [ ets:delete(Table) || Table <- Nodes ], % remove
  erase(),  % remove process dictionary
  unmeck_all().

% ------------------------------------------------------------------------

tpic_cast_prepare(tpic, <<"mkblock">>) ->
%%  error_logger:info_msg("catch tpic cast prepare"),
  Nodes = get_nodes(),
  CurrentNode = get_current_node_name(),

%%  [ {node1, #{authdata => [{pubkey, <<"key1">>}]} } ]
  maps:fold(
    fun
      (NodeName, _Priv, Acc) when NodeName =:= CurrentNode ->  % don't make self association
        Acc;
      (NodeName, Priv, Acc) ->
      Pub = tpecdsa:calc_pub(Priv, true),
      [ {NodeName, #{authdata => [{pubkey, Pub}]} } | Acc ]
    end,
    [],
    Nodes
  ).

% ------------------------------------------------------------------------

tpic_cast(tpic, Peer, Payload) ->
%%  error_logger:info_msg("send to ~p payload ~p", [Peer, Payload]),
  send_packet(Peer, Payload).

% ------------------------------------------------------------------------

get_state() ->
  #{current_node := NodeName, states := States} = get(emulator_state),
  maps:get(NodeName, States, #{}).

%%get_state(NodeName) ->
%%  #{states := States} = get(emulator_state),
%%  maps:get(NodeName, States, #{}).

% ------------------------------------------------------------------------

set_state(NewState) ->
  #{current_node := NodeName, states := States} = EmulatorState = erlang:get(emulator_state),
  erlang:put(
    emulator_state,
    EmulatorState#{ states => maps:put(NodeName, cancel_timers(NewState), States) }
  ).

%%set_state(NodeName, NewState) ->
%%  #{states := States} = EmulatorState = get(emulator_state),
%%  erlang:put(
%%    emulator_state,
%%    EmulatorState#{ states => maps:put(NodeName, cancel_timers(NewState), States) }
%%  ).

% ------------------------------------------------------------------------

get_current_priv() ->
  Nodes = get_nodes(),
  #{current_node := NodeName} = get(emulator_state),
  maps:get(NodeName, Nodes).

% ------------------------------------------------------------------------

get_current_pub() ->
  Priv = get_current_priv(),
  tpecdsa:calc_pub(Priv, true).

% ------------------------------------------------------------------------

get_pub(NodeName) ->
  Nodes = get_nodes(),
  Priv = maps:get(NodeName, Nodes),
  tpecdsa:calc_pub(Priv, true).


% ------------------------------------------------------------------------

switch_node(NewNode) ->
%%  application:unset_env(tpnode, pubkey),
  EmulatorState = get(emulator_state),
  put(emulator_state, EmulatorState#{ current_node => NewNode }).

% ------------------------------------------------------------------------

get_current_node_name() ->
  #{ current_node := CurrentNode } = get(emulator_state),
  CurrentNode.

% ------------------------------------------------------------------------

cancel_timers(State) ->
  Timers = [timer_announce, timer_relay, timer_decide],
  
  maps:map(
    fun(Key, Value) ->
      case lists:member(Key, Timers) of
        true when is_reference(Value) ->
          catch erlang:cancel_timer(Value),
          unknown;
        _ ->
          Value
      end
    end,
    State
  ).

% catch timers
handle_info(timer_announce, State) ->
  {noreply, cancel_timers(State) };

handle_info(timer_relay, State) ->
  {noreply, cancel_timers(State) };

handle_info(timer_decide, State) ->
  {noreply, cancel_timers(State) }.


% ------------------------------------------------------------------------

send_packet(NodeName, Payload) ->
  #{current_node := From, net := Net} = EmulatorState = get(emulator_state),
  Queue = maps:get(NodeName, Net, []),
  put(
    emulator_state,
    EmulatorState#{ net => maps:put(NodeName, Queue ++ [ {From, Payload} ], Net) }
  ).


% ------------------------------------------------------------------------

process_packets(Receiver) ->
  #{net := Net} = get(emulator_state),
  NewNet =
    maps:map(
      fun(NodeName, Queue) ->
        switch_node(NodeName),
%%        error_logger:info_msg("packets queue for node ~p ~n ~p", [NodeName, Queue]),
        lists:foreach(Receiver, Queue),
        []
      end,
      Net
    ),
  EmulatorState = get(emulator_state),
  put(
    emulator_state,
    EmulatorState#{ net => NewNet }
  ).


% ------------------------------------------------------------------------

send_cast({From, {Service, Payload}}) ->
  State = get_state(),
  % {got_beacon, _PeerID, <<16#be, _/binary>> = Payload}
  Service2 =
    case Service of
      <<"beacon">> ->
        got_beacon;
      <<"beacon2">> ->
        got_beacon2
    end,
  
  {noreply, NewState} = topology:handle_cast({Service2, From, Payload}, State),
  
  set_state(NewState).

% ------------------------------------------------------------------------

send_info(Payload) ->
  State = get_state(),
  {noreply, NewState} = topology:handle_info(Payload, State),
  set_state(NewState).

% ------------------------------------------------------------------------

%%show_states() ->
%%  lists:foreach(
%%    fun(NodeName) ->
%%      State = get_state(NodeName),
%%      error_logger:info_msg("state ~p ~n ~p", [NodeName, State])
%%    end,
%%    get_node_names()
%%  ).

% ------------------------------------------------------------------------

chainsettings_is_our_node(PubKey) ->
  maps:fold(
    fun(NodeName, PrivKey, Acc) ->
      NodePubKey = tpecdsa:calc_pub(PrivKey, true),
      case NodePubKey of
        PubKey ->
          NodeName;
        _ ->
          Acc
      end
    end,
    error,
    get_nodes()
  ).
