-module(tpic_checkauth).
-include("include/tplog.hrl").
-export([authcheck/3, authgen/2]).

authgen(Challenge, ExtraData) ->
  ?LOG_DEBUG("Gen auth ed:~p", [ExtraData]),
  %crypto:hash(sha256, Challenge).
  bsig:signhash(
    Challenge,
    [{timestamp, os:system_time(millisecond)}],
    nodekey:get_priv()
  ).

authcheck(Challenge, Response, ExtraData) ->
  Res =
    try
      bsig:checksig1(Challenge, Response)
    catch
      Ec:Ee ->
        ?LOG_ERROR(
          "check auth error: ~p:~p challenge: ~p, response: ~p, ed: ~p",
          [Ec, Ee, Challenge, Response, ExtraData]
        ),
        false
    end,
  ?LOG_DEBUG("Check auth ~p ~p:~p ed: ~p", [Res, Challenge, Response, ExtraData]),
  case Res of
    {true, #{extra:=ED}} ->
      PK = proplists:get_value(pubkey, ED, <<>>),
      ?LOG_INFO("TPIC peer authenticated ~p", [ED]),
      {true, [{nodeid, nodekey:node_id(PK)} | ED]};
    false ->
      false
  end.
%Res=crypto:hash(sha256, Challenge)==Response,
%Res.
