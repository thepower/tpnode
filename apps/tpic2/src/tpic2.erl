-module(tpic2).
-export([childspec/0,certificate/0,cert/2,extract_cert_info/1, verfun/3]).
-include("/usr/local/lib/erlang20/lib/public_key-1.5.2/include/public_key.hrl").

certificate() ->
  Priv=nodekey:get_priv(),
  DERKey=tpecdsa:export(Priv,der),
  Cert=cert(Priv,<<"nodekey:node_name()">>),
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
   ranch:child_spec(
     tpic_tls,
     ranch_ssl,
     HTTPOpts,
     tpic2_tls,
     #{}
    )
  ].

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

