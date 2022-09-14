-module(tpic2_peer).
-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,filter_rfc1918/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
  ?LOG_INFO("args ~p",[Args]),
  {ok, #{
     tmr=>erlang:send_after(100,self(),tmr),
     peer_ipport=>init_ipport(Args),
     pubkey=>maps:get(pubkey, Args, undefined),
     inctl=>undefined,
     outctl=>undefined,
     clients=>[],
     streams=>[{0,out,undefined}],
     servers=>[],
     services=>[],
     monitors=>#{},
     ct=>undefined,
     mpid=>#{}
    }
  }.

init_ipport(#{ip:=IPList,port:=Port}) ->
  [ {IP,Port} || IP <- IPList ];
init_ipport(_) ->
  [].

handle_call(active_out, _From, #{outctl:=OC}=State) ->
  ?LOG_INFO("Pid ~p asked me about active out ~p",
             [_From,OC]),
  {reply,
   case is_pid(OC) andalso is_process_alive(OC) of
     true ->
       OC;
     false ->
       false
   end, State};

handle_call(addr, _From, #{peer_ipport:=IPP}=State) ->
  IPP1=filter_rfc1918(IPP),
  {reply, IPP1, State#{peer_ipport => IPP1}};

handle_call(info, _From, #{streams:=Streams,
                           pubkey:=PK,
                           peer_ipport:=IPP}=State) ->
  {WState,AuthState} = case lists:filter(
               fun({0,out,_}) -> true;
                  (_) -> false
               end,Streams) of
          [{0,out,Pid}] when is_pid(Pid) ->
                           {working,ok};
          _ -> {init,undefined}
        end,
  {reply, #{
     addr => IPP,
     auth => AuthState,
     state => WState,
     peerpid => self(),
     streams => Streams,
     authdata => [ {pubkey,PK} ]
    }, State};

handle_call({get_stream, Name}, _From, #{streams:=Streams}=State) ->
  RStream = lists:filter(
              fun({N,_,_}) -> Name==N;
                 (_) -> false
              end,Streams),
  {reply, RStream, State};

handle_call({add, IP, Port}, _From, #{peer_ipport:=IPP}=State) ->
  IPP2=[{IP,Port}|(IPP--[{IP,Port}])],
  {reply, IPP2, State#{peer_ipport=>filter_rfc1918(IPP2)}};

handle_call({streams, AddStr}, _From, #{streams:=Str, pubkey:=TheirPub}=State) ->
  OurPub=nodekey:get_pub(),
  NewStr=lists:foldl(
    fun({S,_,_},Acc) ->
        Acc--[S]
    end, AddStr, Str),
  if OurPub > TheirPub ->
       erlang:send_after(3000,self(),try_connect),
       ok;
     true ->
       erlang:send_after(100,self(),try_connect),
       ok
  end,
  {reply, NewStr, State#{
                  streams=> Str++[{NS,undefined,undefined} || NS <- NewStr]
                 }
  };

handle_call({register, StreamID, Dir, PID},
            _From,
            #{mpid:=MPID, streams:=Str}=State) ->
  ?LOG_DEBUG("Register pid ~p sid ~p dir ~p",[PID,StreamID,Dir]),
  case maps:find(PID,MPID) of
    {ok, {undefined,_Dir1}} -> %replace with new stream id
      {reply, {ok, self()},
       apply_ctl(
         State#{
           streams=>stream_add({StreamID,Dir,PID},Str),
           mpid=>maps:put(PID,
                          {StreamID,Dir},
                          maps:get(mpid,State,#{})
                         )
          },
         StreamID, Dir, PID
        )
      };
    {ok, _} ->
      {reply, {exists, self()}, State};
    error ->
      monitor(process,PID),
      {reply, {ok, self()},
       apply_ctl(
         State#{
           streams=>stream_add({StreamID,Dir,PID},Str),
           mpid=>maps:put(PID,
                          {StreamID,Dir},
                          maps:get(mpid,State,#{})
                         )
          },
         StreamID, Dir, PID
        )
      }
  end;

handle_call(_Request, _From, State) ->
  ?LOG_INFO("Unhandled call ~p",[_Request]),
  {reply, unhandled, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(try_connect, #{streams:=Str,peer_ipport:=[{Host,Port}|RestIPP]}=State) ->
  case maps:find(ct, State) of
    {ok, Ref} when is_reference(Ref) ->
      erlang:cancel_timer(Ref);
    _ ->
      ok
  end,
  ?LOG_NOTICE("Try connect payload streams ~p",[Str]),
  lists:foreach(
    fun({SID, Dir, undefined}) when Dir==undefined orelse Dir==out ->
        tpic2_client:start(Host,Port, #{stream=>SID});
       (_) ->
        ignore
    end, Str),
  {noreply, State#{
              ct=>undefined,
              peer_ipport=>RestIPP++[{Host,Port}]
             }
  };

handle_info(tmr, #{tmr:=Tmr, pubkey:=PubKey, streams:=Str}=State) ->
  erlang:cancel_timer(Tmr),
  ?LOG_DEBUG("tmr"),
  MyKey=nodekey:get_pub(),
  if(MyKey == PubKey ) ->
      ?LOG_NOTICE("Found peer for myself, terminating"),
      lists:foreach(
        fun({_,_,PID}) when is_pid(PID) ->
            exit(PID,stop);
           (_) ->
            ok
        end, Str),
      {stop, normal, State};
    true ->
      OCState=case maps:get(outctl,State,undefined) of
                undefined ->
                  open_control(State);
                _ ->
                  State
              end,

      {noreply, OCState#{
                  tmr=>erlang:send_after(10000,self(),tmr)
                 }
      }
  end;

handle_info({'DOWN',_Ref,process,PID,_Reason}, #{mpid:=MPID,
                                                 streams:=Str,
                                                 outctl:=OCPid}=State) ->
  case maps:find(PID,MPID) of
    {ok, {StrID, Dir}} ->
      case maps:find(ct, State) of
        {ok, Ref} when is_reference(Ref) ->
          erlang:cancel_timer(Ref);
        _ ->
          ok
      end,

      ?LOG_INFO("Down str ~p ~p ~p",[StrID, Dir, PID]),
      {noreply, apply_ctl(
                  State#{
                    ct=>erlang:send_after(100,self(),try_connect),
                    streams=>stream_delete(PID,Str),
                    mpid=>maps:remove(PID,MPID)
                   },
                  StrID, Dir, undefined
                 )
      };
    error ->
      if OCPid==PID ->
           {noreply, State#{outctl=>undefined}};
         true ->
           {noreply, State}
      end
  end;
 

handle_info(_Info, State) ->
  ?LOG_INFO("Unhandled info ~p",[_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% Добавить стрим. 
%% варианты: стрима нет
%%              добавить
%%          стрим есть с направлением другим
%%              добавить
%%          стрим есть с направлнием undefined
%%              заменить
%%          стрим есть с направлением совпадающим
%%              заменить
stream_add({StreamID, Dir, PID}, Streams) ->
  F=lists:filter(
      fun({_,_,PID1}) when PID1 == PID -> 
          false;
         ({S,D,_}) when S==StreamID, D==Dir -> 
          false;
         ({S,undefined,_}) when S==StreamID -> 
          false;
         (_) -> true
      end,
      Streams),
  [{StreamID, Dir, PID}|F].

stream_delete(PID, Streams) ->
  case lists:keyfind(PID,3,Streams) of
    false -> Streams;
    {_SID, in, _} ->
      lists:keydelete(PID,3,Streams);
    {SID, out, _} ->
      lists:keyreplace(PID,3,Streams,{SID, out, undefined})
  end.

open_control(#{peer_ipport:=[]}=State) ->
  State;

open_control(#{peer_ipport:=[{Host,Port}|RestIPP]}=State) ->
  {ok, PID}=tpic2_client:start(Host,
                               Port,
                               #{
                                 stream=>0,
                                 announce=>[]
                                }),
  monitor(process,PID),
  State#{
    peer_ipport=>RestIPP++[{Host,Port}],
    outctl=>PID
   }.

apply_ctl(State, 0, in, PID) ->
  State#{inctl => PID};

apply_ctl(State, 0, out, PID) ->
  State#{outctl => PID};

apply_ctl(State, _StreamID, _Dir, _PID) ->
  State.

filter_rfc1918(IPP) ->
  case maps:get(allow_rfc1918,application:get_env(tpnode,tpic,#{}),false) of
    true ->
      IPP;
    false ->
      lists:filter(
        fun({Addr,_}) ->
            case inet:parse_address(Addr) of
              {ok, {10,_,_,_}} -> false;
              {ok, {0,0,0,0}} -> false;
              {ok, {172,O,_,_}} when O>=16, O<24 -> false;
              {ok, {192,168,_,_}} -> false;
              {ok, _} -> true;
              _ -> false
            end
        end,
        IPP)
  end.

