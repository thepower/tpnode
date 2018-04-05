-module(beacon).
-export([create/1, check/1]).

create(To) ->
	T=os:system_time(seconds),
	Priv=nodekey:get_priv(),
	create(To, T, Priv).

create(To, Timestamp, Priv) ->
	Bin= <<Timestamp:64/big, To/binary>>,
	HB=crypto:hash(sha256, Bin),
	Sig=bsig:signhash(HB, [], Priv),
	<<16#BE, (size(Bin)):8/integer, Bin/binary, Sig/binary>>.

check(<<16#BE, PayloadLen:8/integer, Rest/binary>>=_Arg) ->
	<<Payload:PayloadLen/binary, Sig/binary>>=Rest,
	<<Timestamp:64/big, Address/binary>>=Payload,
	HB=crypto:hash(sha256, Payload),
	case bsig:checksig1(HB, Sig) of
		{true, #{extra:=Extra}} ->
			SA=proplists:get_value(pubkey, Extra),
			#{ to=>Address,
			   from=>SA,
			   timestamp=>Timestamp
			 };
		false ->
			error
	end.

