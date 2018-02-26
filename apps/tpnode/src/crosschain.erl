% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(crosschain).

-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-export([pack/1, unpack/1]).

-export([test/0]).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    Name = maps:get(name, Options, crosschain),
    lager:notice("start ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    State = #{
        subs => #{},
        connect_timer => erlang:send_after(10 * 1000, self(), make_connections)
    },
    {ok, State}.

handle_call(state, _From, State) ->
    lager:notice("state request", []),
    {reply, State, State};


handle_call({add_subscribe, Subscribe}, _From, #{subs:=Subs} = State) ->
    lager:notice("add subscribe ~p", [Subscribe]),
    {reply, ok, State#{
        subs => add_sub(Subscribe, Subs)
    }};

handle_call({connect, Ip, Port}, _From, State) ->
    lager:notice("crosschain connect to ~p ~p", [Ip, Port]),
    {reply, ok, State#{
        conn => connect_remote({Ip, Port})
    }};

%%handle_call({send, Text}, _From, State) ->
%%    #{conn:=ConnPid} = State,
%%    gun:ws_send(ConnPid, {text, Text}),
%%    {reply, ok, State};

handle_call(_Request, _From, State) ->
    lager:notice("crosschain unknown call ~p", [_Request]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:notice("crosschain unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info({gun_up, ConnPid, http}, State) ->
    lager:notice("crosschain client http up"),
    gun:ws_upgrade(ConnPid, "/"),
    {noreply, State};

handle_info({gun_ws_upgrade, ConnPid, ok, _Headers}, #{subs:=Subs} = State) ->
    lager:notice("crosschain client connection upgraded to websocket"),
    {noreply, State#{
        subs => mark_ws_mode_on(ConnPid, Subs)
    }};

handle_info({gun_ws, ConnPid, {close, _, _}}, #{subs:=Subs} = State) ->
    lager:notice("crosschain client got close from server for pid ~p", [ConnPid]),
    {noreply, State#{
        subs => lost_connection(ConnPid, Subs)
    }};

handle_info({gun_ws, ConnPid, {binary, Bin} }, State) ->
    lager:notice("crosschain client got ws bin msg: ~p", [Bin]),
    handle_xchain(ConnPid, unpack(Bin)),
    {noreply, State};

handle_info({gun_ws, _ConnPid, {text, Msg} }, State) ->
    lager:notice("crosschain client got ws msg: ~p", [Msg]),
    {noreply, State};

handle_info({gun_down, ConnPid, _, _, _, _}, #{subs:=Subs} = State) ->
    lager:notice("crosschain client lost connection for pid: ~p", [ConnPid]),
    {noreply, State#{
        subs => lost_connection(ConnPid, Subs)
    }};

%%{gun_down,<0.271.0>,http,closed,[],[]}
%%{gun_ws,<0.248.0>,{close,1000,<<>>}}
%%{gun_down,<0.248.0>,ws,closed,[],[]}
%%{gun_error,<0.248.0>,{badstate,"Connection needs to be upgraded to Websocket before the gun:ws_send/1 function can be used."}}
%%{gun_ws_upgrade,<0.248.0>,ok,[{<<"connection">>,<<"Upgrade">>},{<<"date">>,<<"Sat, 24 Feb 2018 23:42:38 GMT">>},{<<"sec-websocket-accept">>,<<"vewcPjnW/Rek72GO2D/WPG9/Sz8=">>},{<<"server">>,<<"Cowboy">>},{<<"upgrade">>,<<"websocket">>}]}
%%{gun_ws,<0.1214.0>,{close,1000,<<>>}}

handle_info(make_connections, #{connect_timer:=Timer, subs:=Subs} = State) ->
    catch erlang:cancel_timer(Timer),
    NewSubs = make_connections(Subs),
    {noreply, State#{
        subs => make_subscription(NewSubs),
        connect_timer => erlang:send_after(10 * 1000, self(), make_connections)
    }};

handle_info(_Info, State) ->
    lager:notice("crosschain client unknown info ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


%% TODO: catch gun:open errors here!!!
connect_remote({Ip, Port} = _Address) ->
    {ok, _} = application:ensure_all_started(gun),
    lager:info("crosschain client connecting to ~p ~p", [Ip, Port]),
    {ok, ConnPid} = gun:open(Ip, Port),
    ConnPid.

lost_connection(Pid, Subs) ->
    Cleaner =
        fun(_Key, #{connection:=Connection, channels:=Channels} = Sub) ->
            case Connection of
                Pid ->
                    NewSub = maps:remove(connection, Sub),
                    NewSub1 = maps:remove(ws_mode, NewSub),

                    % unsubscribe all channels
                    NewSub1#{
                        channels => maps:map(fun(_Channel, _OldState) -> 0 end, Channels)
                    };
                _ ->
                    Sub
            end;
            (_Key, Sub) ->
                % skip this subscribe
                Sub
        end,
    maps:map(Cleaner, Subs).


mark_ws_mode_on(Pid, Subs) ->
    Marker =
        fun(_Key, #{connection:=Connection} = Sub) ->
            case Connection of
                Pid ->
                    Sub#{
                        ws_mode => true
                    };
                _ ->
                    Sub
            end;
        (_Key, Sub) ->
            Sub
        end,
    maps:map(Marker, Subs).


make_connections(Subs) ->
    lager:info("make connections"),
    maps:map(
        fun(_Key, Sub) ->
            case maps:is_key(connection, Sub) of
                false ->
                    try
                        #{address:=Ip, port:=Port} = Sub,
                        Sub#{
                            connection => connect_remote({Ip, Port})
                        }
                    catch
                        _:_ ->
                            Sub
                    end;
                _ ->
                    Sub

            end
        end,
        Subs
    ).

subscribe2key(#{address:=Ip, port:=Port}) ->
    {Ip, Port}.


%% #{ {Ip, Port} =>  #{ address =>, port =>, channels => #{ <<"ch1">> => 0, <<"ch2">> => 0, <<"ch3">> => 0}}}

parse_subscribe(#{address:=Ip, port:=Port, channels:=Channels})
    when is_integer(Port) andalso is_list(Channels) ->
    NewChannels = lists:foldl(
        fun(Chan, ChanStorage) when is_binary(Chan) -> maps:put(Chan, 0, ChanStorage);
           (InvalidChanName, _ChanStorage) -> lager:info("invalid chan name: ~p", InvalidChanName)
        end,
        #{},
        Channels
    ),
    #{
        address => Ip,
        port => Port,
        channels => NewChannels
    };

parse_subscribe(Invalid) ->
    lager:info("invalid subscribe: ~p", [Invalid]),
    throw(invalid_subscribe).

check_empty_subscribes(#{channels:=Channels}=_Sub) ->
    SubCount = maps:size(Channels),
    if
        SubCount<1 ->
            throw(empty_subscribes);
        true ->
            ok
    end.

add_sub(Subscribe, Subs) ->
    try
        Parsed = parse_subscribe(Subscribe),
        Key = subscribe2key(Parsed),
        NewSub = maps:merge(
            Parsed,
            maps:get(Key, Subs, #{})
        ),
        check_empty_subscribes(NewSub),
        maps:put(Key, NewSub, Subs)
    catch
        Reason ->
            lager:info("can't process subscribe. ~p", Reason),
            Subs
    end.

subscribe_one_channel(ConnPid, Channel) ->
    % subscribe here
    lager:info("subscribe to ~p channel", [Channel]),
    Cmd = pack({subscribe, Channel}),
    Result = gun:ws_send(ConnPid, {binary, Cmd}),
    lager:info("subscribe result is ~p", [Result]),
    1.

make_subscription(Subs) ->
    Subscriber =
        fun(_Key, #{connection:=Conn, ws_mode:=true, channels:=Channels}=Sub) ->
            NewChannels = maps:map(
                fun(Channel, 0=_CurrentState) ->
                    subscribe_one_channel(Conn, Channel);
                   (_Channel, CurrentState) ->
                       % skip this channel
                       CurrentState
                end,
                Channels),
            Sub#{
                channels => NewChannels
            };
           (_, Sub) ->
               % skip this connection
              Sub
        end,
    maps:map(Subscriber, Subs).


pack(Term) ->
    term_to_binary(Term).

unpack(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]);

unpack(Invalid) ->
    lager:info("invalid data for unpack ~p", [Invalid]),
    {}.


%% -----------------


handle_xchain(_ConnPid, Cmd) ->
    lager:info("got xchain message from server: ~p", [Cmd]).


%%upgrade_success(ConnPid, Headers) ->
%%    io:format("Upgraded ~w. Success!~nHeaders:~n~p~n",
%%        [ConnPid, Headers]),
%%
%%    gun:ws_send(ConnPid, {text, "It's raining!"}),
%%
%%    receive
%%        {gun_ws, ConnPid, {text, Msg} } ->
%%            io:format("got from socket: ~s~n", [Msg])
%%    end.

test() ->
    Subscribe = #{
        address => "127.0.0.1",
        port => 43311,
        channels => [<<"ch1">>, <<"ch2">>, <<"ch3">>]
    },
    gen_server:call(crosschain, {add_subscribe, Subscribe}).
%%    {ok, _} = application:ensure_all_started(gun),
%%    {ok, ConnPid} = gun:open("127.0.0.1", 43311),
%%    {ok, _Protocol} = gun:await_up(ConnPid),
%%
%%    gun:ws_upgrade(ConnPid, "/"),
%%
%%    receive
%%        {gun_ws_upgrade, ConnPid, ok, Headers} ->
%%            upgrade_success(ConnPid, Headers);
%%        {gun_response, ConnPid, _, _, Status, Headers} ->
%%            exit({ws_upgrade_failed, Status, Headers});
%%        {gun_error, _ConnPid, _StreamRef, Reason} ->
%%            exit({ws_upgrade_failed, Reason})
%%    %% More clauses here as needed.
%%    after 1000 ->
%%        exit(timeout)
%%    end,
%%
%%    gun:shutdown(ConnPid).

