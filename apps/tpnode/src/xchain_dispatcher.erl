-module(xchain_dispatcher).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, pub/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

pub(Channel, Payload) when is_binary(Channel) ->
    gen_server:call(xchain_dispatcher, {publish,Channel,Payload}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_) ->
    {
        ok,
        #{
            pid_info => #{},
            pid_subs => #{},
            chan_subs => #{}
        }
    }.


handle_call(peers, _From, #{pid_info:=PidInfo} = State) ->
    {reply, get_peers(PidInfo), State};


handle_call(state, _From, State) ->
    {reply, State, State};


handle_call({publish, Channel, Data}, _From, State) ->
    SentCount = publish(Channel, Data, State),
    {reply, SentCount, State};


handle_call(_Request, _From, State) ->
    lager:error("xchain dispatcher got unknown call ~p", [_Request]),
    {reply, ok, State}.


handle_cast({register_peer, Pid, RemoteNodeId, RemoteChannels}, State) ->
    {noreply, register_peer({Pid, RemoteNodeId, RemoteChannels}, State)};


handle_cast({subscribe, Channel, Pid}, #{pid_subs:=_Pids,chan_subs:=_Chans}=State) ->
    {noreply, add_subscription(Channel, Pid, State)};

handle_cast(_Msg, State) ->
    lager:error("xchain dispatcher got unknown cast ~p", [_Msg]),
    {noreply, State}.


handle_info({'DOWN',_Ref,process,Pid,_Reason}, State) ->
    {noreply, unsubscribe_all(Pid, State)};

handle_info(_Info, State) ->
    lager:error("xchain dispatcher got unknown info  ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


get_peers(PidInfo) ->
    Parser =
        fun(_ConnPid, PeerInfo, Acc) ->
            maps:merge(Acc, PeerInfo)
        end,

    try
        maps:fold(Parser, #{}, PidInfo)
    catch
        Ec:Ee ->
            iolist_to_binary(io_lib:format("~p:~p",[Ec,Ee]))
    end.

register_peer({Pid, RemoteNodeId, RemoteChannels}, #{pid_info:=PidInfo} = State) ->
    lager:info("xchain dispatcher register remote node ~p ~p ~p", [Pid, RemoteNodeId, RemoteChannels]),
    RemoteInfo = #{ RemoteNodeId => RemoteChannels},
    State#{
        pid_info => maps:put(Pid, RemoteInfo, PidInfo)
    }.

add_subscription(Channel, Pid, #{pid_subs:=Pids,chan_subs:=Chans}=State) ->
    lager:info("xchain dispatcher subscribe ~p to ~p", [Pid, Channel]),
    monitor(process,Pid),
    OldPidChannels = maps:get(Pid, Pids, #{}),
    NewPidChannels = maps:put(Channel, 1, OldPidChannels),
    OldChanPids = maps:get(Channel, Chans, #{}),
    NewChanPids = maps:put(Pid, 1, OldChanPids),

    State#{
        pid_subs => maps:put(Pid, NewPidChannels, Pids),
        chan_subs => maps:put(Channel, NewChanPids, Chans)
    }.


unsubscribe_all(Pid, #{pid_info:=PidInfo, pid_subs:=Pids, chan_subs:=Chans}=State)
    when is_pid(Pid) ->
    lager:info("xchain dispatcher remove all subs for pid ~p", [Pid]),
    State#{
        pid_info => maps:remove(Pid, PidInfo),
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

