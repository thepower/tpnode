-module(tpic2_client).
-include("include/tplog.hrl").

-export([start/3,start_link/3,childspec/0,init/1]).
-export([connection_process/4]).

start_link(Host, Port, Opts) when is_map(Opts) ->
  Pid = proc_lib:spawn_link(?MODULE,
                            connection_process,
                            [maps:get(parent, Opts, self()),
                             Host, Port, Opts]
                           ),
  {ok, Pid}.

start(Host, Port, Opts) when is_map(Opts) ->
  {ok,Pid}=supervisor:start_child(tpic2_out_sup,
                                  #{id=>{Host,Port,make_ref()},
                                    restart=>temporary,
                                    start=>{
                                      ?MODULE,
                                      start_link,
                                      [Host, Port, Opts]
                                     }
                                   }
                                 ),
  {ok, Pid}.

init([]) ->
  {ok,
   {_SupFlags = {one_for_one, 1, 1000},
    [ ]
   }
  }.

childspec() ->
  [
   { tpic2_out_sup, { supervisor, start_link,
                      [ {local, tpic2_out_sup}, ?MODULE, [] ]
                    },
     permanent, 20000, supervisor, []
   }
  ].

connection_process(Parent, Host, Port, Opts) ->
  SSLOpts=[
           {alpn_advertised_protocols, [<<"tpic2">>]},
           {client_preferred_next_protocols, {client, [<<"tpic2">>]}},
           {active, true},
           {sni, "tpnode"}
           | tpic2:certificate()
          ],

  Mode=case string:tokens(Host,".") of
    [_,"pk","ygg"] ->
           case application:get_env(tpnode,ygg_proxy) of
             {ok, Path} ->
               {socks5, Path};
             undefined ->
               normal
           end;
    _ ->
      normal
  end,

  {ConnHost,ConnPort,ConnOpts,ProxyTo}
  = case {Mode,application:get_env(tpic2,proxy_connect,undefined)} of
      {{socks5,ProxyPath},_} ->
        {Opts1,NAddr}=parse_address(ProxyPath),
        ?LOG_INFO("Connect to ~s:~w via proxy ~p:~w~n",
                  [Host,Port,ProxyPath,0]),
        {NAddr,0,Opts1,{Host, Port}};
      {normal,undefined} ->
        {Opts1,NAddr}=parse_address(Host),
        ?LOG_INFO("Connect to ~s:~w~n",[Host,Port]),
        {NAddr, Port, Opts1, undefined};
      {normal,{PHost,PPort}} ->
        {Opts1,NAddr}=parse_address(PHost),
        ?LOG_INFO("Connect to ~s:~w via proxy ~p:~w~n",
                   [Host,Port, PHost,PPort]),
        {NAddr,PPort,Opts1,{Host, Port}}
    end,
    case gen_tcp:connect(ConnHost, ConnPort, ConnOpts) of
      {ok, TCPSocket} ->
        case ProxyTo of
          undefined -> ok;
          {ToHost, ToPort} ->
            ok=proxy_connect:proxy_connect(TCPSocket, ToHost, ToPort)
        end,
        inet:setopts(TCPSocket, [binary, {packet,4}]),
        ?LOG_DEBUG("Opts ~p~n",[SSLOpts]),
        {ok, Socket} = ssl:connect(TCPSocket, SSLOpts),
        ssl:setopts(Socket, [{active, once}]),
        {ok,PeerInfo}=ssl:connection_information(Socket),
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

        State=#{
                ref=>maps:get(ref, Opts, undefined),
                socket=>Socket,
                peerinfo=>PeerInfo,
                pubkey=>PeerPK,
                timer=>undefined,
                transport=>ranch_ssl,
                parent=>Parent,
                role=>client,
                opts=>Opts,
                address=>{Host,Port}
               },
        tpic2_tls:send_msg(hello, State),
        tpic2_tls:loop1(State);
      {error, Reason} ->
        ?LOG_INFO("Peer ~w:~w conn error: ~p",[ConnHost, ConnPort, Reason]),
        {error,Reason}
  end.

parse_address("/"++_=Path) ->
  {[local],{local,Path}};
parse_address(Host) ->
  case inet:parse_address(Host) of
    {ok, {_,_,_,_}=Addr} ->
      {[],Addr};
    {ok, {_,_,_,_,_,_,_,_}=Addr} ->
      {[inet6],Addr};
    {error, einval} ->
      case inet:gethostbyname(Host) of
        {ok,{hostent,_,_,inet,_, [IPv4Addr|_]}} ->
          {[],IPv4Addr};
        {ok, Any} ->
          %?LOG_ERROR("Address ~p resolver unexpected result : ~p",[Host, Any]),
          throw({unexpected_gethostbyname_answer,Any});
        {error,nxdomain} ->
          %?LOG_ERROR("Address ~p can't resolve",[Host]),
          throw({bad_hostname,Host})
      end;
    {error, Err} ->
      %?LOG_ERROR("Address ~p error: ~p",[Host, Err]),
      throw({parse_addr,Err})
  end.

