-module(cowboy_jsonrpc).
-export([init/2]).

%% API
init(Req0, {Target, Opts}) ->
    Method = cowboy_req:method(Req0),
    case Method of
      <<"POST">> ->
    {ok, ReqBody, Req1} = cowboy_req:read_body(Req0),
    case jsonrpc2:handle(ReqBody, fun Target:handle/2, fun jiffy:decode/1, fun jiffy:encode/1) of
      {reply, RespBin} ->
        {ok, cowboy_req:reply(200, #{}, RespBin, do_cors(Req1)), Opts}
    end;
      <<"OPTIONS">> ->
        
        {ok, cowboy_req:reply(200, #{}, <<>>, do_cors(Req0)), Opts};
      <<"GET">> ->
        {ok, cowboy_req:reply(400, #{}, <<"Bad request">>, Req0), Opts};
      _ ->
        {ok, cowboy_req:reply(400, #{}, <<"Bad request">>, Req0), Opts}
    end.

do_cors(Req0) ->
  Origin=cowboy_req:header(<<"origin">>, Req0, <<"*">>),
  Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                  Origin, Req0),
  Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                  <<"GET, POST, OPTIONS">>, Req1),
  Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                  <<"86400">>, Req2),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                                  <<"content-type">>, Req4).
