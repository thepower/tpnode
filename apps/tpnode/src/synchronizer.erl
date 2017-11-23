-module(synchronizer).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    pg2:create(?MODULE),
    pg2:join(?MODULE,self()),
    {ok, #{
       myoffset=>undefined,
       offsets=>#{},
       timer5=>erlang:send_after(5000, self(), selftimer5),
       ticktimer=>erlang:send_after(6000, self(), ticktimer),
       tickms=>10000,
       prevtick=>0
      }}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({hello, PID, WallClock}, State) ->
    Behind=erlang:system_time(microsecond)-WallClock,
    lager:debug("Hello from ~p our clock diff ~p",[PID,Behind]),
    {noreply, State#{
                offsets=>maps:put(PID,
                                  {
                                   Behind,
                                   erlang:system_time(seconds)
                                  },
                                  maps:get(offsets,State,#{})
                                 )
               }};

handle_cast({setdelay,Ms}, State) when Ms>900 ->
    lager:info("Setting ~p ms block delay",[Ms]),
    {noreply, State#{
                tickms=>Ms
               }
    };

handle_cast(_Msg, State) ->
    lager:info("Cast ~p",[_Msg]),
    {noreply, State}.

handle_info(ticktimer, 
            #{meandiff:=MeanDiff,ticktimer:=Tmr,tickms:=Delay,prevtick:=_T0}=State) ->
    T=erlang:system_time(microsecond),
    MeanMs=round((T+MeanDiff)/1000),
    Wait=Delay-(MeanMs rem Delay),
%    lager:info("Time to tick. Mean hospital time ~w, next in ~w, last ~w",
%               [(MeanMs rem 3600000)/1000,Wait,(T-_T0)/1000]
%              ),
    gen_server:cast(txpool,prepare),
    erlang:send_after(200, whereis(mkblock), preocess),
%    gen_server:cast(mkblock,process),

    catch erlang:cancel_timer(Tmr),
    {noreply,State#{
               ticktimer=>erlang:send_after(Wait, self(), ticktimer),
               prevtick=>T
              }
    };



handle_info(selftimer5, #{timer5:=Tmr,offsets:=Offs}=State) ->
    Friends=pg2:get_members(synchronizer)--[self()],
    {Avg,Off2}=lists:foldl(
          fun(Friend,{Acc,NewOff}) ->
                  case maps:get(Friend,Offs,undefined) of
                      undefined ->
                          {Acc, NewOff};
                      {LOffset,LTime} ->
                          {[LOffset|Acc],maps:put(Friend,{LOffset,LTime},NewOff)}
                  end
          end,{[],#{}}, Friends),
    MeanDiff=median(Avg),
    T=erlang:system_time(microsecond),
    lists:foreach(
      fun(Pid)-> 
              gen_server:cast(Pid, {hello, self(), T}) 
      end, 
      Friends
     ),
    MeanMs=round((T-MeanDiff)/1000),
    if(Friends==[]) ->
          lager:debug("I'm alone in universe my time ~w",[(MeanMs rem 3600000)/1000]);
      true ->
          lager:info("~s I have ~b friends, and mean hospital time ~w, mean diff ~w",
                     [node(),length(Friends),(MeanMs rem 3600000)/1000,MeanDiff/1000]
                    )
    end,

    catch erlang:cancel_timer(Tmr),

    {noreply,State#{
               timer5=>erlang:send_after(10000-(MeanMs rem 10000)+500, self(), selftimer5),
               offsets=>Off2,
               meandiff=>MeanDiff
              }
    };

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
median([]) -> 0;
median([E]) -> E;
median(List) ->
    LL=length(List),
    DropL=(LL div 2)-1,
    {_,[M1,M2|_]}=lists:split(DropL,List),
    case LL rem 2 of
        0 -> %even elements
            (M1+M2)/2;
        1 -> %odd
            M2
    end.


