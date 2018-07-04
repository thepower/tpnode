-module(tpecdsa).
-export([generate_priv/0, minify/1, calc_pub/2, sign/2, verify/3]).
-export([export/2, import/1 ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-include_lib("public_key/include/public_key.hrl").

generate_priv() ->
  generate_priv(10).

generate_priv(0) ->
  throw('cant_generate');
generate_priv(N) ->
  case crypto:generate_key(ecdh, crypto:ec_curve(secp256k1)) of
    {_, <<255, 255, 255, 255, 255, 255, 255, 255, 255, 255, _/binary>>} ->
      %avoid priv keys with leading ones
      generate_priv(N-1);
    {_, <<Private:32/binary>>} ->
      Private;
    _ ->
      %avoid priv keys with leading zeros
      generate_priv(N-1)
  end.

minify(XPub) ->
  case XPub of
    <<Gxp:8/integer, Gy:32/binary, _:31/binary>> when Gxp==2 orelse Gxp==3->
      <<Gxp:8/integer, Gy:32/binary>>;
    <<4, Gy:32/binary, _:31/binary, Gxx:8/integer>> ->
      Gxp=if Gxx rem 2 == 1 -> 3;
            true -> 2
          end,
      <<Gxp:8/integer, Gy:32/binary>>
  end.

calc_pub(Priv, false) -> %full X
  {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
  %it's ok. regenerated priv can be less tnan 32 bytes, is it with leading zeros
  %BigInt=binary:decode_unsigned(XPrivi),
  %Priv= <<BigInt:256/integer>>,
  XPub;

calc_pub(Priv, true) -> %compact X
  {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
  %it's ok. regenerated priv can be less tnan 32 bytes, is it with leading zeros
  %BigInt=binary:decode_unsigned(XPrivi),
  %Priv= <<BigInt:256/integer>>,
  tpecdsa:minify(XPub).

sign(Message, PrivKey) ->
  crypto:sign(ecdsa, sha256, Message, [PrivKey, crypto:ec_curve(secp256k1)]).

verify(Message, Public, Sig) ->
  R=crypto:verify(ecdsa, sha256, Message, Sig, [Public, crypto:ec_curve(secp256k1)]),
  if R -> correct;
    true -> incorrect
  end.


export(<<PrivKey:32/binary>>,pem) ->
  BDer=base64:encode(export(PrivKey,der)),
  <<"-----BEGIN EC PRIVATE KEY-----\n",
    BDer/binary,
  "\n-----END EC PRIVATE KEY-----">>;

export(<<PrivKey:32/binary>>,der) ->
  <<16#30,16#2e,16#02,16#01,16#01,16#04,16#20,PrivKey/binary,
    16#a0,16#07,16#06,16#05,16#2b,16#81,16#04,16#00,16#0a>>;

export(<<PrivKey:32/binary>>,raw) ->
  PrivKey;

export(<<PubKey:33/binary>>,pem) ->
  BDer=base64:encode(export(PubKey,der)),
  <<"-----BEGIN PUBLIC KEY-----\n",
    BDer/binary,
  "\n-----END PUBLIC KEY-----">>;

export(<<PubKey:33/binary>>,der) ->
  <<48,54,48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,10,3,34,0,
    PubKey/binary>>;

export(<<PubKey:33/binary>>,raw) ->
  PubKey;

export(<<PubKey:65/binary>>,pem) ->
  BDer=base64:encode(export(PubKey,der)),
  <<"-----BEGIN PUBLIC KEY-----\n",
    BDer/binary,
  "\n-----END PUBLIC KEY-----">>;

export(<<PubKey:65/binary>>,der) ->
  <<48,(54+32),48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,10,3,(34+32),0,
    PubKey/binary>>;

export(<<PubKey:65/binary>>,raw) ->
  PubKey.

import(<<"---",_/binary>>=PEM) ->
  [{KeyType, DerKey, not_encrypted}] = public_key:pem_decode(PEM),
  case public_key:der_decode(KeyType, DerKey) of
    #'ECPrivateKey'{
      version = 1,
      privateKey = PrivKey,
      parameters = {namedCurve,{1,3,132,0,10}}
     } ->
      {priv, PrivKey};
    #'SubjectPublicKeyInfo'{
%       algorithm = #'AlgorithmIdentifier'{ algorithm={1,2,840,10045,2,1}},
       subjectPublicKey = PubKey
      } ->
      {pub, PubKey}
  end.

-ifdef(TEST).
sign_test() ->
  SecKey = <<128, 128, 128, 128, 128, 128, 128, 128,
						 128, 128, 128, 128, 128, 128, 128, 128,
						 128, 128, 128, 128, 128, 128, 128, 128,
						 128, 128, 128, 128, 128, 128, 128, 128>>,
  Msg32 = <<"Hello">>,
  << _/binary >> = Sig = sign(Msg32, SecKey),
  ?assertEqual(correct,
							 verify(Msg32, calc_pub(SecKey, false), Sig)
							),
  ?assertEqual(correct,
							 verify(Msg32, calc_pub(SecKey, true), Sig)
							),
  ?assertEqual(incorrect,
							 verify(<<1, Msg32/binary>>,
																			Sig,
																			calc_pub(SecKey, false)
																		 )
							).
-endif.
