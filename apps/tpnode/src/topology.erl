-module(topology).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

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
  InitialRelayTick = (rand:uniform(10) * 1000) + InitialTick, % initial relay tick is occurs later up to 10 seconds after InitialTick
  {ok, #{
    timer_announce => erlang:send_after(InitialTick, self(), timer_announce),
    timer_relay => erlang:send_after(InitialRelayTick, self(), timer_relay),
    tickms => TickMs,
    prev_announce => 0,
    prev_relay => 0,
    beacon_cache => #{}
  }}.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({got_beacon2, _PeerID, <<16#be, _/binary>> = Payload}, State) ->
  lager:info("TOPO ~p beacon relay ~p", [_PeerID, Payload]),
  {noreply, State};


handle_cast({got_beacon, _PeerID, <<16#be, _/binary>> = Payload}, #{beacon_cache := Cache} = State) ->
  try
    case beacon:check(Payload) of
      false ->
        lager:info("TOPO can't verify beacon from ~p", [_PeerID]),
        {noreply, State};
      #{from := From} = Beacon ->
        lager:info("TOPO beacon from ~p: ~p", [_PeerID, Beacon]),

        {noreply, State#{
          beacon_cache => add_beacon_to_cache(Beacon, Cache)
        }}
    end
  catch _:_ ->
    lager:error("TOPO ~p beacon check problem for payload ~p", [_PeerID, Payload]),
    {noreply, State}
  end;


handle_cast({got_beacon, _PeerID, _Payload}, State) ->
  lager:error("Bad TPIC beacon received from peer ~p", [_PeerID]),
  {noreply, State};


handle_cast({got_beacon2, _PeerID, _Payload}, State) ->
  lager:error("Bad TPIC beacon received from peer ~p", [_PeerID]),
  {noreply, State};


handle_cast(_Msg, State) ->
  lager:info("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(timer_announce, #{timer_announce:=Tmr, tickms:=Delay} = State) ->
  Now = erlang:system_time(microsecond),
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


handle_info(timer_relay, #{timer_relay:=Tmr, tickms:=Delay} = State) ->
  Now = erlang:system_time(microsecond),
  catch erlang:cancel_timer(Tmr),
  {noreply,
    State#{
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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


% beacon cache format:
% #{ origin => [ list of destinations ]

add_beacon_to_cache(#{to:=Dest, from:=Origin} = _Beacon, Cache) when is_map(Cache)->
  Dests = maps:get(Origin, Cache, []),
  NewDests =
    case lists:member(Dest, Dests) of
      true ->
        Dests;
      false ->
        [Dest | Dests]
    end,
  maps:put(Origin, NewDests, Cache).
