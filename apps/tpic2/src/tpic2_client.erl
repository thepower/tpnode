-module(tpic2_client).

-export([start_link/3]).
-export([connection_process/4]).

start_link(Host, Port, Opts) when is_map(Opts) ->
  Pid = proc_lib:spawn_link(?MODULE,
                            connection_process,
                            [self(), Host, Port, Opts]
                           ),
  {ok, Pid}.

connection_process(Parent, Host, Port, Opts) ->
  Key=nodekey:get_priv(),
  DerKey=tpecdsa:export(Key,der),
  Cert=tpic2:cert(Key,nodekey:node_name()),
  [{'Certificate',DerCert,not_encrypted}]=public_key:pem_decode(Cert),
  SSLOpts=[
           {verify, verify_peer},
           %{fail_if_no_peer_cert, true},
           {verify_fun, {fun tpic2:verfun/3, []}},
           {active, true},
           {key, {'ECPrivateKey', DerKey}},
           {cert, DerCert}
          ],
  {ok, TCPSocket} = gen_tcp:connect(Host, Port, [binary, {packet,4}]),
  {ok, Socket} = ssl:connect(TCPSocket, SSLOpts),
  ssl:setopts(Socket, [{active, once}]),
  {ok,PeerInfo}=ssl:connection_information(Socket),
  lager:info("Peer ~p",[proplists:get_keys(PeerInfo)]),
  {ok,PeerInfo}=ssl:connection_information(Socket),
  State=#{
    ref=>maps:get(ref, Opts, undefined),
    socket=>Socket,
    peerinfo=>PeerInfo,
    timer=>undefined,
    transport=>ranch_ssl,
    parent=>Parent,
    role=>client,
    opts=>Opts
   },
  tpic2_tls:send_msg({hello, client}, State),
  tpic2_tls:loop(State).

