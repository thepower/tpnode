-module(xchain_api).

%% API
-export([h/3, after_filter/1]).

%%before_filter(Req) ->
%%    lager:info("before filter"),
%%    Req.

after_filter(Req) ->
    Origin = cowboy_req:header(<<"origin">>, Req, <<"*">>),
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
    Req2 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, POST, OPTIONS">>, Req1),
    Req3 = cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req2),
    Req4 = cowboy_req:set_resp_header(<<"access-control-max-age">>, <<"86400">>, Req3),
    cowboy_req:set_resp_header(<<"access-control-allow-headers">>, <<"content-type">>, Req4).


h(<<"POST">>, [<<"ping">>], _Req) ->
    {200, #{
        result => <<"ok">>,
        data => [<<"pong">>]
    }};

h(<<"OPTIONS">>, _, _Req) ->
    {200, [], ""};

h(_Method, [<<"status">>], Req) ->
    {RemoteIP, _Port} = cowboy_req:peer(Req),
    lager:info("api call from ~p", [inet:ntoa(RemoteIP)]),
    Body = apixiom:body_data(Req),

    {200,
        #{
            result => <<"ok">>,
            data => #{
                request => Body
            }
%%            test => maps:from_list([{"192.168.2.1", 1234}, {"192.168.2.4", 1234}])
        }
    }.

