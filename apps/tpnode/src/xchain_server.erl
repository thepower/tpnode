% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain_server).

%% API
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

init(#{headers:=H}=Req, _Opts) ->
  logger:info("Init ~p",[H]),
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
  logger:info("Init ws ~p",[State]),
  {ok, State}.

websocket_handle({binary, Bin}, #{proto:=P}=State) ->
  try
    %%logger:debug("ws server got binary msg: ~p", [Bin]),
    Cmd = xchain:unpack(Bin, P),
    logger:debug("ws server got term: ~p", [Cmd]),
    Result = xchain_server_handler:handle_xchain(Cmd),
    case Result of
      ok ->
        {ok, State};
      Answer ->
        {reply, {binary, xchain:pack(Answer, P)}, State}
    end
  catch
    Ec:Ee:S ->
      %S = erlang:get_stacktrace(),
      logger:error("xchain server ws parse error ~p:~p ~p", [Ec, Ee, Bin]),
      lists:foreach(
        fun(Se) ->
            logger:error("at ~p", [Se])
        end, S),
      {ok, State}
  end;

websocket_handle({text, <<"ping">>}, State) ->
  logger:info("PING"),
  {ok, State};

websocket_handle({text, Msg}, State) ->
  logger:debug("xchain server got text msg: ~p", [Msg]),
  {reply, {text, <<"pong: ", Msg/binary >>}, State};

websocket_handle(_Data, State) ->
  logger:info("xchain server got unknown websocket: ~p", [_Data]),
  {ok, State}.

websocket_info({message, Msg}, #{proto:=P}=State) ->
  logger:debug("xchain server send message ~p", [Msg]),
  {reply, {binary, xchain:pack(Msg, P)}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
  logger:debug("xchain server ws timeout ~p", [Msg]),
  {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
  logger:notice("xchain server got unknown ws info ~p", [_Info]),
  {ok, State}.


%% ----------------------------

