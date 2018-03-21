% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server_handler).

%% API
-export([handle_xchain/1]).


handle_xchain(ping) ->
%%    lager:notice("got ping"),
    ok;


handle_xchain({node_id, RemoteNodeId, RemoteChannels}) ->
    try
        gen_server:cast(xchain_dispatcher, {register_peer, self(), RemoteNodeId, RemoteChannels}),
        {iam, nodekey:node_id()}
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
    {subscribed, Channel};

handle_xchain(Cmd) ->
    {unhandled, Cmd}.
