-module(beacon).
-export([create/1, check/2, relay/2, parse_relayed/1]).

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
  Bin = <<16#BC, (size(To)):8/integer, To/binary, Payload/binary>>,
  pack_and_sign(Bin, Priv).

%% ------------------------------------------------------------------

parse_relayed(<<16#BC, ToLen:8/integer, Rest/binary>>) ->
  <<To:ToLen/binary, Payload/binary>> = Rest,
  {To, Payload};

parse_relayed(<<16#BE, PayloadLen:8/integer, Rest/binary>> = _Arg) ->
  <<PayloadBin:PayloadLen/binary, Sig/binary>> = Rest,
  HB = crypto:hash(sha256, PayloadBin),
  case bsig:checksig1(HB, Sig) of
    {true, #{extra:=Extra}} ->
      case parse_relayed(PayloadBin) of
        {To, Payload} ->
          From = proplists:get_value(pubkey, Extra),
          #{
            to => To,
            from => From,
            collection => Payload
          };
        _ ->
          error
      end;
    false ->
      error
  end.

%% ------------------------------------------------------------------

pack_and_sign(Bin, Priv) ->
  HB = crypto:hash(sha256, Bin),
  Sig = bsig:signhash(HB, [], Priv),
  <<16#BE, (size(Bin)):8/integer, Bin/binary, Sig/binary>>.


%% ------------------------------------------------------------------

check(<<16#BE, PayloadLen:8/integer, Rest/binary>> = _Arg, Validator) ->
  <<Payload:PayloadLen/binary, Sig/binary>> = Rest,
  <<Timestamp:64/big, Address/binary>> = Payload,
  HB = crypto:hash(sha256, Payload),
  case bsig:checksig1(HB, Sig) of
    {true, #{extra:=Extra}} ->
      SA = proplists:get_value(pubkey, Extra),
      Beacon =
        #{
          to => Address,
          from => SA,
          timestamp => Timestamp
        },
      Validator(Beacon);
    false ->
      error
  end.

