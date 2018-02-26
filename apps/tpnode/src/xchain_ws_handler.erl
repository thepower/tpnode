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
%%    erlang:start_timer(1000, self(), <<"Hello!">>),
    {ok, State}.

websocket_handle({binary, Bin}, State) ->
    try
        lager:notice("ws server got binary msg: ~p", [Bin]),
        Cmd = crosschain:unpack(Bin),
        lager:notice("ws server unpacked term: ~p", [Cmd]),
        Result = handle_xchain(Cmd),
        case Result of
            ok ->
                {ok, State};
            Answer ->
                {reply, {binary, crosschain:pack(Answer)}, State}

        end
    catch
        Err:Reason ->
        lager:error("WS server error ~p ~p ~p",[Err, Reason, Bin]),
        {ok, State}
    end;

websocket_handle({text, <<"ping">>}, State) ->
    {ok, State};

websocket_handle({text, Msg}, State) ->
    lager:notice("ws server got msg: ~p", [Msg]),
    {reply, {text, <<"pong: ", Msg/binary >>}, State};

websocket_handle(_Data, State) ->
    lager:notice("Unknown websocket ~p", [_Data]),
    {ok, State}.

websocket_info({message, Msg}, State) ->
    lager:info("send message ~p",[Msg]),
    {reply, {binary, crosschain:pack(Msg)}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
    lager:notice("crosschain ws timeout ~p", [Msg]),
%%    erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    lager:notice("Unknown info ~p", [_Info]),
    {ok, State}.




%% ----------------------------

childspec() ->
    HTTPDispatch = cowboy_router:compile(
        [
            {'_', [
                {"/", xchain_ws_handler, []}
            ]}
        ]),
    CrossChainOpts = application:get_env(tpnode, crosschain, #{}),
    CrossChainPort = maps:get(port, CrossChainOpts, 43311),


    HTTPOpts=[{connection_type,supervisor}, {port, CrossChainPort}],
    HTTPConnType=#{connection_type => supervisor,
        env => #{dispatch => HTTPDispatch}},
    HTTPAcceptors=10,
    ranch:child_spec(crosschain_api,
        HTTPAcceptors,
        ranch_tcp,
        HTTPOpts,
        cowboy_clear,
        HTTPConnType).


%% ----------------------------

handle_xchain({subscribe, Channel}) ->
    gen_server:cast(xchain_dispatcher, {subscribe, Channel, self()}),
    {subscribed, Channel};

handle_xchain(Cmd) ->
    {unhandled, Cmd}.
