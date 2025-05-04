-module(tpnode_preconf_api).
-include("include/tplog.hrl").

-export([h/3,
         after_filter/1,
         before_filter/1,
         packer/2,
         binjson/1]).

-export([answer/0, answer/1, answer/2, err/1, err/2, err/3, err/4]).


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

err(ErrorCode) ->
    err(ErrorCode, <<"">>, #{}, #{}).

err(ErrorCode, ErrorMessage) ->
    err(ErrorCode, ErrorMessage, #{}, #{}).

err(ErrorCode, ErrorMessage, Data) ->
    err(ErrorCode, ErrorMessage, Data, #{}).

err(ErrorCode, ErrorMessage, Data, Options) ->
    Required1 =
        #{
            <<"ok">> => false,
            <<"code">> => ErrorCode,
            <<"msg">> => ErrorMessage
        },

    {
        maps:get(http_code, Options, 200),
        maps:merge(Data, Required1)
    }.

answer() ->
    answer(#{}).

answer(Data) ->
    answer(Data, #{}).

answer(Data, Options) when is_map(Data) ->
  Data2=maps:put(<<"ok">>, true, Data),
  MS=maps:with([jsx,msgpack],Options),
  case(maps:size(MS)>0) of
    true ->
      { 200, {Data2,MS} };
    false ->
      { 200, Data2 }
  end.

before_filter(Req) ->
  % check authentication header:
  case cowboy_req:header(<<"authorization">>, Req) of
    undefined ->
      {reply, 403, #{}, <<"Unauthorized">>, Req};
    Auth ->
      PwHash=crypto:hash(sha256,Auth),
      case application:get_env(tpnode, conf_secret, none) of
        Hash1 when Hash1==PwHash ->
          Req;
        _ ->
          {reply, 403, #{}, <<"Unauthorized">>, Req}
      end
  end.

after_filter(Req) ->
  Origin=cowboy_req:header(<<"origin">>, Req, <<"*">>),
  Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                  Origin, Req),
  Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                  <<"GET, POST, OPTIONS">>, Req1),
%  Req3=cowboy_req:set_resp_header(<<"access-control-allow-credentials">>,
%                                  <<"true">>, Req2),
  Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                  <<"86400">>, Req2),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                             <<"content-type,authorization">>, Req4).

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};

h(<<"GET">>, [<<"tea_progress">>,T], _Req) ->
  {ok,_T0}=tinymq:subscribe(tea,binary_to_integer(T),self()),
  receive
    {Pid,Timestamp, List} when is_pid(Pid), is_integer(Timestamp), is_list(List) ->
      answer( #{t=>Timestamp, data=>List})
  after 50000 ->
      answer( #{error=> <<"timeout">>, data => null})
  end;

h(<<"POST">>, [<<"set_pw">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  io:format("set pw from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  io:format("Body: ~p~n", [Body]),
  case Body of
    #{<<"password">>:=Password} ->
      Hash=crypto:hash(sha256, Password),
      tpnode:set_override(conf_secret, Hash),
      answer( #{});
    _ ->
      err(<<"invalid_request">>, <<"Invalid request">>)
  end;

h(<<"POST">>, [<<"set_role">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  io:format("Join from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  io:format("Body: ~p~n", [Body]),
  case Body of
    #{<<"role">>:=<<"tea">>,
      <<"nodeName">> := NodeName,
      <<"ceremonyToken">> := Token} ->
      %spawn(fun() ->
      %          timer:sleep(1000),
      %          tpnode:restart()
      %      end),
      application:ensure_all_started(teaclient),
      {Host,Port,ConOpts,_Extra}=tpapi2:parse_url(
        application:get_env(tpnode,tea_server,"https://tea.thepower.io:443/")
       ),
      spawn(fun() ->
                teaclient_worker:run(#{
                                       host=>Host,
                                       port=>Port,
                                       token=>Token,
                                       conn_opts=>ConOpts,
                                       status_update=>fun(Kind, Data, Sub) ->
                                                          tinymq:push(tea,#{k=>Kind,
                                                                           d=>Data}),
                                                          io:format("Kind: ~p~n", [Kind]),
                                                          io:format("Data: ~p~n", [Data]),
                                                          {ok, Sub}
                                                      end,
                                       nodename=>NodeName})
            end),
      answer( #{ client => list_to_binary(inet:ntoa(RemoteIP)) });
    _ ->
      io:format("Body: ~p~n", [Body]),
      err(<<"invalid_request">>, <<"Invalid request">>)
  end;

h(_Method, [<<"status">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  ?LOG_INFO("Join from ~p", [inet:ntoa(RemoteIP)]),
  %Body=apixiom:bodyjs(Req),

  answer( #{ client => list_to_binary(inet:ntoa(RemoteIP)) }).

%PRIVATE API

% ----------------------------------------------------------------------

packer(#{req_format := <<"mp">>}=Req) ->
  packer(Req, raw);
packer(Req) ->
  packer(Req, hex).

packer(Req,Default) ->
  QS=cowboy_req:parse_qs(Req),
  case proplists:get_value(<<"bin">>, QS) of
    <<"b64">>  -> fun(Bin) -> base64:encode(Bin) end;
    <<"phex">> -> fun(Bin) -> hex:encode(Bin) end;
    <<"hex">>  -> fun(<<_:160/big>>=Bin) ->
						  address:encode(Bin);
					 (Bin) -> hex:encodex(Bin) end;
    <<"xhex">> -> fun(<<_:160/big>>=Bin) ->
						  address:encode(Bin);
					 (Bin) -> hex:encodex(Bin) end;
	<<"0xhex">>-> fun(Bin) -> <<"0x",(hex:encode(Bin))/binary>> end;
    <<"raw">>  -> fun(Bin) -> Bin end;
    _ -> case Default of
           phex-> fun(Bin) -> hex:encode(Bin) end;
           hex -> fun(<<_:160/big>>=Bin) ->
						  address:encode(Bin);
					 (Bin) -> hex:encodex(Bin) end;
           xhex-> fun(<<_:160/big>>=Bin) ->
						  address:encode(Bin);
					 (Bin) -> hex:encodex(Bin) end;
           b64 -> fun(Bin) -> base64:encode(Bin) end;
           raw -> fun(Bin) -> Bin end
         end
  end.

% ----------------------------------------------------------------------

binjson(Term) ->
  EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
          Conf1=jsx_config:list_to_config(Conf),
          jsx_parser:resume([{Type, base64:encode(Str)}|Tokens],
                            State, Handler, Stack, Conf1)
      end,
   jsx:encode(
     Term,
     [ strict, {error_handler, EHF} ]
    ).

