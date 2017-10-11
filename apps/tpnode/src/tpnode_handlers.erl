-module(tpnode_handlers).
%-compile(export_all).

-export([handle/3,before_filter/1,after_filter/1,after_filter/2,h/3]).

before_filter(Req) ->
	apixiom:before_filter(Req).

after_filter(_,_) -> ok.

after_filter(Req) ->
%	{Origin,Req0}=cowboy_req:header(<<"origin">>,Req,<<"*">>),
	%{AllHdrs,_}=cowboy_req:headers(Req),
	%lager:info("Hdr ~p",[AllHdrs]),
%	Req1=cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, Origin, Req0),
%	Req2=cowboy_req:set_resp_header(<<"Access-Control-Allow-Methods">>, <<"GET, POST, OPTIONS">>, Req1),
%	Req3=cowboy_req:set_resp_header(<<"Access-Control-Allow-Credentials">>, <<"true">>, Req2),
%	Req4=cowboy_req:set_resp_header(<<"Access-Control-Max-Age">>, <<"86400">>, Req3),
%	cowboy_req:set_resp_header(<<"Content-Type">>, <<"application/json">>, Req4).
    Req.

handle(Method, [<<"api">>|Path], Req) ->
	apixiom:handle(Method, Path, Req, ?MODULE);
	
handle(<<"GET">>, [], _Req) ->
    [<<"<h1>There is no web here, only API!</h1>">>].

h(Method, [<<"longpoll">>|_]=Path, Req) ->
	tower_lphandler:h(Method, Path, Req); 

h(Method, [<<"event">>|_]=Path, Req) ->
	tower_lphandler:h(Method, Path, Req); 

h(<<"GET">>, [<<"address">>,Addr], _Req) ->
    Info=gen_server:call(blockchain,{get_addr, <<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>}),
    {200,
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        address=>Addr,
        info=>Info
      }
    };

h(<<"POST">>, [<<"tx">>,<<"new">>], Req) ->
    {{RemoteIP,_Port},_}=cowboy_req:peer(Req),
    Body=apixiom:bodyjs(Req),
    lager:info("New tx from ~s: ~p",[inet:ntoa(RemoteIP), Body]),
    BinTx=case maps:get(<<"tx">>,Body,undefined) of
              <<"0x",BArr/binary>> ->
                  hex:parse(BArr);
              Any -> Any
          end,
    case txpool:new_tx(BinTx) of
        {ok, Tx} -> 
            {200,
             [{<<"Content-Type">>, <<"application/json">>}],
             #{ result => <<"ok">>,
                txid => Tx
              }
            };
        {error, Err} ->
            {500,
             [{<<"Content-Type">>, <<"application/json">>}],
             #{ result => <<"error">>,
                error => iolist_to_binary(io_lib:format("bad_tx:~s",[Err]))
              }
            }
    end;


h(_Method, [<<"status">>], Req) ->
    {{RemoteIP,_Port},_}=cowboy_req:peer(Req),
    lager:info("Join from ~p",[inet:ntoa(RemoteIP)]),
    %Body=apixiom:bodyjs(Req),

    {200,
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        client => list_to_binary(inet:ntoa(RemoteIP))
      }
    }.

%PRIVATE API


