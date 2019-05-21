% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server_handler).

%% API
-export([handle_xchain/1, known_atoms/0]).

known_atoms() ->
  [iam, subscribed].

handle_xchain(#{null:=<<"last_ptr">>,
                <<"chain">>:=Chain}) ->
  ChainPath=[<<"current">>, <<"outward">>, xchain:pack_chid(Chain)],
  Last=chainsettings:by_path(ChainPath),
  H=settings:get([<<".">>,<<"height">>,<<"ublk">>],Last),
  #{ null=><<"last_ptr">>,
     chain=>blockchain:chain(),
     pointers=>maps:put(<<"hash">>, H, maps:remove(<<".">>,Last)),
     ok=>true };

handle_xchain(#{null:=<<"pre_ptr">>,
                <<"chain">>:=Chain,
                <<"block">>:=Parent}) ->
  try
    Res=blockchain:rel(Parent,self),
    if is_map(Res) -> ok;
       is_atom(Res) ->
         throw({noblock, Res})
    end,
    O=maps:get(settings, Res),
    P=block:outward_ptrs(O,Chain),
    #{ ok => true,
       chain=>blockchain:chain(),
       null=><<"pre_ptr">>,
       pointers => P
     }
  catch 
    error:{badkey,outbound} ->
      #{ ok=>false,
         null=><<"pre_ptr">>,
         error => <<"no outbound">>
       };
    throw:noout ->
      #{ ok=>false,
         null=><<"pre_ptr">>,
         error => <<"no outbound for this chain">>
       };
    throw:{noblock, _R} ->
      #{ ok=>false,
         null=><<"pre_ptr">>,
         error => <<"no block">>
       };
    Ec:_ ->
      #{ ok=>false,
         null=><<"pre_ptr">>,
         error => Ec
       }
  end;

handle_xchain(#{null:=<<"owblock">>,
                <<"chain">>:=Chain,
                <<"parent">>:=Parent}) ->
  Res=blockchain:rel(Parent,self),
  OutwardBlock=block:outward_chain(Res,Chain),
  case OutwardBlock of
    none ->
      #{ ok=>false,
         null=><<"owblock">>,
         block => false};
    _AnyBlock ->
      #{ ok => true,
         chain=>blockchain:chain(),
         null=><<"owblock">>,
         block => block:pack(OutwardBlock),
         header => maps:map(
                     fun(extdata,PL) -> maps:from_list(PL);
                        (_,Val) -> Val
                     end,
                     maps:with([hash, header, extdata],OutwardBlock)
                    )
       }
  end;

handle_xchain(#{null:=<<"node_id">>,
                <<"node_id">>:=RemoteNodeId,
                <<"chain">>:=RemoteChain}) ->
  try
    lager:info("Got nodeid ~p",[RemoteNodeId]),
    gen_server:cast(xchain_dispatcher,
                    {register_peer, self(), RemoteNodeId, RemoteChain}),
    #{null=><<"iam">>, 
      <<"node_id">>=>nodekey:node_id(),
      <<"chain">>=>blockchain:chain()
     }
  catch _:_ ->
          error
  end;

handle_xchain(#{null:=<<"node_id">>,
                <<"node_id">>:=RemoteNodeId,
                <<"channels">>:=RemoteChannels}) ->
  try
    lager:info("Got nodeid ~p",[RemoteNodeId]),
    gen_server:cast(xchain_dispatcher,
                    {register_peer, self(), RemoteNodeId, RemoteChannels}),
    #{null=><<"iam">>, 
      <<"node_id">>=>nodekey:node_id(),
      <<"chain">>=>blockchain:chain()
     }
  catch _:_ ->
          error
  end;

handle_xchain(#{null:=<<"subscribe">>,
                <<"channel">>:=Channel}) ->
  gen_server:cast(xchain_dispatcher, {subscribe, Channel, self()}),
  {<<"subscribed">>, Channel};

handle_xchain(#{null:=<<"ping">>}) ->
  #{null=><<"pong">>};

handle_xchain(#{null:=<<"xdiscovery">>, <<"bin">>:=AnnounceBin}) ->
  gen_server:cast(discovery, {got_xchain_announce, AnnounceBin}),
  ok;

handle_xchain(ping) ->
  %%    lager:notice("got ping"),
  ok;

handle_xchain({node_id, RemoteNodeId, RemoteChannels}) ->
  try
    lager:info("Got old nodeid ~p",[RemoteNodeId]),
    gen_server:cast(xchain_dispatcher, {register_peer, self(), RemoteNodeId, RemoteChannels}),
    {<<"iam">>, nodekey:node_id()}
  catch _:_ ->
          error
  end;

handle_xchain(chain) ->
  try
    {ok, blockchain:chain()}
  catch _:_ ->
          error
  end;

handle_xchain(height) ->
  try
    #{header:=#{height:=H}}=blockchain:last_meta(),
    {ok, H}
  catch _:_ ->
          error
  end;

handle_xchain({subscribe, Channel}) ->
  gen_server:cast(xchain_dispatcher, {subscribe, Channel, self()}),
  {<<"subscribed">>, Channel};

handle_xchain({xdiscovery, AnnounceBin}) ->
  gen_server:cast(discovery, {got_xchain_announce, AnnounceBin}),
  ok;

handle_xchain(Cmd) ->
  lager:info("xchain server got unhandled message from client: ~p", [Cmd]),
  {unhandled, Cmd}.

