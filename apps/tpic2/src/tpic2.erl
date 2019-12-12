-module(tpic2).
-export([childspec/0,certificate/0,cert/2,extract_cert_info/1, verfun/3,
        node_addresses/0, alloc_id/0]).
-export([peers/0,peerstreams/0,cast/3]).
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

cast(_TPIC, Service, Data) ->
  {Srv, Msg} = case Data of
                 {S1,M1} when is_binary(S1), is_binary(M1) ->
                   {S1, M1};
                 M when is_binary(M) ->
                   {<<>>, M}
               end,
  ReqID=alloc_id(),
  SentTo=maps:fold(
    fun(PubKey,Pid,Acc) ->
        Avail=lists:keysort(2,gen_server:call(Pid, {get_stream, Service})),
        io:format("Av ~p~n",[Avail]),
        case Avail of
          [{_,_,ConnPID}|_] ->
            case gen_server:call(ConnPID,{send, Service, Srv, ReqID, Msg}) of
              ok ->
                [PubKey|Acc];
              _ ->
                Acc
            end;
          [] ->
            Acc
        end
    end,
    [],
    gen_server:call(tpic2_cmgr,peers)),
  if SentTo==[] ->
       SentTo;
     true ->
       tpic2_cmgr:add_trans(ReqID, self()),
       SentTo
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
   {key, {'ECPrivateKey', DERKey}},
   {cert, DerCert},
   {verify_fun, {fun tpic2:verfun/3, []}},
   {fail_if_no_peer_cert, true},
   {alpn_preferred_protocols, [<<"tpctl">>,<<"tpstream">>]},
   {verify, verify_peer},
   {cacerts, [DerCert]}
  ].

childspec() ->
  Cfg=application:get_env(tpnode,tpic,#{}),
  Port=maps:get(port,Cfg,40000),
  SSLOpts=certificate(),
  HTTPOpts= [
             {connection_type, supervisor},
             {port, Port}
             | SSLOpts ],
  tpic2_client:childspec() ++
  [
   {tpic2_cmgr,
    {tpic2_cmgr,start_link, []},
    permanent,20000,worker,[]
   },
   ranch:child_spec(
     tpic_tls6,
     ranch_ssl,
     HTTPOpts,
     tpic2_tls,
     #{}
    ),
   ranch:child_spec(
     tpic_tls,
     ranch_ssl,
     [inet6, {ipv6_v6only, true} | HTTPOpts],
     tpic2_tls,
     #{}
    )
  ].

node_addresses() ->
  {ok,IA}=inet:getifaddrs(),
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
                  ({addr, ADDR}, Acc1) ->
                   [list_to_binary(inet:ntoa(ADDR)) | Acc1];
                  (_,Acc1) -> Acc1
               end,
               Acc,
               Attrs)
        end end, [],
    IA).

cert(Key, Subject) ->
  H=erlang:open_port(
      {spawn_executable, "/usr/local/bin/openssl"},
      [{args, [
               "req", "-x509",
               "-key", "/dev/stdin",
               "-days", "100",
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
                                               subjectPublicKey=PubKey
                                              }
                       % issuerUniqueID = asn1_NOVALUE,
                       % subjectUniqueID = asn1_NOVALUE,
                       % extensions = asn1_NOVALUE
                      }=_CertBody
     %    signatureAlgorithm=SigAlgo,
     %    signature=Signature
    }) ->
  #{ subj=>lists:keyfind(?'id-at-commonName',2,Subj),
     pubkey=>PubKey,
     keyalgo=>PubKeyAlgo }.

verfun(PCert,{bad_cert, _} = Reason, _) ->
  lager:info("Peer Cert ~p~n",[extract_cert_info(PCert)]),
  lager:info("Reason ~p~n",[Reason]),
  {valid, Reason};
verfun(_, Reason, _) ->
  lager:info("Other Reason ~p~n",[Reason]),
  {fail, unknown}.


