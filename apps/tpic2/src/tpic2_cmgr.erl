-module(tpic2_cmgr).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, start_link/1, pick/1, send/2, lookup_trans/1, add_trans/2, peers/0,
        inc_usage/2,add_peers/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [#{}], []).

pick(PubKey) ->
  gen_server:call(?MODULE, {pick, PubKey}).

send(PubKey, Message) ->
  gen_server:call(?MODULE, {peer, PubKey, Message}).

peers() ->
  gen_server:call(?MODULE,peers).

lookup_trans(Token) ->
  case ets:lookup(tpic2_trans,Token) of
    [{Token,Pid,_}] ->
      {ok, Pid};
    _ ->
      error
  end.

add_peers(List) ->
  KnownPeers=lists:flatten([ maps:get(addr,Peer) || Peer <- tpic2:peers() ]),
  New=List--KnownPeers,
  [ tpic2_client:start(Host,Port,#{}) || {Host, Port} <- New ].

add_trans(Token, Pid) ->
  ets:insert(tpic2_trans,{Token,Pid,erlang:system_time(second)+300}).

inc_usage(Stream, Service) ->
  case ets:lookup(tpic2_usage,{Stream,Service}) of
    [{_,N}] ->
      ets:insert(tpic2_usage,{{Stream,Service},N+1});
    _ ->
      ets:insert(tpic2_usage,{{Stream,Service},1})
  end.


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Opts]) ->
  erlang:send_after(1000,self(), init_peers),
  erlang:send_after(3000,self(), init_peers),
  ets:new(tpic2_trans,[set,public,named_table]),
  ets:new(tpic2_usage,[set,public,named_table]),
  {ok, #{
         opts=>Opts,
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
  {reply, 
   maps:remove(nodekey:get_pub(), P),
   State};

handle_call(_Request, _From, State) ->
    {reply, unhandled, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, #{cleanup:=ClTmr,peers:=P}=State) ->
  erlang:cancel_timer(ClTmr),
  ets:select_delete(tpic2_trans,
                    [{{'$1','$2','$3'},
                      [{'<','$3',{const,os:system_time(second)}}],
                      [true]}]),
  PeersAddrs=maps:fold(fun(Key,PID,Acc) ->
                           [{Key,gen_server:call(PID,addr)}|Acc]
                       end,[],P),

  file:write_file(peers_db(), io_lib:format("~p.~n",[PeersAddrs])),
  {noreply,
   State#{
     cleanup=>erlang:send_after(30000,self(), cleanup)
    }
  };

handle_info(init_peers, State=#{opts:=#{get_peers:=GP}=Opts}) when is_function(GP,1) ->
  try
    GPeers=GP(Opts),
    MyKey=nodekey:get_pub(),
    State1=lists:foldl(
             fun({PubKey,_},Acc) when MyKey==PubKey ->
                 Acc;
                ({PubKey,IPS},Acc) ->
                 {PID, Acc1}=get_conn(PubKey, Acc),
                 lists:foreach(fun({IP,Port}) ->
                                   gen_server:call(PID,{add,IP,Port})
                               end, IPS),
                 Acc1
             end, State, GPeers),
    {noreply, State1}
  catch _:_ ->
          Peers=maps:get(peers,application:get_env(tpnode,tpic,#{}),[]),
          lists:foreach(fun({Host,Port}) ->
                            tpic2_client:start(Host,Port,#{})
                        end, Peers),
          {noreply, State}
  end;


handle_info(init_peers, State) ->
  try
    {ok,[DBPeers]}=file:consult(peers_db()),
    MyKey=nodekey:get_pub(),
    State1=lists:foldl(
             fun({PubKey,_},Acc) when MyKey==PubKey ->
                 Acc;
                ({PubKey,IPS},Acc) ->
                 {PID, Acc1}=get_conn(PubKey, Acc),
                 lists:foreach(fun({IP,Port}) ->
                                   gen_server:call(PID,{add,IP,Port})
                               end, IPS),
                 Acc1
             end, State, DBPeers),
    {noreply, State1}
  catch _:_ ->
          Peers=maps:get(peers,application:get_env(tpnode,tpic,#{}),[]),
          lists:foreach(fun({Host,Port}) ->
                            tpic2_client:start(Host,Port,#{})
                        end, Peers),
          {noreply, State}
  end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

peers_db() ->
  try
    utils:dbpath(peers)
  catch _:_ ->
          "db/peers_" ++ atom_to_list(node())
  end.

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

