-module(tpic2_cmgr).
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
    {ok, #{
       peers=>#{}
      }
    }.

handle_call({register, PubKey, _Stream, _Direction, _PID}=Msg, From, State) ->
  {PID, State2} = get_conn(PubKey, State),
  PID ! {'$gen_call', From, Msg},
  {noreply, State2};

handle_call({pick, PubKey}, _From, State) ->
  {PID, State2} = get_conn(PubKey, State),
  {reply, {ok, PID}, State2};

handle_call(_Request, _From, State) ->
    {reply, unhandled, State}.

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

get_conn(PubKey, #{peers:=P}=State) ->
  case maps:find(PubKey, P) of
    error ->
      {ok,PID}=tpic2_peer:start_link(#{pubkey => PubKey}),
      {
       PID,
       State#{peers=>maps:put(PubKey, PID, P)}
      };
    {ok, PID} ->
      {PID, State}
  end.

