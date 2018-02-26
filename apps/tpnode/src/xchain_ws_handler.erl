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


websocket_handle({text, <<"ping">>}, State) ->
    {ok, State};

websocket_handle({text, Msg}, State) ->
    lager:notice("ws server got msg: ~p", [Msg]),
    {reply, {text, <<"pong: ", Msg/binary >>}, State};

websocket_handle(_Data, State) ->
    lager:notice("Unknown websocket ~p", [_Data]),
    {ok, State}.

websocket_info({timeout, _Ref, Msg}, State) ->
    lager:notice("crosschain ws timeout ~p", [Msg]),
%%    erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    lager:notice("Unknown info ~p", [_Info]),
    {ok, State}.



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
