-module(beacon).
-export([create/1, check/1, check/2, relay/2, parse_relayed/1]).

%% ------------------------------------------------------------------

create(To) ->
  Now = os:system_time(seconds),
  Priv = nodekey:get_priv(),
  create(To, Now, Priv).

create(To, Timestamp, Priv) when is_binary(To) ->
  Bin = <<Timestamp:64/big, To/binary>>,
  pack_and_sign(Bin, Priv).

%% ------------------------------------------------------------------

relay(To, Payload) when is_binary(To) andalso is_binary(Payload) ->
  Priv = nodekey:get_priv(),
  relay(To, Payload, Priv).

relay(To, Payload, Priv) ->
  Bin = <<16#BC, (size(To)):32/integer, To/binary, Payload/binary>>,
  pack_and_sign(Bin, Priv, 32).

%% ------------------------------------------------------------------

parse_relayed(<<16#BC, ToLen:32/integer, Rest/binary>>) ->
  <<To:ToLen/binary, Payload/binary>> = Rest,
  {To, Payload};

parse_relayed(<<16#BE, PayloadLen:32/integer, Rest/binary>> = Bin) ->
  <<PayloadBin:PayloadLen/binary, Sig/binary>> = Rest,
  HB = crypto:hash(sha256, PayloadBin),
  case bsig:checksig1(HB, Sig) of
    {true, #{extra:=Extra}=D} ->
      case parse_relayed(PayloadBin) of
        {To, Payload} ->
          Origin = proplists:get_value(pubkey, Extra),
          #{
            check => D,
            to => To,
            from => Origin,
            collection => Payload,
            bin => Bin
           };
        _ ->
          error
      end;
    false ->
      error
  end.

%% ------------------------------------------------------------------

pack_and_sign(Bin, Priv) ->
  pack_and_sign(Bin, Priv, 8).

pack_and_sign(Bin, Priv, SizeLen) when is_binary(Bin) andalso is_binary(Priv) ->
  HB = crypto:hash(sha256, Bin),
  Sig = bsig:signhash(HB, [], Priv),
  <<16#BE, (size(Bin)):SizeLen/integer, Bin/binary, Sig/binary>>.


%% ------------------------------------------------------------------

check(<<16#BE, PL:8/integer, _:PL/binary, _/binary>> = Bin) ->
  check(Bin, fun(E) -> E end).

check(<<16#BE, PayloadLen:8/integer, Payload:PayloadLen/binary, Sig/binary>> = Bin, Validator) ->
  <<Timestamp:64/big, Address/binary>> = Payload,
  HB = crypto:hash(sha256, Payload),
  case bsig:checksig1(HB, Sig) of
    {true, #{extra:=Extra}=D} ->
      Origin = proplists:get_value(pubkey, Extra),
      Beacon =
      #{
        check => D,
        to => Address,
        from => Origin,
        timestamp => Timestamp,
        bin => Bin
       },
      Validator(Beacon);
      false ->
      error
  end.

