-module(yggstack).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,control/2,control/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Config], []).

control(SocketPath, {addpeer, URI}) ->
  control(SocketPath, 
          #{
            <<"arguments">> => #{<<"uri">> => URI},
            <<"request">> => <<"addpeer">>
           }
         );

control(SocketPath, Command) when is_atom(Command) ->
  control(SocketPath, 
          #{ <<"request">> => atom_to_binary(Command) }
         );

control(SocketPath, {removepeer, URI}) ->
  control(SocketPath, 
          #{
            <<"arguments">> => #{<<"uri">> => URI},
            <<"request">> => <<"removepeer">>
           }
         );

control(SocketPath, Command) when is_map(Command) ->
  case gen_tcp:connect({local,SocketPath}, 0, [local]) of
    {error,Reason} ->
      {error, Reason};
    {ok, P} ->
      ok = inet:setopts(P, [binary, {packet,raw},{active,true}]),
      ok = gen_tcp:send(P, jsx:encode(Command)),
      Resp=fun F(Acc) ->
          receive
            {tcp,P,Data} ->
              F([Data|Acc]);
            {tcp_closed,P} ->
              gen_tcp:close(P),
              Acc
          after 5000 ->
                  gen_tcp:close(P),
                  Acc
          end
      end([]),
      jsx:decode(list_to_binary(lists:reverse(Resp)),[return_maps])
  end.

control(Command) ->
  control(gen_server:call(?SERVER,socket),Command).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([#{admin:=AdminSocket}=Config]) ->
    logger:set_process_metadata(#{domain=>[yggstack]}),
    Executable=case ygg:executable() of
                 false -> throw(no_yggstack_found);
                 L -> L
               end,
    {ok, Cwd} = file:get_cwd(),
    ProxyPath=filename:join(Cwd,"yggstack.sock"),
    ConfigPath=filename:join(Cwd,"yggstack.conf"),
    ok=file:write_file(ConfigPath,ygg:config_file(Config)),
    ExportPorts=lists:foldl(
      fun({YggPort,LocalPort},A) ->
          ["-remote-tcp", integer_to_list(YggPort)++":127.0.0.1:"++integer_to_list(LocalPort)|A]
      end,[], maps:get(export,Config,[])),
    case yggstack:control(AdminSocket,getself) of
      {error, _} ->
        ok;
      #{} ->
        os:cmd("pkill -f "++filename:basename(ygg:executable())),
        timer:sleep(1)
    end,
    H=erlang:open_port(
        {spawn_executable, Executable},
        [{args, ["-useconffile", ConfigPath, "-socks", ProxyPath|ExportPorts]},
         exit_status,
         %eof,
         stderr_to_stdout,
         binary
        ]),
    erlang:link(H),
    spawn(fun() ->
              timer:sleep(1000),
              ok=file:delete(ConfigPath)
          end),
    {ok, #{handler=>H, socket=>AdminSocket,timer=>make_ref(),queue=>[]}}.

handle_call(socket, _From, #{socket:=S}=State) ->
  {reply, S, State};

handle_call({peer, Act, Url}, _From, #{timer:=T,queue:=Q}=State) when Act==add orelse Act==del ->
  Q1=[{Act,Url}|Q],
  T1=case erlang:read_timer(T) of
       false -> % restart expired timer
         erlang:send_after(10000,self(),apply);
       N when is_integer(N) -> % keep running timer
         T
     end,
  {reply, ok, State#{timer=>T1,queue=>Q1}};


handle_call(peers, _From, #{socket:=AdminSocket}=State) ->
  R=try
      lists:map(
        fun(#{<<"remote">>:=R,<<"key">>:=K}) ->
            {hex:decode(K),[R]}
        end,
        maps:get(<<"peers">>,
                 maps:get(<<"response">>,
                          yggstack:control(AdminSocket, getPeers)
                         )
                )
       )
    catch _:_ ->
            error
    end,
  {reply, R, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  logger:info("BV Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(apply, State=#{queue:=Q, socket:=AdminSocket}) ->
  R=lists:map(fun({add,Peer}) ->
                  yggstack:control(AdminSocket,{addpeer,Peer});
                 ({del,Peer}) ->
                  yggstack:control(AdminSocket,{removepeer,Peer});
                 (_) ->
                  unknown
              end, lists:reverse(Q)),
  logger:notice("yggstack apply peers ~p",[R]),
  {noreply, State#{queue=>[]}};

handle_info({Port,{exit_status,Res}}, State=#{handler:=Port}) ->
  logger:notice("yggstack terminated res ~w",[Res]),
  {stop,
   if Res==0 -> normal;
      true -> timer:sleep(1000), {exit_status, Res} end,
   State};

handle_info({Port,{data,Text}}, State=#{handler:=Port,watchdog:=_}) ->
  lists:foreach(
    fun(Str) ->
        case re:run(Str,"^(\\d{4}.\\d{2}.\\d{2} \\d{2}:\\d{2}:\\d{2}\\s*)(?<MSG>\.\*)",[{capture,all_names,list}]) of
          {match,[Stripped]} ->
            logger:info("yggstack> ~s~n",[Stripped]);
          nomatch ->
            logger:info("yggstack> ~s~n",[Str])
        end
    end,
    binary:split(string:chomp(Text),<<"\n">>,[global])
   ),
  {noreply, State};

handle_info({Port,{data,Text}}, State=#{handler:=Port}) when is_binary(Text) ->
  Info=erlang:port_info(Port),
  if Info == undefined ->
       logger:info("yggstack> ~s~n",[string:chomp(Text)]),
       {noreply, State};
     true ->
       OsPid=proplists:get_value(os_pid,Info),
       true=is_integer(OsPid),
       logger:info("yggstack up pid ~w",[OsPid]),
       PID=yggstack_wdt:start_link(self(), OsPid),
       handle_info({Port,{data,Text}}, State#{watchdog=>PID,pid=>OsPid})
  end;

handle_info(_Info, State) ->
  logger:info("Got info ~w ~w~n",[_Info, maps:keys(State)]),
  {noreply, State}.

terminate(_Reason, _State) ->
    logger:info("Terminate yggstack ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

