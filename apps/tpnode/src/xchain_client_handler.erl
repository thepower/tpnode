% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_client_handler).

%% API
-export([handle_xchain/3]).

handle_xchain(#{null:=<<"pong">>}, _ConnPid, Sub) ->
  Sub;

handle_xchain(#{null:=<<"iam">>, <<"node_id">>:=NodeId}, _ConnPid, Sub) ->
  Sub#{
    node_id => NodeId
   };

handle_xchain({iam, NodeId}, ConnPid, Sub) ->
    handle_xchain({<<"iam">>, NodeId}, ConnPid, Sub);

handle_xchain({<<"iam">>, NodeId}, _ConnPid, Sub) ->
  Sub#{
    node_id => NodeId
   };

handle_xchain(pong, _ConnPid, Sub) ->
%%    lager:info("Got pong for ~p", [_ConnPid]),
    Sub;

handle_xchain({<<"outward_block">>, FromChain, ToChain, BinBlock}, ConnPid, Sub) when
    is_integer(ToChain), is_integer(FromChain), is_binary(BinBlock) ->
  handle_xchain({outward_block, FromChain, ToChain, BinBlock}, ConnPid, Sub);

handle_xchain({outward_block, FromChain, ToChain, BinBlock}, _ConnPid, Sub) when
    is_integer(ToChain), is_integer(FromChain), is_binary(BinBlock) ->
    lager:info("Got outward block from ~b to ~b", [FromChain, ToChain]),
    Block=block:unpack(BinBlock),
    try
        Filename="tmp/inward_block." ++ integer_to_list(FromChain) ++ ".txt",
        file:write_file(Filename, io_lib:format("~p.~n", [Block]))
    catch Ec:Ee ->
        S=erlang:get_stacktrace(),
        lager:error("Can't dump inward block ~p:~p at ~p",
            [Ec, Ee, hd(S)])
    end,
    lager:debug("Here it is ~p", [Block]),
    gen_server:cast(txpool, {inbound_block, Block}),
    Sub;

handle_xchain({<<"subscribed">>,Cmd}, _ConnPid, Sub) ->
    lager:info("xchain client: subscribed successfully ~s", [Cmd]),
    Sub;

handle_xchain({<<"unhandled">>,Cmd}, _ConnPid, Sub) ->
    lager:info("xchain client: server did not understand my command: ~p", [Cmd]),
    Sub;

handle_xchain(Cmd, _ConnPid, Sub) ->
    lager:info("xchain client got unhandled message from server: ~p", [Cmd]),
    Sub.

