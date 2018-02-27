-module(xchain_dispatcher).
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

init(_) ->
    {
        ok,
        #{
            pid_subs => #{},
            chan_subs => #{}
        }
    }.


handle_call(state, _From, State) ->
    {reply, State, State};


handle_call({publish, Channel, Data}, _From, State) ->
    SentCount = publish(Channel, Data, State),
    {reply, SentCount, State};


handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p", [_Request]),
    {reply, ok, State}.



handle_cast({subscribe, Channel, Pid}, #{pid_subs:=_Pids,chan_subs:=_Chans}=State) ->
    {noreply, add_subscription(Channel, Pid, State)};

handle_cast(_Msg, State) ->
    lager:notice("Unknown cast ~p", [_Msg]),
    {noreply, State}.


handle_info({'DOWN',_Ref,process,Pid,_Reason}, State) ->
    {noreply, unsubscribe_all(Pid, State)};

handle_info(_Info, State) ->
    lager:notice("Unknown info  ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


add_subscription(Channel, Pid, #{pid_subs:=Pids,chan_subs:=Chans}=State) ->
    lager:info("subscribe ~p to ~p", [Pid, Channel]),
    monitor(process,Pid),
    OldPidChannels = maps:get(Pid, Pids, #{}),
    NewPidChannels = maps:put(Channel, 1, OldPidChannels),
    OldChanPids = maps:get(Channel, Chans, #{}),
    NewChanPids = maps:put(Pid, 1, OldChanPids),

    State#{
        pid_subs => maps:put(Pid, NewPidChannels, Pids),
        chan_subs => maps:put(Channel, NewChanPids, Chans)
    }.


unsubscribe_all(Pid, #{pid_subs:=Pids,chan_subs:=Chans}=State) when is_pid(Pid) ->
    lager:info("remove all subs for pid ~p", [Pid]),
    State#{
        pid_subs => maps:remove(Pid, Pids),
        chan_subs => maps:map(
            fun(_Chan, ChanPids) ->
                maps:without([Pid], ChanPids)
            end, Chans)
    }.

publish(Channel, Data, #{chan_subs:=Chans}=_State) ->
    Subscribers = maps:get(Channel, Chans, #{}),
    Publisher =
        fun(ClientPid, _SubscribeState, Counter) ->
            erlang:send(ClientPid, {message, Data}),
            Counter+1
        end,
    maps:fold(Publisher, 0, Subscribers).

