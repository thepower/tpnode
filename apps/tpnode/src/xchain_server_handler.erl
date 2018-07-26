% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server_handler).

%% API
-export([handle_xchain/1, known_atoms/0]).

known_atoms() ->
  [iam, subscribed].

handle_xchain(#{null:=<<"node_id">>,
                <<"node_id">>:=RemoteNodeId,
                <<"channels">>:=RemoteChannels}) ->
  try
    lager:info("Got nodeid ~p",[RemoteNodeId]),
    gen_server:cast(xchain_dispatcher,
                    {register_peer, self(), RemoteNodeId, RemoteChannels}),
    #{null=><<"iam">>, <<"node_id">>=>nodekey:node_id()}
  catch _:_ ->
          error
  end;

handle_xchain(#{null:=<<"subscribe">>,
                <<"channel">>:=Channel}) ->
  gen_server:cast(xchain_dispatcher, {subscribe, Channel, self()}),
  {<<"subscribed">>, Channel};

handle_xchain(#{null:=<<"ping">>}) ->
  ok;

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
    {_, H} = gen_server:call(blockchain, last_block_height),
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

