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
           {active, true}
           | tpic2:certificate()
          ],
  {Opts1,NAddr}=case inet:parse_address(Host) of
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
               end,
  try
    {ok, TCPSocket} = gen_tcp:connect(NAddr, Port, [binary, {packet,4}]++Opts1),
    ?LOG_DEBUG("Opts ~p~n",[SSLOpts]),
    {ok, Socket} = ssl:connect(TCPSocket, SSLOpts),
    ssl:setopts(Socket, [{active, once}]),
    {ok,PeerInfo}=ssl:connection_information(Socket),
    State=#{
      ref=>maps:get(ref, Opts, undefined),
      socket=>Socket,
      peerinfo=>PeerInfo,
      timer=>undefined,
      transport=>ranch_ssl,
      parent=>Parent,
      role=>client,
      opts=>Opts,
      address=>{Host,Port}
     },
    tpic2_tls:send_msg(hello, State),
    tpic2_tls:loop1(State)
  catch error:{badmatch,{error,econnrefused}} ->
          ?LOG_INFO("Peer ~s:~w conn refused",[inet:ntoa(NAddr),Port])
  end.

