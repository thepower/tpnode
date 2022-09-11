-module(tpic2).
-export([childspec/0,certificate/0,cert/2,extract_cert_info/1, verfun/3,
        node_addresses/0, alloc_id/0]).
-export([peers/0,peerstreams/0,cast/2,cast/3,call/2,call/3,cast_prepare/1]).
-include_lib("public_key/include/public_key.hrl").

alloc_id() ->
  Node=nodekey:node_id(),
  N=erlang:phash2(Node,16#ffff),
  Req=case get(tpic_req) of
        undefined -> 0;
        I when is_integer(I) ->
          I
      end,
  PID=erlang:phash2({self(),Req bsr 24},16#ffffff),
  put(tpic_req,Req+1),
  <<N:16/big,PID:24/big,Req:24/big>>.

broadcast(ReqID, Stream, Srv, Data, Opts) ->
  case whereis(tpic2_cmgr) of
    undefined -> tpic_not_started;
    _ ->
  tpic2_cmgr:inc_usage(Stream, Srv),
  maps:fold(
    fun(PubKey,Pid,Acc) ->
        Avail=lists:keysort(2,gen_server:call(Pid, {get_stream, Stream})),
        case Avail of
          [{_,_,ConnPID}|_] when is_pid(ConnPID) ->
            case lists:member(async, Opts) of
              true ->
                case erlang:is_process_alive(ConnPID)  of
                  true ->
                    gen_server:cast(ConnPID,{send, Srv, ReqID, Data}),
                    [PubKey|Acc];
                  false ->
                    Acc
                end;
              false ->
                case gen_server:call(ConnPID,{send, Srv, ReqID, Data}) of
                  ok ->
                    [PubKey|Acc];
                  _ ->
                    Acc
                end
            end;
          _ ->
            Acc
        end
    end,
    [],
    tpic2_cmgr:peers())
  end.

unicast(ReqID, Peer, Stream, Srv, Data, Opts) ->
  case whereis(tpic2_cmgr) of
    undefined -> tpic_not_started;
    _ ->
      tpic2_cmgr:inc_usage(Stream, Srv),
      Avail=lists:keysort(2,tpic2_cmgr:send(Peer,{get_stream, Stream})),
      case Avail of
        [{_,_,ConnPID}|_] when is_pid(ConnPID) ->
          case lists:member(async, Opts) of
            true ->
              case erlang:is_process_alive(ConnPID)  of
                true ->
                  gen_server:cast(ConnPID,{send, Srv, ReqID, Data}),
                  tpic2_cmgr:add_trans(ReqID, self()),
                  [Peer];
                false ->
                  []
              end;
            false ->
              case gen_server:call(ConnPID,{send, Srv, ReqID, Data}) of
                ok ->
                  tpic2_cmgr:add_trans(ReqID, self()),
                  [Peer];
                _ ->
                  []
              end
          end;
        _ ->
          []
      end
  end.

cast_prepare(Stream) ->
  ReqID=alloc_id(),
  maps:fold(
    fun(PubKey,Pid,Acc) ->
        Avail=lists:keysort(2,gen_server:call(Pid, {get_stream, Stream})),
        case Avail of
          [{_,_,ConnPID}|_] when is_pid(ConnPID) ->
            case erlang:is_process_alive(ConnPID) of
              true ->
                [{PubKey,Stream,ReqID}|Acc];
              false ->
                Acc
            end;
          _ ->
            Acc
        end
    end,
    [],
    tpic2_cmgr:peers()).

cast(Dat, Data) ->
  cast(Dat, Data, []).

cast({Peer,Stream,ReqID}, Data, Opts) when is_atom(Stream) ->
  cast({Peer,atom_to_binary(Stream,latin1),ReqID}, Data, Opts);

cast({Peer,Stream,ReqID}, Data, Opts) ->
  {Srv, Msg} = case Data of
                 {S1,M1} when is_binary(S1), is_binary(M1) ->
                   {S1, M1};
                 M when is_binary(M) ->
                   {<<>>, M}
               end,
  unicast(ReqID, Peer, Stream, Srv, Msg, Opts);

cast(Service, Data, Opts) when is_binary(Service); Service==0 ->
  {Srv, Msg} = case Data of
                 {S1,M1} when is_binary(S1), is_binary(M1) ->
                   {S1, M1};
                 M when is_binary(M) ->
                   {<<>>, M}
               end,
  ReqID=alloc_id(),
  SentTo=broadcast(ReqID, Service, Srv, Msg, Opts),
  if SentTo==[] ->
       SentTo;
     true ->
       case whereis(tpic2_cmgr) of
         undefined -> tpic_not_started;
         _ ->
           tpic2_cmgr:add_trans(ReqID, self())
       end,
       SentTo
  end.

call(Conn, Request) -> 
    call(Conn, Request, 2000).

call(Service, Request, Timeout) when is_binary(Service); Service==0 -> 
    R=cast(Service, Request),
    T2=erlang:system_time(millisecond)+Timeout,
    lists:reverse(wait_response(T2,R,[]));

call(Conn, Request, Timeout) when is_tuple(Conn) -> 
    R=cast(Conn, Request),
    T2=erlang:system_time(millisecond)+Timeout,
    lists:reverse(wait_response(T2,R,[])).

wait_response(_Until,[],Acc) ->
    Acc;

wait_response(Until,[NodeID|RR],Acc) ->
    logger:debug("Waiting for reply",[]),
    T1=Until-erlang:system_time(millisecond),
    T=if(T1>0) -> T1;
        true -> 0
      end,
    receive 
        {'$gen_cast',{tpic,{NodeID,_,_}=R1,A}} ->
            logger:debug("Got reply from ~p",[R1]),
            wait_response(Until,RR,[{R1,A}|Acc])
    after T ->
              wait_response(Until,RR,Acc)
    end.


peers() ->
  Raw=gen_server:call(tpic2_cmgr,peers),
  maps:fold(
    fun(_,V,Acc) ->
        [gen_server:call(V,info)|Acc]
    end, [], Raw).

peerstreams() ->
  Raw=gen_server:call(tpic2_cmgr,peers),
  maps:fold(
    fun(_,V,Acc) ->
        [begin
           PI=gen_server:call(V,info),
           maps:put(
             streams,
             [ 
              {SID, Dir, Pid, gen_server:call(Pid, peer)} || 
              {SID, Dir, Pid} <- maps:get(streams,PI), is_pid(Pid), is_process_alive(Pid) ],
              maps:with([authdata],PI)
            )
         end|Acc]
    end, [], Raw).

certificate() ->
  Priv=nodekey:get_priv(),
  DERKey=tpecdsa:export(Priv,der),
  Cert=cert(Priv,
            nodekey:node_name(iolist_to_binary(net_adm:localhost()))
           ),
  [{'Certificate',DerCert,not_encrypted}]=public_key:pem_decode(Cert),
  [
   {verify, verify_peer},
   {cert, DerCert},
   {cacerts, [DerCert]},
   {verify_fun, {fun tpic2:verfun/3, []}},
   {fail_if_no_peer_cert, true},
  % {key, {'ECPrivateKey', DERKey}}
   {key, {'PrivateKeyInfo', DERKey}}
  ].

childspec() ->
  Cfg=application:get_env(tpnode,tpic,#{}),
  Port=maps:get(port,Cfg,40000),
  HTTPOpts = fun(E) -> #{
                         connection_type => supervisor,
                         socket_opts => [{port,Port},
                                         {alpn_preferred_protocols, [<<"tpctl">>,<<"tpstream">>]}
                                        ] ++ E ++ certificate()
                        }
             end,
  tpic2_client:childspec() ++
  [
   {tpic2_cmgr,
    {tpic2_cmgr,start_link, []},
    permanent,20000,worker,[]
   },
   ranch:child_spec(
     tpic_tls,
     ranch_ssl,
     HTTPOpts([]),
     tpic2_tls,
     #{}
    ),
   ranch:child_spec(
     tpic_tls6,
     ranch_ssl,
     HTTPOpts([inet6, {ipv6_v6only, true}]),
     tpic2_tls,
     #{}
    )
  ].

node_addresses() ->
  {ok,IA}=inet:getifaddrs(),
  AllowLocal=maps:get(allow_localip,application:get_env(tpnode,tpic,#{}),false)==true,
  TPICAddr=[ list_to_binary(A) || #{address:=A,proto:=tpic} <-
                                  maps:get(addresses,application:get_env(tpnode,discovery,#{}),[])
           ],
  lists:foldl(
    fun({_IFName,Attrs},Acc) ->
        Flags=proplists:get_value(flags,Attrs,[]),
        case not lists:member(loopback,Flags)
             andalso lists:member(running,Flags)
        of false ->
             Acc; true
           ->
             lists:foldl(
               fun({addr, {65152,_,_,_,_,_,_,_}}, Acc1) ->
                   Acc1;
                  ({addr, {192,168,_,_}}, Acc1) when (not AllowLocal) ->
                   Acc1;
                  ({addr, {172,SixTeenToThirdtyOne,_,_}}, Acc1) when (not AllowLocal) andalso
                                                              SixTeenToThirdtyOne >= 16 andalso
                                                              SixTeenToThirdtyOne < 31 ->
                   Acc1;
                  ({addr, {10,_,_,_}}, Acc1) when not AllowLocal ->
                   Acc1;
                  ({addr, ADDR}, Acc1) ->
                   [list_to_binary(inet:ntoa(ADDR)) | Acc1];
                  (_,Acc1) -> Acc1
               end,
               Acc,
               Attrs)
        end end, TPICAddr,
    IA).

cert(Key, Subject) ->
  Env=application:get_env(tpnode,tpic,#{}),
  OpenSSL=maps:get(openssl,Env,os:find_executable("openssl")),
  H=erlang:open_port(
      {spawn_executable, OpenSSL},
      [{args, [
               "req", "-new", "-x509",
               "-key", "/dev/stdin",
               "-days", "366",
               "-nodes", "-subj", "/CN="++binary_to_list(Subject)
              ]},
       eof,
       binary,
       stderr_to_stdout
      ]),
  PrivKey=tpecdsa:export(Key,pem),
  H ! {self(), {command, <<PrivKey/binary,"\n">>}},
  cert_loop(H).

cert_loop(Handle) ->
  receive
    {Handle, {data, Msg}} ->
      <<Msg/binary,(cert_loop(Handle))/binary>>;
    {Handle, eof} ->
      <<>>
  after 10000 ->
          throw("Cant get certificate from openssl")
  end.

extract_cert_info(
  #'OTPCertificate'{
     tbsCertificate=#'OTPTBSCertificate'{
                       % version = asn1_DEFAULT,
                       % serialNumber,
                       % signature,
                       % issuer,
                       % validity,
                       subject={rdnSequence,[Subj|_]},
                       subjectPublicKeyInfo=#'OTPSubjectPublicKeyInfo'{
                                               algorithm=PubKeyAlgo,
                                               subjectPublicKey={'ECPoint',RawPK}=_PubKey
                                              }
                       % issuerUniqueID = asn1_NOVALUE,
                       % subjectUniqueID = asn1_NOVALUE,
                       % extensions = asn1_NOVALUE
                      }=_CertBody
     %    signatureAlgorithm=SigAlgo,
     %    signature=Signature
    }) ->
  #'PublicKeyAlgorithm'{algorithm = Algo} = PubKeyAlgo,
  #{ subj=>lists:keyfind(?'id-at-commonName',2,Subj),
     pubkey=>tpecdsa:wrap_pubkey(RawPK, Algo),
     keyalgo=>PubKeyAlgo
   }.

verfun(PCert,{bad_cert, _} = Reason, _) ->
  logger:debug("Peer Cert ~p~n",[extract_cert_info(PCert)]),
  logger:info("Peer cert ~p~n",[Reason]),
  {valid, Reason};
verfun(_, Reason, _) ->
  logger:notice("Bad cert. Reason ~p~n",[Reason]),
  {fail, unknown}.


