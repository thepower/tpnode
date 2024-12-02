-module(tpnode_yggpeers).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,peers/0,peers/1,actual_peers/0]).

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

init([]) ->
    logger:set_process_metadata(#{domain=>[yggstack]}),
    erlang:send_after(20000,self(),sync),
    {ok, #{timer => erlang:send_after(10000,self(),sync)}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    logger:info("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(sync, State=#{timer:=T}) ->
  T1=case erlang:read_timer(T) of
       false -> % restart expired timer
         erlang:send_after(30000,self(),sync);
       N when is_integer(N) -> % keep running timer
         T
     end,
  P=case application:get_env(tpnode,ygg_peers,local) of
      local ->
        peers();
      URL when is_list(URL) ->
        peers(URL)
    end,
  Actual=actual_peers(),
  case length(P--Actual)>0 of
    true ->
      logger:notice("To sync ~p",[P--Actual]);
    false -> ok 
  end,
  lists:foreach(fun(ToAdd) ->
                    yggstack:add_peer(list_to_binary(ToAdd))
                end, P--Actual),

  {noreply, State#{timer=>T1}};

handle_info(_Info, State) ->
  logger:info("Got info ~w~n",[_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
    logger:info("Terminate yggstack ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

peers() ->
  Me=tpecdsa:shortpub(nodekey:get_pub()),
  lists:foldl(
    fun(#{pubkey:=PK,hostname:=Addr,port:=Port},A) ->
        SPK=tpecdsa:shortpub(PK),
        case SPK==Me of
          true -> A;
          false -> 
            URI=uri_string:recompose(#{
                                    host => Addr,
                                    port=>Port,
                                    scheme => "tls",
                                    path => [],
                                    query=>uri_string:compose_query([{"key",binary:encode_hex(SPK)}])
                                   }),
            [URI|A]
        end
    end, [], discovery:lookup(<<"yggpeer">>)).


peers(URL) ->
  #{path:=Path}=uri_string:parse(URL),
  {ok,List}=msgpack:unpack(tpapi2:httpget(URL,Path)),
  Me=tpecdsa:shortpub(nodekey:get_pub()),
  lists:foldl(
    fun(#{<<"pubkey">>:=PK,<<"hostname">>:=Addr,<<"port">>:=Port},A) ->
        SPK=tpecdsa:shortpub(PK),
        case SPK==Me of
          true -> A;
          false -> 
            URI=uri_string:recompose(#{
                                       host => Addr,
                                       port=>Port,
                                       scheme => "tls",
                                       path => [],
                                       query=>uri_string:compose_query([{"key",binary:encode_hex(SPK)}])
                                      }),
            [URI|A]
        end
    end, [], List).


actual_peers() ->
  case yggstack:control(getPeers) of
    #{<<"response">> := #{ <<"peers">> := List }} ->
      %[ binary_to_list(R) || #{<<"remote">>:=R} <- List ]
      lists:map(
        fun(#{<<"remote">>:=R,<<"key">>:=K}) ->
            SPK=binary:decode_hex(K),
            uri_string:recompose(
              maps:put(query,
                       uri_string:compose_query([{"key",binary:encode_hex(SPK)}]),
                       uri_string:parse(R)))
        end, List)
  end.

