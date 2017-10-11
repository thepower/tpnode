-module(blockchain).
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
    T0=tables:init(#{index=>[address,cur]}),
    {ok,_,T1}=tables:insert(#{
                address=><<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>,
                cur=><<"FTT">>,
                amount=>21.12,
                t=>1507586415,
                seq=>5
               }, T0),
    {ok,_,T2}=tables:insert(#{
                address=><<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>,
                cur=><<"KAKA">>,
                amount=>1,
                t=>1507586915,
                seq=>1
               }, T1),
    {ok, #{
       table=>T2,
       nodeid=>tpnode_tools:node_id()
      }
    }.

handle_call({get_addr, Addr}, _From, #{table:=Table}=State) ->
    case tables:lookup(address,Addr,Table) of
        {ok,E} ->
            {reply,
             lists:foldl(
               fun(#{cur:=Cur}=E1,A) -> 
                       maps:put(Cur,
                                maps:without(['address','_id'],E1),
                                A)
               end, 
               #{},
               E), State};
        _ ->
            {reply, not_found, State}
    end;

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

