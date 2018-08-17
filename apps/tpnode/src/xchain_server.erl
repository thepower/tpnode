% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server).

%% API
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(#{headers:=H}=Req, _Opts) ->
  lager:info("Init ~p",[H]),
  code:ensure_loaded(xchain_server_handler),
  xchain_server_handler:known_atoms(),
  ConnState=case maps:get(<<"sec-websocket-protocol">>,H,undefined) of
              <<"thepower-xchain-v2">> -> #{proto=>2};
              _ -> #{proto=>0}
            end,
  {cowboy_websocket,
   Req,
   ConnState, #{
     idle_timeout => 600000
    }}.

websocket_init(State) ->
  lager:info("Init ws ~p",[State]),
  {ok, State}.

websocket_handle({binary, Bin}, #{proto:=P}=State) ->
  try
    %%lager:debug("ws server got binary msg: ~p", [Bin]),
    Cmd = xchain:unpack(Bin, P),
    lager:debug("ws server got term: ~p", [Cmd]),
    Result = xchain_server_handler:handle_xchain(Cmd),
    case Result of
      ok ->
        {ok, State};
      Answer ->
        {reply, {binary, xchain:pack(Answer, P)}, State}
    end
  catch
    Ec:Ee ->
      S = erlang:get_stacktrace(),
      lager:error("xchain server ws parse error ~p:~p ~p", [Ec, Ee, Bin]),
      lists:foreach(
        fun(Se) ->
            lager:error("at ~p", [Se])
        end, S),
      {ok, State}
  end;

websocket_handle({text, <<"ping">>}, State) ->
  lager:info("PING"),
  {ok, State};

websocket_handle({text, Msg}, State) ->
  lager:debug("xchain server got text msg: ~p", [Msg]),
  {reply, {text, <<"pong: ", Msg/binary >>}, State};

websocket_handle(_Data, State) ->
  lager:info("xchain server got unknown websocket: ~p", [_Data]),
  {ok, State}.

websocket_info({message, Msg}, #{proto:=P}=State) ->
  lager:debug("xchain server send message ~p", [Msg]),
  {reply, {binary, xchain:pack(Msg, P)}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
  lager:debug("xchain server ws timeout ~p", [Msg]),
  {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
  lager:notice("xchain server got unknown ws info ~p", [_Info]),
  {ok, State}.


%% ----------------------------

