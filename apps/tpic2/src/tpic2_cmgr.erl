-module(tpic2_cmgr).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, pick/1, send/2, lookup_trans/1, add_trans/2]).

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

pick(PubKey) ->
  gen_server:call(?MODULE, {pick, PubKey}).

send(PubKey, Message) ->
  gen_server:call(?MODULE, {peer, PubKey, Message}).

lookup_trans(Token) ->
  case ets:lookup(tpic2_trans,Token) of
    [{Token,Pid,_}] ->
      {ok, Pid};
    _ ->
      error
  end.

add_trans(Token, Pid) ->
  ets:insert(tpic2_trans,{Token,Pid,erlang:system_time(second)+300}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  erlang:send_after(100,self(), init_peers),
  ets:new(tpic2_trans,[set,public,named_table]),
  {ok, #{
     peers=>#{},
     cleanup=>erlang:send_after(30000,self(), cleanup)
    }
  }.

handle_call({peer, PubKey, Msg}, From, State) ->
  {PID, State2} = get_conn(PubKey, State),
  PID ! {'$gen_call', From, Msg},
  {noreply, State2};

handle_call({pick, PubKey}, _From, State) ->
  {PID, State2} = get_conn(PubKey, State),
  {reply, {ok, PID}, State2};

handle_call(peers, _From, #{peers:=P}=State) ->
  {reply, P, State};

handle_call(_Request, _From, State) ->
    {reply, unhandled, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, #{cleanup:=ClTmr}=State) ->
  erlang:cancel_timer(ClTmr),
  ets:select_delete(tpic2_trans,
                    [{{'$1','$2','$3'},
                      [{'<','$3',{const,os:system_time(second)}}],
                      [true]}]),
  {noreply,
   State#{
     cleanup=>erlang:send_after(30000,self(), cleanup)
    }
  };

handle_info(init_peers, State) ->
  Peers=maps:get(peers,application:get_env(tpnode,tpic,#{}),[]),
  lists:foreach(fun({Host,Port}) ->
                    tpic2_client:start(Host,Port,#{})
                end, Peers),
  {noreply, State};

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

