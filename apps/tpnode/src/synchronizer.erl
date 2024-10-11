-module(synchronizer).
-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok, #{
    myoffset => undefined,
    offsets => #{},
    timer5 => erlang:send_after(5000, self(), selftimer5),
    ticktimer => erlang:send_after(6000, self(), ticktimer),
    tickms => 10000,
    prevtick => 0,
    mychain => 0
  }}.

handle_call(peers, _From, #{offsets:=Offs} = State) ->
  Friends = maps:keys(Offs),
  {reply, Friends, State};

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(settings, State) ->
  {noreply, load_settings(State)};


handle_cast({tpic, _PeerID, Payload}, State) ->
  case msgpack:unpack(Payload) of
    {ok, #{null:=<<"hello">>, <<"n">>:=Node, <<"t">>:=T}} ->
      handle_cast({hello, Node, T}, State);
    Any ->
      ?LOG_INFO("Bad TPIC received ~p", [Any]),
      {noreply, State}
  end;


handle_cast({hello, PID, WallClock}, State) ->
  Behind = erlang:system_time(microsecond) - WallClock,
  ?LOG_DEBUG("Hello from ~p our clock diff ~p", [PID, Behind]),
  {noreply, State#{
    offsets => maps:put(
      PID,
      {Behind, erlang:system_time(seconds)},
      maps:get(offsets, State, #{})
    )
  }};

handle_cast({setdelay, Ms}, State) when Ms > 900 ->
  ?LOG_INFO("Setting ~p ms block delay", [Ms]),
  {noreply, State#{
    tickms => Ms
  }};

handle_cast(_Msg, State) ->
  ?LOG_INFO("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(imready, State) ->
  {noreply, State#{ bcready => true }};

handle_info(ticktimer,
  #{ticktimer:=Tmr, tickms:=Delay, prevtick:=_T0} = State) ->
  
  catch erlang:cancel_timer(Tmr),
  
  T = os:system_time(millisecond),
  Wait = Delay - (T rem Delay),

  MBD=case application:get_env(tpnode, mkblock_delay, 200) of
        X when is_integer(X), X>-500, X<2000, X=/=0 ->
          X;
        Any ->
          ?LOG_INFO("Bad mkblock_delay ~p",[Any]),
          200
      end,

  stout:log(sync_ticktimer, [{node, nodekey:node_name()},
                             {ready, maps:get(bcready, State, false)}]),

  case maps:get(bcready, State, false) of
    true ->
      if MBD<0 ->
           mkblock ! process,
           erlang:send_after(-MBD, whereis(txqueue), prepare);
         MBD>0 ->
           erlang:send_after(MBD, whereis(mkblock), process),
           txqueue ! prepare
      end,
      %tpnode_dtx_runner:run(), %run dtx txs
      ?LOG_DEBUG("Time to tick. next in ~w", [Wait]);
    false ->
      erlang:send_after(MBD, whereis(mkblock), flush),
      ?LOG_INFO("Time to tick. But we not in sync. wait ~w", [Wait])
  end,
  
  {noreply,
    State#{
      ticktimer => erlang:send_after(Wait, self(), ticktimer),
      prevtick => T
    }
  };

handle_info(selftimer5, #{mychain:=_MyChain, tickms:=_Ms, timer5:=Tmr, offsets:=_Offs} = State) ->
  
  catch erlang:cancel_timer(Tmr),
  
%  Friends = maps:keys(Offs),
%
%  {Avg, Off2} = lists:foldl(
%    fun(Friend, {Acc, NewOff}) ->
%      case maps:get(Friend, Offs, undefined) of
%        undefined ->
%          {Acc, NewOff};
%        {LOffset, LTime} ->
%          {[LOffset | Acc], maps:put(Friend, {LOffset, LTime}, NewOff)}
%      end
%    end, {[], #{}}, Friends),
%
%  MeanDiff = median(Avg),
  MeanDiff = 0,
  T = os:system_time(microsecond),
%
%  Hello =
%    msgpack:pack(
%      #{null=><<"hello">>,
%        <<"n">> => nodekey:node_id(),
%        <<"t">> => T
%      }),
%  tpic:cast(tpic, <<"timesync">>, Hello),

  BCReady = blockchain:ready(),
  MeanMs = round((T - MeanDiff) / 1000),
%
%  if
%    (Friends == []) ->
%      ?LOG_DEBUG("I'm alone in universe my time ~w", [(MeanMs rem 3600000) / 1000]);
%    true ->
%      ?LOG_DEBUG(
%        "I have ~b friends, and mean hospital time ~w, mean diff ~w blocktime ~w",
%        [length(Friends), (MeanMs rem 3600000) / 1000, MeanDiff / 1000, Ms]
%      )
%  end,


  {noreply, State#{
    timer5 => erlang:send_after(5000 - (MeanMs rem 5000) + 500, self(), selftimer5),
%    offsets => Off2,
%    meandiff => MeanDiff,
    bcready => BCReady
  }};

handle_info(_Info, State) ->
  ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%median([]) -> 0;
%
%median([E]) -> E;
%
%median(List) ->
%  LL = length(List),
%  DropL = (LL div 2) - 1,
%  {_, [M1, M2 | _]} = lists:split(DropL, List),
%  case LL rem 2 of
%    0 -> %even elements
%      (M1 + M2) / 2;
%    1 -> %odd
%      M2
%  end.

%% ------------------------------------------------------------------

load_settings(State) ->
  {ok, MyChain} = chainsettings:get_setting(mychain),
  BlockTime = chainsettings:get_val(blocktime,3),
  BCReady = blockchain:ready(),
  State#{
    tickms => BlockTime * 1000,
    mychain => MyChain,
    bcready => BCReady
  }.


