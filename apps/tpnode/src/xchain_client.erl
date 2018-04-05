% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_client).

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

-export([test/0]).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    Name = maps:get(name, Options, xchain_client),
    lager:notice("start ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    State = #{
        subs => init_subscribes(#{}),
        chain => blockchain:chain(),
        connect_timer => erlang:send_after(10 * 1000, self(), make_connections),
        pinger_timer => erlang:send_after(10 * 1000, self(), make_pings)
    },
    {ok, State}.

handle_call(state, _From, State) ->
    {reply, State, State};


handle_call({add_subscribe, Subscribe}, _From, #{subs:=Subs} = State) ->
    AS=add_sub(Subscribe, Subs),
    lager:notice("xchain client add subscribe ~p: ~p", [Subscribe, AS]),
    {reply, ok, State#{
        subs => AS
    }};

handle_call({connect, Ip, Port}, _From, State) ->
    lager:notice("xchain client connect to ~p ~p", [Ip, Port]),
    {reply, ok, State#{
        conn => connect_remote({Ip, Port})
    }};

%%handle_call({send, Text}, _From, State) ->
%%    #{conn:=ConnPid} = State,
%%    gun:ws_send(ConnPid, {text, Text}),
%%    {reply, ok, State};

handle_call(peers, _From, #{subs:=Subs} = State) ->
    {reply, get_peers(Subs), State};


handle_call(_Request, _From, State) ->
    lager:notice("xchain client unknown call ~p", [_Request]),
    {reply, ok, State}.


handle_cast(settings, State) ->
    lager:notice("xchain client reload settings"),
    {noreply, change_settings_handler(State)};

handle_cast({discovery, Announce, AnnounceBin}, #{subs:=Subs} = State) ->
    lager:notice("xchain client got announce from discovery. Relay it to all connected chains"),
    try
        relay_discovery(Announce, AnnounceBin, Subs)
    catch
        Err:Reason ->
            lager:error(
                "xchain client can't relay announce ~p ~p ~p",
                [Err, Reason, Announce]
            )
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    lager:error("xchain client unknown cast ~p", [_Msg]),
    {noreply, State}.


handle_info({gun_up, ConnPid, http}, State) ->
    lager:notice("xchain client http up"),
    gun:ws_upgrade(ConnPid, "/"),
    {noreply, State};

handle_info({gun_ws_upgrade, ConnPid, ok, _Headers}, #{subs:=Subs} = State) ->
    lager:notice("xchain client connection upgraded to websocket"),
    {noreply, State#{
        subs => mark_ws_mode_on(ConnPid, Subs)
    }};

handle_info({gun_ws, ConnPid, {close, _, _}}, #{subs:=Subs} = State) ->
    lager:notice("xchain client got close from server for pid ~p", [ConnPid]),
    {noreply, State#{
        subs => lost_connection(ConnPid, Subs)
    }};

handle_info({gun_ws, ConnPid, {binary, Bin} }, State) ->
%%    lager:notice("xchain client got ws bin msg: ~p", [Bin]),
    try
        NewState = xchain_client_handler:handle_xchain(unpack(Bin), ConnPid, State),
        {noreply, NewState}
    catch
        Ec:Ee ->
            S=erlang:get_stacktrace(),
            lager:error("xchain client msg parse error ~p:~p", [Ec, Ee]),
            lists:foreach(
                fun(Se) ->
                    lager:error("at ~p", [Se])
                end, S),
            {noreply, State}
    end;

handle_info({gun_ws, _ConnPid, {text, Msg} }, State) ->
    lager:error("xchain client got ws text msg: ~p", [Msg]),
    {noreply, State};

handle_info({gun_down, ConnPid, _, _, _, _}, #{subs:=Subs} = State) ->
    lager:notice("xchain client lost connection for pid: ~p", [ConnPid]),
    {noreply, State#{
        subs => lost_connection(ConnPid, Subs)
    }};

%%{gun_down, <0.271.0>, http, closed, [], []}
%%{gun_ws, <0.248.0>, {close, 1000, <<>>}}
%%{gun_down, <0.248.0>, ws, closed, [], []}
%%{gun_error, <0.248.0>, {badstate, "Connection needs to be upgraded to Websocket "++
%%								"before the gun:ws_send/1 function can be used."}}
%%
%%{gun_ws_upgrade, <0.248.0>, ok, [{<<"connection">>, <<"Upgrade">>},
%%{<<"date">>, <<"Sat, 24 Feb 2018 23:42:38 GMT">>},
%%{<<"sec-websocket-accept">>, <<"vewcPjnW/Rek72GO2D/WPG9/Sz8=">>},
%%{<<"server">>, <<"Cowboy">>}, {<<"upgrade">>, <<"websocket">>}]}
%%
%%{gun_ws, <0.1214.0>, {close, 1000, <<>>}}

handle_info(make_connections, #{connect_timer:=Timer, subs:=Subs} = State) ->
    catch erlang:cancel_timer(Timer),
    NewSubs = make_connections(Subs),
    {noreply, State#{
        subs => make_subscription(NewSubs),
        connect_timer => erlang:send_after(10 * 1000, self(), make_connections)
    }};


handle_info(make_pings, #{pinger_timer:=Timer, subs:=Subs} = State) ->
    catch erlang:cancel_timer(Timer),
    make_pings(Subs),
    {noreply, State#{
        pinger_timer => erlang:send_after(30 * 1000, self(), make_pings)
    }};


handle_info({'DOWN', _Ref, process, Pid, _Reason}, #{subs:=Subs} = State) ->
    {noreply, State#{
        subs => lost_connection(Pid, Subs)
    }};

handle_info(_Info, State) ->
    lager:error("xchain client unknown info ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

make_pings(Subs) ->
    Cmd = pack(ping),
    maps:fold(
        fun(_Key, #{connection:=ConnPid, ws_mode:=true} = _Sub, Acc) ->
            catch gun:ws_send(ConnPid, {binary, Cmd}),
            Acc + 1;
           (_, _, Acc) ->
               Acc
        end, 0, Subs).


%% --------------------------------------------------------------------

connect_remote({Ip, Port} = _Address) ->
    {ok, _} = application:ensure_all_started(gun),
    lager:info("xchain client connecting to ~p ~p", [Ip, Port]),
    {ok, ConnPid} = gun:open(Ip, Port),
    ConnPid.


%% --------------------------------------------------------------------

lost_connection(Pid, Subs) ->
    Cleaner =
        fun(_Key, #{connection:=Connection, channels:=Channels} = Sub) ->
            case Connection of
                Pid ->
                    NewSub = maps:remove(connection, Sub),
                    NewSub1 = maps:remove(ws_mode, NewSub),
                    NewSub2 = maps:remove(node_id, NewSub1),

                    % unsubscribe all channels
                    NewSub2#{
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

%% --------------------------------------------------------------------

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


%% --------------------------------------------------------------------

make_connections(Subs) ->
	lager:info("xchain client make connections"),
	maps:map(
		fun(_Key, Sub) ->
				case maps:is_key(connection, Sub) of
					false ->
						try
							#{address:=Ip, port:=Port} = Sub,
							ConnPid = connect_remote({Ip, Port}),
							monitor(process, ConnPid),
							Sub#{
								connection => ConnPid
							 }
						catch
							Err:Reason ->
								lager:info("xchain client got error while connection to remote xchain: ~p ~p",
													 [Err, Reason]),
								Sub
						end;
					_ ->
						Sub

				end
		end,
		Subs
	 ).

%% --------------------------------------------------------------------

subscribe2key(#{address:=Ip, port:=Port}) ->
    {Ip, Port}.


%% --------------------------------------------------------------------

%% #{ {Ip, Port} =>  #{ address =>, port =>, channels =>
%%						#{ <<"ch1">> => 0, <<"ch2">> => 0, <<"ch3">> => 0}}}

parse_subscribe(#{address:=Ip, port:=Port, channels:=Channels})
    when is_integer(Port) andalso is_list(Channels) ->
    NewChannels = lists:foldl(
        fun(Chan, ChanStorage) when is_binary(Chan) -> maps:put(Chan, 0, ChanStorage);
           (InvalidChanName, _ChanStorage) -> lager:info("xchain client got invalid chan name: ~p", InvalidChanName)
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
    lager:error("xchain client got invalid subscribe: ~p", [Invalid]),
    throw(invalid_subscribe).

%% --------------------------------------------------------------------


check_empty_subscribes(#{channels:=Channels}=_Sub) ->
    SubCount = maps:size(Channels),
    if
        SubCount<1 ->
            throw(empty_subscribes);
        true ->
            ok
    end.

%% --------------------------------------------------------------------

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
            lager:error("xchain client can't process subscribe. ~p ~p", [Reason, Subscribe]),
            Subs
    end.

%% --------------------------------------------------------------------

subscribe_one_channel(ConnPid, Channel) ->
    % subscribe here
    lager:info("xhcain client subscribe to ~p channel", [Channel]),
    Cmd = pack({subscribe, Channel}),
    Result = gun:ws_send(ConnPid, {binary, Cmd}),
    lager:info("xchain client subscribe result is ~p", [Result]),
    1.

%% --------------------------------------------------------------------

make_subscription(Subs) ->
    MyNodeId = nodekey:node_id(),

    Subscriber =
        fun(_Key, #{connection:=Conn, ws_mode:=true, channels:=Channels}=Sub) ->
            Cmd = pack({node_id, MyNodeId, maps:keys(Channels)}),
            gun:ws_send(Conn, {binary, Cmd}),

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


%% --------------------------------------------------------------------


get_peers(Subs) ->
    Parser =
        fun(_PeerKey, #{channels:=Channels, node_id:=NodeId, ws_mode:=true} = _PeerInfo, Acc) ->
            maps:put(NodeId, maps:keys(Channels), Acc);

            (_PeerKey, _PeerInfo, Acc) ->
                Acc
        end,
    maps:fold(Parser, #{}, Subs).


%% --------------------------------------------------------------------

relay_discovery(_Announce, AnnounceBin, Subs) ->
    Sender =
        fun(_Key, #{connection:=Conn, ws_mode:=true}=Sub) ->
            Cmd = pack({xdiscovery, AnnounceBin}),
            gun:ws_send(Conn, {binary, Cmd}),
            Sub
        end,
    maps:map(Sender, Subs),
    ok.

%% --------------------------------------------------------------------

pack(Term) ->
    xchain:pack(Term).

%% --------------------------------------------------------------------

unpack(Bin) ->
    xchain:unpack(Bin).

%% --------------------------------------------------------------------

change_settings_handler(#{chain:=Chain, subs:=Subs} = State) ->
    CurrentChain = blockchain:chain(),
    case CurrentChain of
        Chain ->
            State;
        _ ->
            lager:info("xchain client wiped out all crosschain subscribes"),

            % close all active connections
            maps:fold(
                fun(_Key, #{connection:=ConnPid}=_Sub, Acc) ->
                    catch gun:shutdown(ConnPid),
                    Acc+1;
                   (_Key, _Sub, Acc) ->
                       Acc
                end,
                0,
                Subs),

            % and finally replace all subscribes by new ones
            State#{
                subs => init_subscribes(#{}),
                chain => CurrentChain
            }
    end.

%% -----------------

init_subscribes(Subs) ->
    Config = application:get_env(tpnode, crosschain, #{}),
    ConnectIpsList = maps:get(connect, Config, []),
    MyChainChannel = xchain:pack_chid(blockchain:chain()),
    lists:foldl(
        fun({Ip, Port}, Acc) when is_integer(Port) ->
            Sub = #{
                address => Ip,
                port => Port,
                channels => [MyChainChannel]
            },
            add_sub(Sub, Acc);

            (Invalid, Acc) ->
                lager:error("xhcain client got invalid crosschain connect term: ~p", Invalid),
                Acc
        end, Subs, ConnectIpsList).



%% -----------------



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
        port => 43312,
        channels => [<<"test123">>, xchain:pack_chid(2)]
    },
    gen_server:call(xchain_client, {add_subscribe, Subscribe}).
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

