-module(tpic_checkauth).
-export([authcheck/3,authgen/2]).

authgen(Challenge, ExtraData) ->
    lager:debug("Gen auth ed:~p",[ExtraData]),
    %crypto:hash(sha256,Challenge).
	bsig:signhash(Challenge,
				  [{timestamp, os:system_time(millisecond)}],
				  nodekey:get_priv()
				 ).

authcheck(Challenge,Response,ExtraData) ->
	Res=bsig:checksig1(Challenge, Response),
	lager:debug("Check auth ~p ~p:~p ed: ~p",[Res,Challenge,Response,ExtraData]),
	case Res of
		{true, #{extra:=ED}} ->
			PK=proplists:get_value(pubkey,ED,<<>>),
			lager:info("TPIC peer authenticated ~p",[ED]),
			{true, [{nodeid,nodekey:node_id(PK)}|ED]};
		false ->
			false;
		_Any ->
			lager:error("Auth module error ~p",[_Any]),
			false
	end.
%Res=crypto:hash(sha256,Challenge)==Response,
%Res.
