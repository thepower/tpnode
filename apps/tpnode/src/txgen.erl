-module(txgen).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,process/1,bals/0]).

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
	{ok, #{
	   ticktimer=>erlang:send_after(6000, self(), ticktimer)
	  }
	}.

handle_call(_Request, _From, State) ->
    {reply, unknown, State}.

handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(ticktimer, 
			#{ticktimer:=Tmr}=State) ->
	catch erlang:cancel_timer(Tmr),
	process(25),
	{noreply,State#{
			   ticktimer=>erlang:send_after(5000, self(), ticktimer)
			  }
    };

handle_info(_Info, State) ->
    lager:info("Unknown info ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

bals() ->
	{ok,[L]}=file:consult("txgen.txt"),
	RS=lists:foldl(fun({Addr,_PKey},Acc) -> 
						   Ledger=ledger:get(Addr),
						   Bal=bal:get_cur(<<"FTT">>,Ledger),
						   [Bal|Acc]
				   end,[], L),
	{median(lists:sort(RS)),lists:sum(RS)/length(RS),lists:sum(RS),length(RS)}.

process(N) ->
	{ok,[L]}=file:consult("txgen.txt"),
	Addrs=lists:map(fun({Addr,_PKey}) -> Addr end, L),
	AL=length(Addrs),
	Prop=N/(AL*(AL-1)),
	PickAddr=fun(Addr0) ->
					 lists:map(
					   fun({_,A}) -> A end,
					   lists:sort(
						 lists:filtermap(fun(A0) when A0==Addr0 -> false;
											(A0) -> 
												 {true,{rand:uniform(),A0}}
										 end, Addrs)
						)
					  )
			 end,
	L1=lists:foldl(fun({Addr,_PKey},Acc) -> 
						   Ledger=ledger:get(Addr),
						   Bal=bal:get_cur(<<"FTT">>,Ledger),
						   Seq0=bal:get(seq,Ledger),
						   if(Bal==0) -> Acc;
							 true ->
								 ToList=PickAddr(Addr),
								 TS=Bal/length(ToList),
								 {_,TR}=lists:foldl(
								   fun(To,{Seq,Acc1}) ->
										   R0=rand:uniform(),
										   Amount=round((rand:uniform(100)/100)*TS),
										   if(Amount>0 andalso R0<Prop) ->
												 Tx=#{
												   amount=>Amount,
												   cur=><<"FTT">>,
												   extradata=>jsx:encode(#{}),
												   from=>Addr,
												   to=>To,
												   seq=>Seq+1,
												   timestamp=>os:system_time(millisecond)
												  },
												 STX=tx:sign(Tx,_PKey),
												 {Seq+1,Acc1++[
															   {{naddress:encode(Addr),
																 naddress:encode(To),
																 Amount},
																STX
																}]};
											 true ->
												 {Seq,Acc1}
										   end
								   end, {Seq0,[]}, ToList),
								 Acc++TR
						   end
				   end,[], L),
	lists:map(
	  fun({T1,_TX}) ->
			  case txpool:new_tx(_TX) of
				  {ok, TXID} ->
					  {T1,TXID};
				  _ ->
					  {T1, error}
			  end
	  end, L1).

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

