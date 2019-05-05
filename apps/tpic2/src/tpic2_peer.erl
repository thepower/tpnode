-module(tpic2_peer).
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

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
  lager:info("args ~p",[Args]),
  {ok, #{
     tmr=>erlang:send_after(100,self(),tmr),
     peer_ipport=>init_ipport(Args),
     pubkey=>maps:get(pubkey, Args, undefined),
     inctl=>undefined,
     outctl=>undefined,
     clients=>[],
     streams=>[],
     servers=>[],
     services=>[],
     monitors=>#{},
     mpid=>#{}
    }
  }.

init_ipport(#{ip:=IPList,port:=Port}) ->
  [ {IP,Port} || IP <- IPList ];
init_ipport(_) ->
  [].

handle_call({add, IP, Port}, _From, #{peer_ipport:=IPP}=State) ->
  IPP2=[{IP,Port}|(IPP--[{IP,Port}])],
  {reply, IPP2, State#{peer_ipport=>IPP2}};

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

handle_call({register, StreamID0, Dir, PID},
            _From,
            #{mpid:=MPID, streams:=Str}=State) ->
  StreamID = if StreamID0 == null -> undefined;
                true -> StreamID0
             end,
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
  lager:info("Unhandled call ~p",[_Request]),
  {reply, unhandled, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(try_connect, #{streams:=Str,peer_ipport:=[{Host,Port}|RestIPP]}=State) ->
  lager:notice("Try connect payload streams ~p",[Str]),
  lists:foreach(
    fun({SID, Dir, undefined}) when Dir==undefined orelse Dir==out ->
        tpic2_client:start(binary_to_list(Host),Port, #{stream=>SID});
       (_) ->
        ignore
    end, Str),
  {noreply, State#{
              peer_ipport=>RestIPP++[{Host,Port}]
             }
  };

handle_info(tmr, #{tmr:=Tmr}=State) ->
  erlang:cancel_timer(Tmr),
  lager:info("tmr"),

  OCState=case maps:get(outctl,State,undefined) of
       undefined ->
         open_control(State);
       _ ->
         State
     end,

  {noreply, OCState#{
              tmr=>erlang:send_after(10000,self(),tmr)
             }
  };

handle_info({'DOWN',_Ref,process,PID,_Reason}, #{mpid:=MPID,
                                                 streams:=Str}=State) ->
  case maps:find(PID,MPID) of
    {ok, {_Dir, _StrID}} ->
      {noreply, State#{
                  streams=>stream_delete(PID,Str),
                  mpid=>maps:remove(PID,MPID)
                 }};
    error ->
      {noreply, State}
  end;
 

handle_info(_Info, State) ->
  lager:info("Unhandled info ~p",[_Info]),
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
      fun({S,D,_}) -> 
          S=/=StreamID
          orelse
          (D=/=Dir andalso D=/=undefined)
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
  {ok, PID}=tpic2_client:start(binary_to_list(Host),
                               Port,
                               #{
                                 stream=>0,
                                 announce=>[]
                                }),
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

