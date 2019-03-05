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

handle_call({add, _, IP, Port}, _From, #{peer_ipport:=IPP}=State) ->
  IPP2=[{IP,Port}|(IPP--{IP,Port})],
  {reply, IPP2, State#{peer_ipport=>IPP2}};

handle_call({register, StreamID, Dir, PID},
            _From,
            #{mpid:=MPID, streams:=Str}=State) ->
  case maps:find(PID,MPID) of
    {ok, _} ->
      {reply, {exists, self()}, State};
    error ->
      monitor(process,PID),
      {reply, {ok, self()},
       State#{
         streams=>[{StreamID,Dir,PID}|Str],
         mpid=>maps:put(PID,
                        {StreamID,Dir},
                        maps:get(mpid,State,#{})
                       )
        }
      }
  end;

handle_call(_Request, _From, State) ->
  lager:info("Unhandled call ~p",[_Request]),
  {reply, unhandled, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

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
                  streams=>lists:keydelete(PID,3,Str),
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

open_control(#{peer_ipport:=[{Host,Port}|RestIPP]}=State) ->
  {ok, PID}=tpic2_client:start(Host, Port, #{stream=>0}),
  State#{
    peer_ipport=>RestIPP++[{Host,Port}],
    outctl=>PID
   }.




