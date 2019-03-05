-module(tpic2_tls).
-behavior(ranch_protocol).

-export([start_link/4]).
-export([connection_process/5,loop1/1,loop/1,send_msg/2, system_continue/3]).

-spec start_link(ranch:ref(), ssl:sslsocket(), module(), cowboy:opts()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
  Pid = proc_lib:spawn_link(?MODULE, connection_process,
                            [self(), Ref, Socket, Transport, Opts]),
  {ok, Pid}.

-spec connection_process(pid(), ranch:ref(), ssl:sslsocket(), module(), cowboy:opts()) -> ok.
connection_process(Parent, Ref, Socket, Transport, Opts) ->
  ok = ranch:accept_ack(Ref),
  %Proto=ssl:negotiated_protocol(Socket),
  %lager:info("Transport ~p NegProto ~p",[Transport, Proto]),
  {ok,PeerInfo}=ssl:connection_information(Socket),
  Transport:setopts(Socket, [{active, once},{packet,4}]),
  State=#{parent=>Parent,
          ref=>Ref,
          socket=>Socket,
          peerinfo=>PeerInfo,
          timer=>undefined,
          transport=>Transport,
          role=>server,
          opts=>Opts
         },
  tpic2_tls:send_msg({hello, server}, State),
  ?MODULE:loop1(State).

loop1(State=#{socket:=Socket,role:=_Role}) ->
  {ok,PC}=ssl:peercert(Socket),
  DCert=tpic2:extract_cert_info(public_key:pkix_decode_cert(PC,otp)),
  Pubkey=case DCert of
           #{pubkey:={'ECPoint', Point}} ->
             tpecdsa:minify(Point);
           _ ->
             undefined
         end,
  lager:info("Peer PubKey ~p ~p",[Pubkey,chainsettings:is_our_node(Pubkey)]),
  ?MODULE:loop(State#{pubkey=>Pubkey}).

loop(State=#{parent:=Parent, socket:=Socket, transport:=Transport, opts:=_Opts,
             timer:=TimerRef}) ->
  {OK, Closed, Error} = Transport:messages(),
  receive
    %% Socket messages.
    {OK, Socket, Data} ->
      handle_data(Data, State);
    {Closed, Socket} ->
      terminate(State, {socket_error, closed, 'The socket has been closed.'});
    {Error, Socket, Reason} ->
      terminate(State, {socket_error, Reason, 'An error has occurred on the socket.'});
    %% Timeouts.
    %{timeout, Ref, {shutdown, Pid}} ->
    %cowboy_children:shutdown_timeout(Children, Ref, Pid),
    %loop(State, Buffer);
    {timeout, TimerRef, Reason} ->
      timeout(State, Reason);
    {timeout, _, _} ->
      ?MODULE:loop(State);
    %% System messages.
    {'EXIT', Parent, Reason} ->
      exit(Reason);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {State});
    %% Messages pertaining to a stream.
    %{{Pid, StreamID}, Msg} when Pid =:= self() ->
    %?MODULE:loop(info(State, StreamID, Msg), Buffer);
    %% Exit signal from children.
    %Msg = {'EXIT', Pid, _} ->
    %?MODULE:loop(down(State, Pid, Msg), Buffer);
    %% Calls from supervisor module.
    {'$gen_call', {From, Tag}, state} ->
      From ! {Tag, State},
      ?MODULE:loop(State);
    {'$gen_call', {From, Tag}, _} ->
      From ! {Tag, {error, ?MODULE}},
      ?MODULE:loop(State);
    %% Unknown messages.
    Msg ->
      error_logger:error_msg("Received stray message ~p.~n", [Msg]),
      ?MODULE:loop(State)
  after 10000 -> %to avoid killing on code change
          ?MODULE:loop(State)
  end.

system_continue(_PID,_,{State}) ->
  ?MODULE:loop(State).

send_msg({hello, Role}, #{socket:=Socket, opts:=Opts}) ->
  Stream=maps:get(stream, Opts, undefined),
  ssl:send(Socket,msgpack:pack(#{null=><<"hello">>, i=>Role, s=>Stream}));

send_msg(Msg, #{socket:=Socket}) when is_map(Msg) ->
  ssl:send(Socket,msgpack:pack(Msg)).

handle_msg(#{null:=<<"hello">>, <<"s">>:=SID},State) ->
  send_msg(#{null=><<"hello_ack">>}, State),
  State#{
    sid=>SID
   };

handle_msg(Any,State) ->
  lager:error("Unknown message ~p",[Any]),
  State.

handle_data(Bin, State=#{socket:=Socket, transport:=Transport}) ->
  {ok,D}=msgpack:unpack(Bin),
  lager:info("Got mp ~p",[D]),
  State2=handle_msg(D, State),
  Transport:setopts(Socket, [{active, once}]),
  ?MODULE:loop(State2).

-spec terminate(_, _) -> no_return().
terminate(undefined, Reason) ->
  lager:info("Term undef"),
  exit({shutdown, Reason});
terminate(#{socket:=Socket}, Reason) ->
  lager:info("Term ~p",[Socket]),
  ssl:close(Socket),
  exit({shutdown, Reason}).

-spec timeout(_, _) -> no_return().
timeout(State, idle_timeout) ->
  terminate(State, {connection_error, timeout,
                    'Connection idle longer than configuration allows.'}).

