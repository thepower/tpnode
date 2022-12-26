% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_client).
-include("include/tplog.hrl").

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-define(CONNECTION_TIMER_SEC, 10).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,init_subscribes/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
  Name = maps:get(name, Options, xchain_client),
  gen_server:start_link({local, Name}, ?MODULE, Options, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  State = #{
    %subs => init_subscribes(#{}),
    subs => #{},
    chain => blockchain:chain(),
    connect_timer => erlang:send_after(5 * 1000, self(), make_connections)
  },
  code:ensure_loaded(xchain_client_handler),
  {ok, State}.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call({add_subscribe, Subscribe}, _From, #{subs:=Subs} = State) ->
  AS=add_sub(Subscribe, Subs),
  ?LOG_NOTICE("xchain client add subscribe ~p: ~p", [Subscribe, AS]),
  {reply, ok, State#{
                subs => AS
               }};

handle_call(peers, _From, #{subs:=Subs} = State) ->
  {reply, get_peers(Subs), State};

handle_call(_Request, _From, State) ->
  ?LOG_NOTICE("xchain client unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast(settings, State) ->
  ?LOG_NOTICE("xchain client reload settings"),
  {noreply, change_settings_handler(State)};

handle_cast({discovery, Announce, AnnounceBin}, #{subs:=Subs} = State) ->
%%  ?LOG_DEBUG(
%%    "xchain client got announce from discovery. " ++
%%    "Relay it to all active xchain connections."),
  try
    stout:log(xchain_c_discovery, [{announce, Announce}]),
    relay_discovery(Announce, AnnounceBin, Subs)
  catch
    Err:Reason ->
      ?LOG_ERROR(
        "xchain client can't relay announce ~p ~p ~p",
        [Err, Reason, Announce]
       )
  end,
  {noreply, State};

handle_cast(_Msg, State) ->
  ?LOG_ERROR("xchain client unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info({wrk_up, ConnPid, NodeID}, #{subs:=Subs} = State) ->
  ?LOG_NOTICE("xchain client got nodeid from server for pid ~p: ~p",
               [ConnPid, NodeID]),
  {noreply, State#{
              subs => update_sub(
                        fun(_,Sub) ->
                            maps:put(nodeid, NodeID, Sub)
                        end, ConnPid, Subs)
             }};

handle_info({wrk_down, ConnPid, Reason}, #{subs:=Subs} = State) ->
  ?LOG_NOTICE(
    "xchain client got close from server for pid ~p: ~p",
    [ConnPid, Reason]
  ),
  
  {noreply,
    State#{
      subs => update_sub(
        fun(_, Sub) ->
          BanUntil = os:system_time(seconds) +
            ?CONNECTION_TIMER_SEC * 5 + rand:uniform(?CONNECTION_TIMER_SEC),
          NewSub = maps:without([worker, nodeid], Sub),
          NewSub#{ban => BanUntil}
        end, ConnPid, Subs)
    }};


handle_info(make_connections, #{connect_timer:=Timer, subs:=Subs} = State) ->
  catch erlang:cancel_timer(Timer),
  Subs1 = init_subscribes(Subs),
  NewSubs = make_connections(Subs1),
  {noreply,
    State#{
      subs => NewSubs,
      connect_timer =>
        erlang:send_after(?CONNECTION_TIMER_SEC * 1000, self(), make_connections)
    }};

handle_info(_Info, State) ->
  ?LOG_ERROR("xchain client unknown info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
make_connections(Subs) ->
  maps:map(
    fun(_Key, Sub) ->
        case maps:is_key(worker, Sub) of
          false ->
            try
              IsBanned =
                fun() ->
                  %% Sub = #{ban => 12345678, address => "1.2.3.4",port => 8080}
                  Now = os:system_time(seconds),
                  case maps:get(ban, Sub, 0) of
                    TS when (TS>Now) ->
                      TS; % banned until TS
                    _ ->
                      false % can connect
                  end
                end,
  
              case IsBanned() of
                false ->
                  ?LOG_INFO("xchain client make connection to ~p",[Sub]),
                  {ok, Pid} = xchain_client_worker:start_link(Sub),
                  Sub#{worker=>Pid};
                WaitUntil ->
                  ?LOG_DEBUG("xchain client skip until ~p connection to ~p",[WaitUntil, Sub]),
                  Sub
              end
            catch
              Err:Reason ->
                ?LOG_INFO(
                  "xchain client got error while connection to remote xchain: ~p ~p",
                  [Err, Reason]
                ),
                Sub
            end;
          _ ->
            Sub
        end
    end,
    Subs
   ).

add_sub(#{address:=IP,port:=Port}=Subscribe, Subs) ->
  try
    Key = {IP,Port},
    NewSub = maps:merge(
               Subscribe,
               maps:get(Key, Subs, #{})
              ),
    maps:put(Key, NewSub, Subs)
  catch
    Reason ->
      ?LOG_ERROR("xchain client can't process subscribe. ~p ~p", [Reason, Subscribe]),
      Subs
  end.

get_peers(Subs) ->
  Parser = fun(_PeerKey, #{worker:=_W, nodeid:=NodeID}, Acc) ->
               maps:put(NodeID, [], Acc);
              (_PeerKey, _PeerInfo, Acc) ->
               Acc
           end,
  maps:fold(Parser, #{}, Subs).

relay_discovery(_Announce, AnnounceBin, Subs) ->
  Sender =
  fun(_Key, #{worker:=W}, Cnt) ->
      W ! {send_msg, #{null=><<"xdiscovery">>, <<"bin">>=>AnnounceBin}},
      Cnt+1;
     (_Key, Sub, Cnt) ->
      ?LOG_DEBUG("Skip relaying to unfinished connection: ~p", [Sub]),
      Cnt
  end,
  Sent = maps:fold(Sender, 0, Subs),
  ?LOG_DEBUG("~p xchain discovery announces were sent", [Sent]),
  ok.

change_settings_handler(#{chain:=Chain, subs:=Subs} = State) ->
  CurrentChain = blockchain:chain(),
  case CurrentChain of
    Chain ->
      State;
    _ ->
      ?LOG_INFO("xchain client wiped out all crosschain subscribes"),

      % close all active connections
      maps:fold(
        fun(_Key, #{worker:=W}=_Sub, Acc) ->
            W ! stop,
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

init_subscribes(Subs) ->
  CS=case ets:info(blockchain) of
       undefined ->
         false;
       _ ->
         true
     end,
  Config = application:get_env(tpnode, crosschain, #{}),
  case maps:get(connect, Config, undefined) of
    undefined ->
      MyCfg=if CS==false ->
                 #{};
               CS==true ->
                 CfgPath=[<<"current">>, <<"xchain">>, nodekey:node_name()],
                 chainsettings:by_path(CfgPath)
            end,
      case maps:get(<<"connect">>,MyCfg,#{}) of
        Nodes2Connect when is_list(Nodes2Connect) ->
          S1=lists:foldl(
            fun(NodeName,A) ->
                C=chainsettings:contacts(NodeName,[<<"xchain">>,<<"xchain+tls">>]),
                if is_list(C) ->
                     lists:foldl(
                       fun(ConnTo,Acc) ->
                           %uri_string:parse(<<"xchain://user:pw@10.3.252.69:1080/as/er.txt?x=1#s123">>).
                           URI=#{scheme:=S,host:=H,port:=P}=uri_string:parse(ConnTo),
                           Parts=binary:split(
                                   maps:get( query, URI, <<>>),
                                   <<"&">>,
                                   [global]),
                           Param=[ case binary:split(L,<<"=">>) of
                                      [A1,B1] -> {A1,B1};
                                      [A1] -> A1
                                    end || L <- Parts ]--[<<>>],
                           case S of
                             <<"xchain">> ->
                               add_sub( #{ url=>ConnTo,
                                           scheme=>S,
                                           address => binary_to_list(H),
                                           port => P,
                                           param => Param,
                                           new => true
                                         },Acc);
                             <<"xchain+tls">> -> %not ready yet, so ignore
                               Acc;
                             _ ->
                               Acc
                           end
                       end,
                       A, C);
                   C==#{} ->
                     A;
                   true ->
                     ?LOG_ERROR("Can't parse node ~p contacts ~p",[NodeName,C]),
                     A
                end
            end,
            Subs,
            Nodes2Connect),
          maps:fold(
            fun(K, #{new:=_}=V, Acc)  ->
                maps:put(K,maps:remove(new,V),Acc);
               (K, #{worker:=_}=V, Acc)  ->
                maps:put(K,V,Acc);
               (_K, _Sub, Acc)  ->
                Acc
            end, #{}, S1);

        #{} ->
          Subs;
        Any ->
          ?LOG_ERROR("Can't parse connect ~p",[Any]),
          Subs
      end;
    ConnectIpsList ->
      lists:foldl(
        fun({Ip, Port}, Acc) when is_integer(Port) ->
            Sub = #{
                    address => Ip,
                    port => Port
                   },
            add_sub(Sub, Acc);
           (Invalid, Acc) ->
            ?LOG_ERROR("xhcain client got invalid crosschain connect term: ~p", Invalid),
            Acc
        end, Subs, ConnectIpsList)
  end.

update_sub(Fun, GunPid, Subs) ->
  case find_sub_by_pid_and_ref(GunPid, Subs) of
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

find_sub_by_pid_and_ref(GunPid, Subs) ->
  maps:fold(
    fun(Key, #{worker:=Pid}, undefined) when Pid==GunPid ->
        {pid,Key};
       (_,_, Found) ->
        Found
    end, undefined, Subs).

