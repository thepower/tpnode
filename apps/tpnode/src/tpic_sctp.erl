-module(tpic_sctp).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include_lib("kernel/include/inet.hrl").
-include_lib("kernel/include/inet_sctp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,resolve/1,call_all/3,call/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Settings) when is_map(Settings) ->
    gen_server:start_link({local, tpic}, ?MODULE, Settings, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

%streams:
%0 - socket control and neighbor discovery
%1 - real time (synchronization)

%2 - to mkblock chain 0
%3 - to mkblock chain N

%4 - to blockvote chain 0
%4 - to blockvote chain N

%5 - blockchain sync chain 0
%5 - blockchain sync chain N

init([]) ->
    throw('loadconfig');

init(#{port:=MyPort}=Args) when is_map(Args) ->
    {ok,S} = gen_sctp:open(MyPort, [{recbuf,65536},
                                    {ip,any},
                                    {active,true},
                                    inet6,
                                    {reuseaddr, true},
                                    {sctp_nodelay, true},
                                    {sctp_i_want_mapped_v4_addr, true},
                                    {sndbuf,65536}]),
    lager:info("Listening on ~p Socket ~p", [MyPort,S]),
    ok=gen_sctp:listen(S, true),
    erlang:send_after(1000,self(), connect_peers),
    PI=lists:foldl(
         fun({Host,Port},Acc) ->
                 case resolve(Host) of 
                     [] ->
                         Acc;
                     [E1] ->
                         mkmap:put({E1,Port},#{},Acc);
                     [E1|Rest] ->
                         lists:foldl(
                           fun(E2,Acc2) ->
                                   mkmap:add_key({E1,Port},{E2,Port},Acc2)
                           end, mkmap:put({E1,Port},#{},Acc),
                           Rest
                          )
                 end
         end, mkmap:new(), maps:get(peers, Args, [])
        ),
    lager:info("Init PI ~p",[PI]),
    {_,ExtRouting}=maps:fold(
                     fun (K,_V,{L,A}) ->
                             case maps:is_key(K,A) of
                                 false ->
                                     {L+1,maps:put(K,L,A)};
                                 true ->
                                     {K, A}
                             end
                     end,{2,#{<<"timesync">>=>1}}, maps:get(routing,Args,#{})),
    RRouting=maps:fold(
               fun(K,V,A) ->
                       maps:put(V,K,A)
               end, #{}, ExtRouting),
    {ok, Args#{
           socket=>S,
           extrouting=>ExtRouting,
           rrouting=>RRouting,
           peerinfo=>PI
          }
    }.

handle_call(peers, _From, #{peerinfo:=PI}=State) ->
    {reply, PI, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call({broadcast, Chan, Message}, _From,
            #{peerinfo:=PI,socket:=Socket}=State) ->
    Sent=mkmap:fold(
           fun(K,#{routes:=Routes}=_Ctx,Acc) ->
                   case proplists:get_value(ass,K) of
                       undefined -> Acc; %Not connected
                       AssID -> %connected
                           case maps:is_key(Chan,Routes) of
                               true ->
                                   SID=maps:get(Chan,Routes),
                                   R=gen_sctp:send(Socket, AssID, SID, Message),
                                   lager:info("I have assoc ~p, send ~p",[AssID,R]),
                                   if R==ok ->
                                          [{AssID,SID}|Acc];
                                      true ->
                                          Acc
                                   end;
                               false ->
                                   %no such channel
                                   Acc
                           end
                   end;
              (_,_,Acc) ->
                   Acc
           end, [], PI),
    lager:info("Broadcast ~p ~p bytes: ~p",[Chan,size(Message),Sent]),
    {reply, Sent, State};


handle_call({unicast, {Assoc, SID}, Message}, _From,
            #{peerinfo:=PI,socket:=Socket}=State) ->
    case mkmap:get({ass,Assoc}, PI, undefined) of
        undefined ->
            {reply, [], State};
        #{} ->
            R=gen_sctp:send(Socket, Assoc, SID, Message),
            lager:info("I have assoc ~p, send ~p",[Assoc,R]),
            if R==ok ->
                   {reply, [{Assoc,SID}], State};
               true ->
                   {reply, [], State}
            end
    end;

handle_call(_Request, _From, State) ->
    lager:info("unknown call ~p",[_Request]),
    {reply, ok, State}.

handle_cast({broadcast, Chan, Message}, 
            #{peerinfo:=PI,socket:=Socket}=State) ->
    Sent=mkmap:fold(
           fun(K,#{routes:=Routes}=_Ctx,Acc) ->
                   case proplists:get_value(ass,K) of
                       undefined -> ok; %Not connected
                       AssID -> %connected
                           case maps:is_key(Chan,Routes) of
                               true ->
                                   SID=maps:get(Chan,Routes),
                                   R=gen_sctp:send(Socket, AssID, SID, Message),
                                   lager:info("I have assoc ~p, send ~p",[AssID,R]),
                                   [{AssID,R}|Acc];
                               false ->
                                   %no such channel
                                   Acc
                           end
                   end;
              (_,_,Acc) ->
                   Acc
           end, [], PI),
    lager:info("Broadcast ~p ~p bytes: ~p",[Chan,size(Message),Sent]),
    {noreply, State};

handle_cast({unicast, {PeerID, SID}, Message}, 
            #{peerinfo:=_PI,socket:=Socket}=State) ->
    lager:debug("FIXME: check PerrID"),
    R=gen_sctp:send(Socket, PeerID, SID, Message),
    lager:info("I send to ~p:~p, send ~p",[PeerID,SID,R]),
    {noreply, State};

handle_cast(_Msg, State) ->
    lager:info("unknown cast ~p",[_Msg]),
    {noreply, State}.

%{sctp,Socket,IP,Port,{[{sctp_sndrcvinfo,0,0,[],0,0,0,0,396599080,3}],{sctp_assoc_change,comm_up,0,10,5,3}}}
%{sctp,Socket,IP,Port,{[{sctp_sndrcvinfo,0,0,[],0,0,0,0,396599080,3}],{sctp_paddr_change,{{0,0,0,0,0,0,0,1},1234},addr_confirmed,0,3}}}
%{sctp,Socket,IP,Port,{[{sctp_sndrcvinfo,0,0,[],0,0,0,396599081,396599081,3}],<<"Test 0">>}}

handle_info(connect_peers, #{peerinfo:=PI,socket:=S}=State) ->
    lager:debug("Connect peers"),
    lists:foldl(
      fun([{Host,Port}|_]=K,Acc) ->
              try
                  case proplists:get_value(ass,K) of
                      undefined ->
                          ok;
                      _ ->
                          throw(connected)
                  end,

                  T=mkmap:get({Host,Port},PI),
                  case maps:get(auth,T,undefined) of
                      fail ->
                          TD=erlang:system_time(seconds)-maps:get(lastdown,T,0),
                          if TD<60 ->
                                 throw({skip,authfail});
                             true -> ok
                          end;
                      _ -> ok
                  end,

                  lager:debug("I have to connect to ~p: ~p",[Host,T]),
                  case gen_sctp:connect_init
                       (S, Host, Port, [{sctp_initmsg,#sctp_initmsg{num_ostreams=10}}])
                  of ok ->
                         ok;
                     {error,ealready} ->
                         %wait a little bit and association will up
                         throw({skip,ealready})
                  end,
                  %lager:info("Outcoing assoc ~p",[Assoc]),
                  Acc

              catch 
                  throw:connected ->
                      Acc;
                  throw:{skip,Reason}->
                      lager:info("Skip ~p: ~p",[{Host,Port},Reason]),
                      Acc
              end
      end, undefined, mkmap:get_all_keys(PI)),

    erlang:send_after(10000,self(), connect_peers),

    {noreply, State};


handle_info({sctp,Socket,RemoteIP,RemotePort,
             { [AAnc]=Anc, Payload }
            }, #{socket:=Socket}=State) when is_binary(Payload) ->
    showanc(Anc,RemoteIP,RemotePort),
    State1=handle_payload(AAnc,{RemoteIP,RemotePort},Payload,State),
    {noreply, State1};

handle_info({sctp,Socket,RemoteIP,RemotePort,
             { Anc, #sctp_assoc_change{
                       assoc_id=AID,
                       error=Err,
                       outbound_streams=OS,
                       inbound_streams=IS,
                       state=ASt
                      }
             }
            }, #{peerinfo:=PI,socket:=Socket}=State) ->
    showanc(Anc,RemoteIP,RemotePort),
    lager:debug("AssChange for ~p:~w",[RemoteIP,RemotePort]),
    Action=case ASt of
               comm_up -> up;
               cant_assoc -> error;
               comm_lost -> down;
               restart -> down;
               shutdown_comp -> down
           end,
    lager:debug("AssocChange ~w ~s (IS ~w OS ~w Err ~w)",[AID,ASt,IS,OS,Err]),
    PI1=case Action of
            up -> 
                Challenge= <<"Hello",(crypto:strong_rand_bytes(16))/binary,"\r\n">>,
                gen_sctp:send(Socket, AID, 0, Challenge),
                Pre=mkmap:get({RemoteIP,RemotePort}, PI, #{}),
                mkmap:add_key({RemoteIP,RemotePort},{ass,AID},
                              mkmap:put({RemoteIP,RemotePort},
                                        maps:merge(Pre,
                                                   #{state=>up,
                                                     auth=>undefined,
                                                     lastup=>erlang:system_time(seconds),
                                                     prim=>{RemoteIP,RemotePort},
                                                     mych=>Challenge,
                                                     state=>init
                                                    }
                                                  ), PI)
                             );
            down ->
                Pre=mkmap:get({ass, AID}, PI, #{}),
                mkmap:del_key({ass,AID},
                              mkmap:put({RemoteIP,RemotePort},
                                        maps:merge(
                                          Pre,
                                          #{state=>down,
                                            lastdown=>erlang:system_time(seconds)
                                           }
                                         ), PI)
                             );
            error ->
                PI
        end,

    lager:debug("PI ~p",[PI1]),
    {noreply, State#{peerinfo=>PI1}};

handle_info({sctp,Socket,RemoteIP,RemotePort,
             { Anc, #sctp_paddr_change{assoc_id=AID,state=ASt,addr={Addr,AddrP},error=Err} }
            }, #{peerinfo:=PI, socket:=Socket}=State) ->
    showanc(Anc,RemoteIP,RemotePort),

    Action=case ASt of
               addr_unreachable -> del;
               addr_available -> add;
               addr_removed -> del;
               addr_added -> add;
               addr_made_prim -> prim;
               addr_confirmed -> add
           end,

    lager:info("AddrChange ~w ~s ~s (err ~p)",[AID,ASt,inet:ntoa(Addr),Err]),

    PI1=case Action of
            prim ->
                Pre=mkmap:get({ass, AID}, PI),
                mkmap:put({ass,AID},
                          maps:merge(
                            Pre,
                            #{ prim=>{Addr,AddrP} }
                           )
                          ,PI);
            add -> 
                lager:info("Add address ~p to ~p",[Addr,AID]),
                mkmap:add_key({ass,AID},{Addr,AddrP}, PI);
            del ->
                try
                    mkmap:del_key({Addr,AddrP},PI)
                catch error:{badkey,_} ->
                          PI
                end
        end,

    lager:info("PI ~p",[PI1]),

    {noreply, State#{peerinfo=>PI1}};

handle_info({sctp,Socket,RemoteIP,RemotePort, Message }, #{socket:=Socket}=State) ->
    lager:info("SCTP from ~s:~w unknown ~p",[
                                             inet:ntoa(RemoteIP),
                                             RemotePort,
                                             Message
                                            ]),
    {noreply, State};

handle_info(_Info, State) ->
    lager:info("unknown info ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
mapto6({_,_,_,_,_,_,_,_}=IP6) -> 
    IP6;
mapto6({A,B,C,D}) ->
    {0,0,0,0,0,16#FFFF,(A bsl 8) bor B,(C bsl 8) bor D}.

resolve(Host) ->
    lists:foldl(
      fun(AF,A) ->
              case inet:gethostbyname(Host,AF) of
                  {ok, #hostent{h_addr_list=P}} ->
                      A++lists:map(fun mapto6/1,P);
                  {error, _} ->
                      A
              end
      end,
      [], [inet6,inet]).


showanc([#sctp_sndrcvinfo{
            stream=SID,    % 0	Streams numbered from 0 (XXX?)
            flags=Flags,   % [unordered, addr_over, abort, eof]
            ppid=PPID,     % 0,	Passed to the remote end
            context=Ctx,   % 0,	Passed to the user on error
            cumtsn=Cumtsn, % 0,	Only for unordered recv
            assoc_id=Assoc % 0		IMPORTANT!
           }],RemoteIP,RemotePort) ->
    lager:debug("from ~s:~w ass ~w str ~w flg ~p pp ~p ctx ~p cum ~p",
               [ inet:ntoa(RemoteIP), RemotePort,
                Assoc, SID, Flags, PPID, Ctx, Cumtsn ]).

handle_payload(#sctp_sndrcvinfo{ stream=SID, assoc_id=Assoc }=Anc,
               {RemoteIP,RemotePort},Payload,#{peerinfo:=PI,socket:=Socket}=State) ->
    Ctx=mkmap:get({ass,Assoc}, PI, #{}),
    lager:debug("++> Payload from ~p ~p: ~p  (ctx ~p)", [Assoc, SID, Payload, Ctx]),
    case payload(Socket, Anc, {RemoteIP,RemotePort},Payload,Ctx,State) of
        {ok, close} ->
            gen_sctp:eof(Socket, #sctp_assoc_change{
                                    assoc_id = Assoc
                                   }),
            State;
        {ok, NewState} ->
            NewState;
        {ok, NewCtx, NewState} ->
            PI1=mkmap:put({ass,Assoc},NewCtx,PI),
            NewState#{ peerinfo=>PI1 }
%        _Any ->
%            lager:error("Bad return from payload handler ~p",[_Any]),
%            State
    end.

payload(Socket, 
        #sctp_sndrcvinfo{ stream=SID, assoc_id=Assoc },
        _Remote,Payload,#{state := init}=Ctx,State) when SID==0 ->
    lager:info("Make chresp"),
    ExtAuth=case maps:get(authmod,State,undefined) of
                X when is_atom(X) ->
                    case erlang:function_exported(X,authgen,2) of
                        true ->
                            X:authgen(Payload,maps:get(authctx,State,#{}));
                        false ->
                            undefined
                    end;
                _ -> 
                    lager:notice("No authmod specified"),
                    undefined
            end,
    if is_binary(ExtAuth) ->
           gen_sctp:send(Socket, Assoc, SID, ExtAuth),
           {ok, Ctx#{state=>chrespo}, State};
       ExtAuth == undefined ->
           gen_sctp:send(Socket, Assoc, SID, crypto:hash(sha,Payload)),
           {ok, Ctx#{state=>chrespo}, State};
       true ->
           lager:error("spic Auth module returned unexpected result ~p",
                       [ExtAuth]),
           {ok, close}
    end;

payload(Socket, 
        #sctp_sndrcvinfo{ stream=SID, assoc_id=Assoc },
        _Remote,Payload,#{state := chrespo, mych:=Ch}=Ctx,State) when SID==0 ->
    ExtAuth=case maps:get(authmod,State,undefined) of
                X when is_atom(X) ->
                    case erlang:function_exported(X,authcheck,3) of
                        true ->
                            X:authcheck(Ch,Payload,maps:get(authctx,State,#{}));
                        false ->
                            undefined
                    end;
                _ -> 
                    lager:notice("No authmod specified"),
                    undefined
            end,
    Auth=case ExtAuth of
             true -> true;
             false -> false;
             undefined ->
                 crypto:hash(sha,Ch)==Payload;
             _ ->
                 lager:error("tpic Auth module returned unexpected result ~p",
                             [ExtAuth]),
                 false
         end,
    if Auth==true ->
           lager:info("Auth ok"),
           Routing=msgpack:pack(#{
                           null=><<"routing">>,
                           <<"routing">>=>maps:get(extrouting,State)
                          }),
           lager:info("Send routing ~p",[Routing]),
           gen_sctp:send(Socket, Assoc, SID, Routing),
           {ok, Ctx#{auth=>ok,state=>working}, State};
       Auth==false ->
           lager:info("Auth fail"),
           gen_sctp:send(Socket, Assoc, SID, <<1>>),
           gen_sctp:eof(Socket, #sctp_assoc_change{
                                   assoc_id = Assoc
                                  }),
           {ok, Ctx#{auth=>fail,state=>authfail}, State}
    end;

payload(Socket, 
        #sctp_sndrcvinfo{ stream=SID, assoc_id=_Assoc }=Anc,
        Remote,Payload,#{state := working}=Ctx,State) when SID==0 ->
    case msgpack:unpack(Payload) of 
        {ok, Unpacked} ->
            zerostream(Socket,Anc,Remote,Unpacked,Ctx,State);
        _ ->
            lager:info("Can't decode MP in 0 stream, closing assoc"),
            {ok, close}
    end;

payload(_Socket,
        #sctp_sndrcvinfo{ stream=SID, assoc_id=Assoc },
        {_RemoteIP,_RemotePort},Payload,_Ctx,#{rrouting:=RR}=State) ->
    case maps:is_key(SID,RR) of
        true ->
            To=case maps:get(SID,RR) of
                   <<"timesync">> -> synchronizer;
                   X when is_pid(X) -> X;
                   X when is_atom(X) -> X;
                   X when is_binary(X) ->
                       try 
                           erlang:binary_to_existing_atom(X,utf8)
                       catch error:badarg ->
                                 undefined
                       end
               end,
            gen_server:cast(To,{tpic,{Assoc,SID},Payload}),
            lager:info("Payload to ~p from ~p ~p",
                       [To, Assoc, SID]);
        false ->
            lager:info("Payload from ~p ~p: ~p",
                       [Assoc, SID, Payload])
    end,
    {ok, State}.

zerostream(_Socket, 
           #sctp_sndrcvinfo{ stream=SID, assoc_id=_Assoc }=_Anc, 
           _Remote, #{
             null:=<<"routing">>,
             <<"routing">>:=Routes
            }=_Message,Ctx,State) when SID==0 ->
    {ok, Ctx#{routes=>Routes}, State};

zerostream(_Socket, 
           #sctp_sndrcvinfo{ stream=SID, assoc_id=Assoc }=_Anc, 
           _Remote, #{}=_Message,_Ctx,State) when SID==0 ->
    lager:info("Message from ~p ~p", [Assoc, _Message]),
    {ok, State}.


call(TPIC, Conn, Request) -> 
    call(TPIC, Conn, Request, 2000).

call_all(TPIC, Service, Request) -> 
    call_all(TPIC, Service, Request, 2000).

call(TPIC, Conn, Request, Timeout) -> 
    R=gen_server:call(TPIC,{unicast,Conn, Request}),
    T2=erlang:system_time(millisecond)+Timeout,
    wait_response(T2,R,[]).

call_all(TPIC, Service, Request, Timeout) -> 
    R=gen_server:call(TPIC,{broadcast,Service, Request}),
    T2=erlang:system_time(millisecond)+Timeout,
    wait_response(T2,R,[]).

wait_response(_Until,[],Acc) ->
    Acc;

wait_response(Until,[R1|RR],Acc) ->
    lager:debug("Waiting for reply"),
    T1=Until-erlang:system_time(millisecond),
    T=if(T1>0) -> T1;
        true -> 0
      end,
    receive 
        {'$gen_cast',{tpic,R1,A}} ->
            {ok,Response}=msgpack:unpack(A),
            lager:debug("Got reply from ~p ~p",[R1,Response]),
            wait_response(Until,RR,[{R1,Response}|Acc])
    after T ->
              wait_response(Until,RR,Acc)
    end.

    
