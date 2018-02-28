-module(xchain_api).

%% API
-export([h/3,after_filter/1]).

after_filter(Req) ->
    Origin=cowboy_req:header(<<"origin">>,Req,<<"*">>),
    Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
    Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, POST, OPTIONS">>, Req1),
    Req3=cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req2),
    Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>, <<"86400">>, Req3),
    cowboy_req:set_resp_header(<<"access-control-allow-headers">>, <<"content-type">>, Req4).


h(<<"POST">>, [<<"ping">>], _Req) ->
    {200, #{
        result => <<"ok">>,
        data => [<<"pong">>]
    }};

h(<<"OPTIONS">>, _, _Req) ->
    {200, [], ""};

h(_Method, [<<"status">>], Req) ->
    {RemoteIP,_Port}=cowboy_req:peer(Req),
    lager:info("api call from ~p",[inet:ntoa(RemoteIP)]),
    Body=apixiom:bodyjs(Req),

    lager:info("body ~p", [Body]),

    {200,
        #{
            result => <<"ok">>,
            data => #{
                request => Body
            }
        }
    }.

