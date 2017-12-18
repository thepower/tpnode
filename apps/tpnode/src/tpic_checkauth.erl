-module(tpic_checkauth).
-export([authcheck/3,authgen/2]).

authgen(Challenge, ExtraData) ->
    lager:info("Gen auth ed:~p",[ExtraData]),
    crypto:hash(sha256,Challenge).

authcheck(Challenge,Response,ExtraData) ->
    Res=crypto:hash(sha256,Challenge)==Response,
    lager:info("Check auth ~p ~p:~p ed: ~p",[Res,Challenge,Response,ExtraData]),
    Res.
