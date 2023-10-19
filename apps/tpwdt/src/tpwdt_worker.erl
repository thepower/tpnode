-module(tpwdt_worker).
-include("include/tplog.hrl").

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok, #{tmr=>erlang:send_after(5000,self(),check)}}.

handle_call(_Request, _From, State) ->
    ?LOG_NOTICE("Unknown call ~p",[_Request]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    ?LOG_NOTICE("Unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(check, #{tmr:=T0}=State) ->
  erlang:cancel_timer(T0),
  Now=os:system_time(millisecond),
  LBH=maps:get(hash,blockchain:last_meta()),

  case maps:get(lbh,State, <<>>) of
    L when L==LBH ->
      LBT=maps:get(lbt,State),
      if (Now-LBT > 55000) ->
           logger:error("Last block does not change for ~p ms, restarting",[Now-LBT]),
           tpnode:restart(),
           {noreply, State#{
                       lc=>Now,
                       tmr=>erlang:send_after(10000,self(),check)
                      }};
         true ->
           {noreply, maps:merge(#{lbt=>Now},
                                State#{lbh=>LBH,
                                       lc=>Now,
                                       tmr=>erlang:send_after(10000,self(),check)}
                               )}
      end;
    _ ->
      {noreply, State#{lbt=>Now,
                       lbh=>LBH,
                       lc=>Now,
                       tmr=>erlang:send_after(10000,self(),check)}}
  end;

handle_info(_Info, State) ->
    ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


