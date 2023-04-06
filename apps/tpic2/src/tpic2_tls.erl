-module(tpic2_tls).
-include("include/tplog.hrl").
-behavior(ranch_protocol).

-export([start_link/4]).
-export([connection_process/5,loop1/1,loop/1,send_msg/2, system_continue/3, my_streams/0]).

-spec start_link(ranch:ref(), ssl:sslsocket(), module(), cowboy:opts()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
  Pid = proc_lib:spawn_link(?MODULE, connection_process,
                            [self(), Ref, Socket, Transport, Opts]),
  {ok, Pid}.

-spec connection_process(pid(), ranch:ref(), ssl:sslsocket(), module(), cowboy:opts()) -> ok.
connection_process(Parent, Ref, Socket, Transport, Opts) ->
  ok = ranch:accept_ack(Ref),
  PeerPK=case ssl:peercert(Socket) of
    {ok, PC} ->
      DCert=tpic2:extract_cert_info(public_key:pkix_decode_cert(PC,otp)),
      case DCert of
        #{pubkey:=Der} ->
          Der;
        _ ->
          ?LOG_NOTICE("Unknown cert ~p",[DCert]),
          undefined
      end;
    {error, no_peercert} ->
      undefined
  end,

  ?LOG_DEBUG("tpic2_tls accept ~p",[PeerPK]),

  case ssl:negotiated_protocol(Socket) of
    {ok, Proto} ->
      ?LOG_DEBUG("tpic2_tls protocol ~s",[Proto]),
      conn_proto(Parent, Ref, Socket, Transport, Opts, Proto, PeerPK);
    _ ->
      ssl:send(Socket,msgpack:pack(#{null=><<"no_protocol">>})),
      Transport:close(Socket)
  end.

conn_proto(Parent, Ref, Socket, Transport, Opts, <<"h2">>,undefined) ->
  cowboy_http2:init(Parent, Ref, Socket, Transport, undefined, Opts);
conn_proto(Parent, Ref, Socket, Transport, Opts, <<"http/1.1">>, undefined) ->
  cowboy_http:init(Parent, Ref, Socket, Transport, undefined, Opts);

conn_proto(Parent, Ref, Socket, Transport, Opts, <<"h2">>, PubKey) ->
  IsOurNode=chainsettings:is_our_node(PubKey),
  if(IsOurNode==false) ->
      ssl:send(Socket,<<"unknown_node">>),
      ?LOG_NOTICE("tpic2_tls h2 connection unknwon key ~p",[PubKey]),
      Transport:close(Socket);
    true ->
      cowboy_http2:init(Parent, Ref, Socket, Transport, undefined, Opts)
  end;

conn_proto(Parent, Ref, Socket, Transport, Opts, <<"http/1.1">>, PubKey) ->
  IsOurNode=chainsettings:is_our_node(PubKey),
  if(IsOurNode==false) ->
      ssl:send(Socket,<<"unknown_node">>),
      ?LOG_NOTICE("tpic2_tls http/1.1 connection unknown key ~p",[PubKey]),
      Transport:close(Socket);
    true ->
      cowboy_http:init(Parent, Ref, Socket, Transport, undefined, Opts)
  end;

conn_proto(_Parent, _Ref, Socket, Transport, _Opts, <<"tpic2">>, undefined) ->
  ssl:send(Socket,msgpack:pack(#{null=><<"unknown_node">>})),
  timer:sleep(1000),
  Transport:close(Socket),
  done;

conn_proto(Parent, Ref, Socket, Transport, Opts, <<"tpic2">>, PeerPK) ->
  {ok,PeerInfo}=ssl:connection_information(Socket),
  Transport:setopts(Socket, [{active, once},{packet,4}]),
  State=#{
          parent=>Parent,
          ref=>Ref,
          socket=>Socket,
          peerinfo=>PeerInfo,
          timer=>undefined,
          transport=>Transport,
          protocol => tpic2,
          peerpk => PeerPK,
          nodeid=> try
                     nodekey:get_pub()
                   catch _:_ -> atom_to_binary(node(),utf8)
                   end,
          role=>server,
          opts=>Opts
         },
  ?MODULE:loop1(State);

conn_proto(_Parent, _Ref, Socket, Transport, _Opts, _, _) ->
  ssl:send(Socket,msgpack:pack(#{null=><<"error">>,error=><<"bad protocol">>})),
  Transport:close(Socket).

loop1(State=#{socket:=Socket,role:=Role,opts:=Opts,
              transport:=Transport,peerpk:=Pubkey}) ->
  %{ok,PC}=ssl:peercert(Socket),
  %DCert=tpic2:extract_cert_info(public_key:pkix_decode_cert(PC,otp)),
  %Pubkey=case DCert of
  %         #{pubkey:=Der} ->
  %           Der;
  %         _ ->
  %           ?LOG_NOTICE("Unknown cert ~p",[DCert]),
  %           undefined
  %       end,
  IsItMe=tpecdsa:cmp_pubkey(Pubkey)==tpecdsa:cmp_pubkey(nodekey:get_pub()),
  IsOurNode=chainsettings:is_our_node(Pubkey),
  ?LOG_INFO("Peer PubKey ~s ~p",[hex:encode(Pubkey), IsOurNode]),

  if IsItMe andalso Role==server ->
      tpic2_tls:send_msg(hello, State),
      ?LOG_NOTICE("I received connection from myself, dropping session"),
      timer:sleep(1000),
      Transport:close(Socket),
      done;

     IsItMe ->
      tpic2_tls:send_msg(hello, State),
      ?LOG_NOTICE("I connected to myself, dropping session"),
      timer:sleep(1000),
      Transport:close(Socket),
      done;

     Role == server andalso IsOurNode == false -> %server, unknonwn peer
      tpic2_tls:send_msg(unknown_node, State),
      timer:sleep(1000),
      Transport:close(Socket),
      done;

     Role == server -> %server, known peer
      tpic2_tls:send_msg(hello, State),
      {ok,PPID}=gen_server:call(tpic2_cmgr, {peer,Pubkey, {register, undefined, in, self()}}),
      ?MODULE:loop(State#{pubkey=>Pubkey,peerpid=>PPID});

     IsOurNode == false -> %client unknown node
      tpic2_tls:send_msg(unknown_node, State),
      {IP, Port} = maps:get(address, State),
      gen_server:call(tpic2_cmgr,{peer, Pubkey, {del, IP, Port}, unknown_node}),
      timer:sleep(5000),
      Transport:close(Socket),
      done;

    true -> %client, known node
      tpic2_tls:send_msg(hello, State),
      Stream=maps:get(stream, Opts, 0),
      {IP, Port} = maps:get(address, State),
      gen_server:call(tpic2_cmgr,{peer, Pubkey, {add, IP, Port}}),
      WhatToDo=if Stream == 0 ->
                    case gen_server:call(tpic2_cmgr,{peer, Pubkey, active_out}) of
                      false ->
                        ok;
                      Pid when Pid == self() ->
                        ok;
                      Pid when is_pid(Pid) ->
                        ?LOG_INFO("Add address ~p:~p to peer and shutdown",[IP,Port]),
                        tpic2_tls:send_msg(dup, State),
                        timer:sleep(6000),
                        Transport:close(Socket),
                        shutdown
                    end;
                  true -> ok
               end,
      if WhatToDo==shutdown ->
           done;
         true ->
           ?MODULE:loop(State#{pubkey=>Pubkey})
      end
  end.

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
    {'$gen_cast', {send, Process, ReqID, Payload}} when is_binary(Payload) ->
      {_,S1}=send_gen_msg(Process, ReqID, Payload, State),
      ?MODULE:loop(S1);
    {'$gen_call', {From, Tag}, {send, Process, ReqID, Payload}} when is_binary(Payload) ->
      {Res,S1}=send_gen_msg(Process, ReqID, Payload, State),
      From ! {Tag, Res},
      ?MODULE:loop(S1);
    {'$gen_call', {From, Tag}, peer} ->
      Peer=case Transport:peername(Socket) of
             {ok, {IP0,Port0}} ->
               {inet:ntoa(IP0), Port0};
             {ok, NonIP0} ->
               NonIP0;
             {error, _} ->
               error
           end,
      Me=case Transport:sockname(Socket) of
             {ok, {IP1,Port1}} ->
               {inet:ntoa(IP1), Port1};
             {ok, NonIP1} ->
               NonIP1;
             {error, _} ->
               error
           end,
      From ! {Tag, {Me, Peer}},
      ?MODULE:loop(State);
    {'$gen_call', {From, Tag}, _} ->
      From ! {Tag, {error, ?MODULE}},
      ?MODULE:loop(State);
    %% Unknown messages.
    Msg ->
      ?LOG_ERROR("Received stray message ~p.~n", [Msg]),
      ?MODULE:loop(State)
  after 10000 -> %to avoid killing on code change
          case send_msg(#{null=><<"KA">>},State) of
            ok -> ?MODULE:loop(State);
            {error, closed} ->
              exit(normal)
          end
  end.

system_continue(_PID,_,{State}) ->
  ?MODULE:loop(State).

send_gen_msg(Process, ReqID, Payload, State) ->
  try
    {ok, Unpacked} = msgpack:unpack(Payload),
    ?LOG_DEBUG("Send gen msg ~p: ~p",[ReqID, Unpacked])
  catch _:_ ->
          ?LOG_DEBUG("Send gen msg ~p: ~p",[ReqID, Payload])
  end,
  Res=send_msg(#{
      null=><<"gen">>,
      proc=>Process,
      req=>ReqID,
      data=>Payload}, State),
  {Res,State}.

send_msg(dup, #{socket:=Socket, opts:=Opts}) ->
  ?LOG_DEBUG("dup opts ~p",[Opts]),
  Dup=#{null=><<"duplicate">>},
  ssl:send(Socket,msgpack:pack(Dup));

send_msg(hello, #{socket:=Socket, opts:=Opts}) ->
  ?LOG_DEBUG("Hello opts ~p",[Opts]),
  Stream=maps:get(stream, Opts, 0),
  Announce=my_streams(),
  Cfg=application:get_env(tpnode,tpic,#{}),
  Port=maps:get(port,Cfg,40000),
  Hello=#{null=><<"hello">>,
          addrs=>tpic2:node_addresses(),
          port=>Port,
          sid=>Stream,
          v=>2,
          services=>Announce
         },
  ?LOG_DEBUG("Hello ~p",[Hello]),
  ssl:send(Socket,msgpack:pack(Hello));

send_msg(unknown_node, #{socket:=Socket, opts:=Opts}) ->
  ?LOG_DEBUG("send unknown_node and close conn to ~p",[Opts]),
  Hello=#{null=><<"unknown_node">>},
  ssl:send(Socket,msgpack:pack(Hello));

send_msg(Msg, #{socket:=Socket}) when is_map(Msg) ->
  ssl:send(Socket,msgpack:pack(Msg)).

handle_msg(#{null:=<<"KA">>}, State) ->
  State;

handle_msg(#{null:=<<"duplicate">>}, #{socket:=Socket}=State) ->
  ssl:close(Socket),
  State;

handle_msg(#{null:=<<"hello">>,
             <<"sid">>:=OldSID,
             <<"addrs">>:=Addrs,
             <<"port">>:=Port
            }=Pkt,
           #{pubkey:=PK,
             role:=Role,
             opts:=Opts}=State) ->
  {Reg,SID}=if Role==client ->
                 NS=maps:get(stream, Opts, 0),
                 {
                  {register, NS, out, self()},
                  NS
                 };
         Role==server ->
                 {
                  {register, OldSID, in, self()},
                  OldSID
                 }
      end,
  {ok, PPID}=gen_server:call(tpic2_cmgr, {peer,PK, Reg}),
  lists:foreach(fun(Addr) ->
                    gen_server:call(PPID, {add, binary_to_list(Addr), Port})
                end,
                Addrs),

  if SID==0 orelse SID==undefined ->
       Str=case maps:is_key(<<"services">>,Pkt) of
         false -> my_streams();
         true ->
           S0=maps:get(<<"services">>,Pkt),
           lists:usort(S0++my_streams())
       end,
       gen_server:call(PPID, {streams, Str});
     true -> ok
  end,

  send_msg(#{null=><<"hello_ack">>}, State),
  ?LOG_DEBUG("This is hello ack, new sid ~p",[SID]),
  State#{ sid=>SID };

handle_msg(#{null:=<<"gen">>,
             <<"proc">>:=Proc,
             <<"req">>:=ReqID,
%             <<"str">>:=Stream,
             <<"data">>:=Data
            }=_Pkt, #{pubkey:=PK, sid:=SID
                      %, transport:=Transport, socket:=Socket
                      }=State) ->
%      Peer=case Transport:peername(Socket) of
%             {ok, {IP0,Port0}} ->
%               {inet:ntoa(IP0), Port0};
%             {ok, NonIP0} ->
%               NonIP0;
%             {error, _} ->
%               error
%           end,
%      Me=case Transport:sockname(Socket) of
%             {ok, {IP1,Port1}} ->
%               {inet:ntoa(IP1), Port1};
%             {ok, NonIP1} ->
%               NonIP1;
%             {error, _} ->
%               error
%           end,
%
  try
    {ok, Unpacked} = msgpack:unpack(Data),
    ?LOG_DEBUG("Inbound msg sid ~p ReqID ~p proc  ~p: ~p",[SID, ReqID, Proc, Unpacked])
  catch _:_ ->
          ?LOG_DEBUG("Inbound msg sid ~p ReqID ~p proc ~p: ~p",[SID, ReqID, Proc, Data])
  end,

  tpic2_response:handle(PK, SID, ReqID, Proc, Data, State),
  State;

handle_msg(#{null := <<"hello_ack">>}, State) ->
  State;

handle_msg(Any,State) ->
  ?LOG_ERROR("Unknown message ~p",[Any]),
  State.

handle_data(Bin, State=#{socket:=Socket, transport:=Transport}) ->
  {ok,D}=msgpack:unpack(Bin),
%  ?LOG_INFO("Got mp ~p",[D]),
  State2=handle_msg(D, State),
  Transport:setopts(Socket, [{active, once}]),
  ?MODULE:loop(State2).

-spec terminate(_, _) -> no_return().
terminate(undefined, Reason) ->
  ?LOG_INFO("Term undef"),
  exit({shutdown, Reason});
terminate(#{socket:=Socket}, Reason) ->
  ?LOG_INFO("Term ~p",[Socket]),
  ssl:close(Socket),
  exit({shutdown, Reason}).

-spec timeout(_, _) -> no_return().
timeout(State, idle_timeout) ->
  terminate(State, {connection_error, timeout,
                    'Connection idle longer than configuration allows.'}).

my_streams() ->
  [<<"blockchain">>,
   <<"blockvote">>,
   <<"mkblock">>,
   <<"txpool">>
  ].

