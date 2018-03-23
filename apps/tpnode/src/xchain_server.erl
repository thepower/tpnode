% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server).

%% API
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(Req, Opts) ->
    {cowboy_websocket, Req, Opts, #{
        idle_timeout => 600000
    }}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({binary, Bin}, State) ->
    try
%%        lager:debug("ws server got binary msg: ~p", [Bin]),
        Cmd = xchain:unpack(Bin),
        lager:debug("ws server got term: ~p", [Cmd]),
        Result = xchain_server_handler:handle_xchain(Cmd),
        case Result of
            ok ->
                {ok, State};
            Answer ->
                {reply, {binary, xchain:pack(Answer)}, State}

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
    {reply, {binary, xchain:pack(Msg)}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
    lager:debug("crosschain ws timeout ~p", [Msg]),
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    lager:notice("Unknown info ~p", [_Info]),
    {ok, State}.


%% ----------------------------

