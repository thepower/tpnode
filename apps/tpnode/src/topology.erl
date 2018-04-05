-module(topology).
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
%    gen_server:cast(self(), settings),
	Tickms=10000,
    {ok, #{
       ticktimer=>erlang:send_after(Tickms, self(), timer),
       tickms=>Tickms,
       prevtick=>0
      }}.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({tpic, _PeerID, <<16#be, _/binary>>=Payload}, State) ->
	try
		Beacon=beacon:check(Payload),
		lager:info("TOPO ~p beacon ~p", [_PeerID, Beacon]),
		{noreply, State}
	catch _:_ ->
			  {noreply, State}
	end;

handle_cast({tpic, _PeerID, _Payload}, State) ->
	lager:info("Bad TPIC received", []),
	{noreply, State};


handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(timer,
            #{ticktimer:=Tmr, tickms:=Delay}=State) ->
    T=erlang:system_time(microsecond),
	catch erlang:cancel_timer(Tmr),
	Peers=tpic:cast_prepare(tpic, <<"mkblock">>),
	lists:foreach(fun({N, #{authdata:=AD}}) ->
						  PK=proplists:get_value(pubkey, AD, <<>>),
						  lager:info("TOPO ~p: ~p", [N, PK]),
						  tpic:cast(tpic, N,
									{<<"beacon">>,
									 beacon:create(PK)
									}
								   );
					 (_) -> ok
				  end,
				  Peers),

    {noreply, State#{
               ticktimer=>erlang:send_after(Delay, self(), ticktimer),
               prevtick=>T
              }
    };

handle_info(_Info, State) ->
    lager:info("Unknown info ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

