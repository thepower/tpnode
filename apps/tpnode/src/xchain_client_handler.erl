% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_client_handler).

%% API
-export([handle_xchain/3]).


handle_xchain({iam, NodeId}, ConnPid, #{subs:=Subs} = State) ->
    State#{
        subs => set_node_id(ConnPid, NodeId, Subs)
    };

handle_xchain(pong, _ConnPid, State) ->
%%    lager:info("Got pong for ~p", [_ConnPid]),
    State;

handle_xchain({outward_block, FromChain, ToChain, BinBlock}, _ConnPid, State) ->
    lager:info("Got outward block from ~p to ~p", [FromChain, ToChain]),
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
    State;

handle_xchain(Cmd, _ConnPid, State) ->
    lager:info("got xchain message from server: ~p", [Cmd]),
    State.





% ------------

set_node_id(Pid, NodeId, Subs) ->
    Setter =
        fun(_Key, #{connection:=Connection} = Sub) ->
            case Connection of
                Pid ->
                    Sub#{
                        node_id => NodeId
                    };
                _ ->
                    Sub
            end;
            (_Key, Sub) ->
                Sub
        end,
    maps:map(Setter, Subs).
