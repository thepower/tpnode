% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_ws_handler).

%% API
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-export([childspec/0]).


init(Req, Opts) ->
    {cowboy_websocket, Req, Opts, #{
        idle_timeout => 600000
    }}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({binary, Bin}, State) ->
    try
%%        lager:debug("ws server got binary msg: ~p", [Bin]),
        Cmd = crosschain:unpack(Bin),
        lager:debug("ws server got term: ~p", [Cmd]),
        Result = handle_xchain(Cmd),
        case Result of
            ok ->
                {ok, State};
            Answer ->
                {reply, {binary, crosschain:pack(Answer)}, State}

        end
    catch
        Ec:Ee ->
            S = erlang:get_stacktrace(),
            lager:error("WS server error parse error ~p:~p ~p", [Ec, Ee, Bin]),
            lists:foreach(
                fun(Se) ->
                    lager:error("at ~p", [Se])
                end, S),
            {ok, State}
    end;

websocket_handle({text, <<"ping">>}, State) ->
    {ok, State};

websocket_handle({text, Msg}, State) ->
    lager:debug("ws server got msg: ~p", [Msg]),
    {reply, {text, <<"pong: ", Msg/binary >>}, State};

websocket_handle(_Data, State) ->
    lager:info("Unknown websocket ~p", [_Data]),
    {ok, State}.

websocket_info({message, Msg}, State) ->
    lager:debug("send message ~p",[Msg]),
    {reply, {binary, crosschain:pack(Msg)}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
    lager:debug("crosschain ws timeout ~p", [Msg]),
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    lager:notice("Unknown info ~p", [_Info]),
    {ok, State}.


%% ----------------------------

childspec() ->
    HTTPDispatch = cowboy_router:compile(
        [
            {'_', [
                {"/xchain/ws", xchain_ws_handler, []},
                {"/", xchain_ws_handler, []},
                {"/xchain/api/[...]", apixiom, {xchain_api,#{}}}
            ]}
        ]),
    CrossChainOpts = application:get_env(tpnode, crosschain, #{}),
    CrossChainPort = maps:get(port, CrossChainOpts, 43311),


    HTTPOpts=[{connection_type,supervisor}, {port, CrossChainPort}],
    HTTPConnType=#{connection_type => supervisor,
        env => #{dispatch => HTTPDispatch}},
    HTTPAcceptors=10,
    [
        ranch:child_spec(crosschain_api,
            HTTPAcceptors,
            ranch_tcp,
            HTTPOpts,
            cowboy_clear,
            HTTPConnType),

        ranch:child_spec(crosschain_api6,
            HTTPAcceptors,
            ranch_tcp,
            [inet6,{ipv6_v6only,true}|HTTPOpts],
            cowboy_clear,
            HTTPConnType)
    ].


%% ----------------------------

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
