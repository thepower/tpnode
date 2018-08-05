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
  {ok, _} = application:ensure_all_started(gun),
  State = #{
    subs => init_subscribes(#{}),
    chain => blockchain:chain(),
    cp_to_sub => #{},
    connect_timer => erlang:send_after(3 * 1000, self(), make_connections),
    pinger_timer => erlang:send_after(60 * 1000, self(), make_pings)
   },
  code:ensure_loaded(xchain_client_handler),
  {ok, State}.

handle_call(state, _From, State) ->
  {reply, State, State};


handle_call({add_subscribe, Subscribe}, _From, #{subs:=Subs} = State) ->
  AS=add_sub(Subscribe, Subs),
  lager:notice("xchain client add subscribe ~p: ~p", [Subscribe, AS]),
  {reply, ok, State#{
                subs => AS
               }};

handle_call(peers, _From, #{subs:=Subs} = State) ->
  {reply, get_peers(Subs), State};


handle_call(_Request, _From, State) ->
  lager:notice("xchain client unknown call ~p", [_Request]),
  {reply, ok, State}.


handle_cast(settings, State) ->
  lager:notice("xchain client reload settings"),
  {noreply, change_settings_handler(State)};

handle_cast({discovery, Announce, AnnounceBin}, #{subs:=Subs} = State) ->
  lager:notice(
    "xchain client got announce from discovery. " ++
    "Relay it to all active xchain connections."),
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

handle_info({gun_response, GunPid, GunRef, _IsFin, Code,
             _Headers}, #{subs:=Subs}=State) ->
  S1=update_sub(
       fun(pid, Sub) -> Sub;
          (ref, Sub) ->
           case maps:get(request, Sub, undefined) of
             compat ->
               if Code==404 ->
                    gun:ws_upgrade(GunPid, "/xchain/ws"),
                    Sub#{proto=>0};
                  true ->
                    Sub
               end;
             _ ->
               Sub
           end
       end, GunPid, GunRef, Subs),
  {noreply, State#{subs=>S1}};

handle_info({gun_data, GunPid, GunRef, _IsFin,
             _Payload}, #{subs:=Subs}=State) ->
  S1=update_sub(
       fun(pid, Sub) -> Sub;
          (ref, Sub) ->
           case maps:get(request, Sub, undefined) of
             compat ->
               lager:info("Gun data ~p",[_Payload]),
               gun:ws_upgrade(GunPid, "/xchain/ws",
                              [
                               {<<"sec-websocket-protocol">>, <<"thepower-xchain-v2">>}
                              ]),
               maps:without([request, req_ref],
                            Sub#{proto=>2}
                           );
             _ ->
               Sub
           end
       end, GunPid, GunRef, Subs),
  {noreply, State#{subs=>S1}};

handle_info({ws_request, Peer, Payload}, #{subs:=Subs}=State) ->
  case maps:find(Peer,Subs) of
    {ok, #{proto:=P,ws_mode:=true,connection:=Conn}} ->
      Cmd = xchain:pack(Payload, P),
      gun:ws_send(Conn, {binary, Cmd}),
      {noreply, State};
    {ok, #{}} ->
      lager:error("Can't make ws request: not connected"),
      {noreply, State};
    error ->
      {noreply, State}
  end;

handle_info({gun_up, _ConnPid, http}, State) ->
  lager:notice("xchain client http up"),
  {noreply, State};

handle_info({gun_ws_upgrade, ConnPid, ok, _Headers}, #{subs:=Subs} = State) ->
  lager:notice("xchain clientv2 connection upgraded to websocket"),
  {noreply, State#{
              subs => update_sub(
                        fun(_,#{proto:=P, channels:=Channels}=Sub) ->
                            MyNodeId = nodekey:node_id(),
                            Cmd = xchain:pack({node_id, MyNodeId, maps:keys(Channels)}, P),
                            gun:ws_send(ConnPid, {binary, Cmd}),
                            Sub#{ws_mode=>true}
                        end, ConnPid, undefined, Subs)
             }
  };

handle_info({gun_ws, ConnPid, {close, _, _}}, #{subs:=Subs} = State) ->
  lager:notice("xchain client got close from server for pid ~p", [ConnPid]),
  {noreply, State#{
              subs => lost_connection(ConnPid, Subs)
             }};

handle_info({gun_ws, ConnPid, {binary, Bin} }, #{subs:=Subs}=State) ->
  try
    {SubKey, #{proto:=P}=Sub}=find_sub(ConnPid, Subs),
    Handle=case maps:find(ws_handler_pid,Sub) of
             {ok, Pid} when is_pid(Pid) ->
               case is_process_alive(Pid) of
                 true  -> Pid;
                 false -> default
               end;
             error ->
               default
           end,
    if Handle==default ->
         NewSub = xchain_client_handler:handle_xchain(
                    xchain:unpack(Bin,P), ConnPid, Sub
                   ),
         if NewSub==Sub ->
              {noreply, State};
            true ->
              {noreply, State#{subs=>maps:put(SubKey, NewSub, Subs)}}
         end
    end
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
  maps:fold(
    fun(_Key, #{connection:=ConnPid, ws_mode:=true, proto:=P} = _Sub, Acc) ->
        Cmd = xchain:pack(ping, P),
        catch gun:ws_send(ConnPid, {binary, Cmd}),
        Acc + 1;
       (_, _, Acc) ->
        Acc
    end, 0, Subs).


%% --------------------------------------------------------------------

connect_remote(#{address:=Ip, port:=Port} = Sub) ->
  lager:info("xchain client connecting to ~p ~p", [Ip, Port]),
  {ok, ConnPid} = gun:open(Ip, Port),
  monitor(process, ConnPid),
  case maps:get(protocol, Sub, undefined) of
    2 ->
      Sub#{ connection => ConnPid };
    _ ->
      Ref=gun:get(ConnPid,"/xchain/api/compat"),
      Sub#{
        request => compat,
        req_ref => Ref,
        connection => ConnPid
       }
  end.

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
            channels =>
            maps:map(fun(_Channel, _OldState) -> 0 end, Channels)
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

make_connections(Subs) ->
  maps:map(
    fun(_Key, Sub) ->
        case maps:is_key(connection, Sub) of
          false ->
            try
              lager:info("xchain client make connection to ~p",[Sub]),
              connect_remote(Sub)
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

make_subscription(Subs) ->

  Subscriber =
  fun(_Key, #{connection:=Conn, ws_mode:=true, proto:=P, channels:=Channels}=Sub) ->
      NewChannels = maps:map(
                      fun(Channel, 0=_CurrentState) ->
                          lager:info("xhcain client subscribe to ~p channel", [Channel]),
                          CCmd = xchain:pack({subscribe, Channel}, P),
                          Result = gun:ws_send(Conn, {binary, CCmd}),
                          lager:info("xchain client subscribe result is ~p", [Result]),
                          1;
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
  fun(_Key, #{connection:=Conn, ws_mode:=true, proto:=P}, Cnt) ->
      Cmd = xchain:pack({xdiscovery, AnnounceBin}, P),
      gun:ws_send(Conn, {binary, Cmd}),
      Cnt+1;
     (_Key, Sub, Cnt) ->
      lager:debug("Skip relaying to unfinished connection: ~p", [Sub]),
      Cnt
  end,
  Sent = maps:fold(Sender, 0, Subs),
  lager:debug("~p xchain discovery announces were sent", [Sent]),
  ok.

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

update_sub(Fun, GunPid, GunRef, Subs) ->
  case find_sub_by_pid_and_ref(GunPid, GunRef, Subs) of
    undefined ->
      Subs;
    {Matched,Found} ->
      Sub=maps:get(Found, Subs),
      Sub2=Fun(Matched, Sub),
      if(Sub==Sub2) ->
          Subs;
        true ->
          maps:put(Found, Sub2, Subs)
      end
  end.

find_sub_by_pid_and_ref(GunPid, GunRef, Subs) ->
  maps:fold(
    fun(Key, #{connection:=Pid, req_ref:=RR}, undefined) when
          Pid==GunPid andalso RR==GunRef ->
        {ref,Key};
       (Key, #{connection:=Pid}, undefined) when Pid==GunPid ->
        {pid,Key};
       (_,_, Found) ->
        Found
    end, undefined, Subs).

find_sub(GunPid, Subs) ->
  maps:fold(
    fun(Key, #{connection:=Pid}=Conn, undefined) when Pid==GunPid ->
        {Key,Conn};
       (_,_, Found) ->
        Found
    end, undefined, Subs).

