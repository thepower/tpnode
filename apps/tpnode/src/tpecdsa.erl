-module(tpecdsa).
-export([generate_priv/0,minify/1,calc_pub/2,sign/2,verify/3]).
-export([secp256k1_ecdsa_sign/4,
  secp256k1_ecdsa_verify/3,
  secp256k1_ec_pubkey_create/2,
  secp256k1_ec_pubkey_create/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

generate_priv() ->
  generate_priv(10).

generate_priv(0) ->
  throw('cant_generate');
generate_priv(N) ->
  case crypto:generate_key(ecdh, crypto:ec_curve(secp256k1)) of
    {_,<<255,255,255,255,255,255,255,255,255,255,_/binary>>} ->
      %avoid priv keys with leading ones
      generate_priv(N-1);
    {_,<<Private:32/binary>>} ->
      Private;
    _ ->
      %avoid priv keys with leading zeros
      generate_priv(N-1)
  end.

minify(XPub) ->
  case XPub of
    <<Gxp:8/integer,Gy:32/binary,_:31/binary>> when Gxp==2 orelse Gxp==3->
      <<Gxp:8/integer,Gy:32/binary>>;
    <<4,Gy:32/binary,_:31/binary,Gxx:8/integer>> ->
      Gxp=if Gxx rem 2 == 1 -> 3;
            true -> 2
          end,
      <<Gxp:8/integer,Gy:32/binary>>
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

sign(Message,PrivKey) ->
  crypto:sign(ecdsa, sha256, Message, [PrivKey, crypto:ec_curve(secp256k1)]).

verify(Message,Public,Sig) ->
  R=crypto:verify(ecdsa, sha256, Message, Sig, [Public, crypto:ec_curve(secp256k1)]),
  if R -> correct;
    true -> incorrect
  end.


secp256k1_ecdsa_sign(Msg32, SecKey, _Nonce, _NonceData) ->
  sign(Msg32,SecKey).

secp256k1_ecdsa_verify(Msg32, Sig, Pubkey) ->
  verify(Msg32, Pubkey, Sig).

secp256k1_ec_pubkey_create(SecKey) -> %use mini keys by default
  calc_pub(SecKey, true).

secp256k1_ec_pubkey_create(SecKey, Compressed) ->
  calc_pub(SecKey, Compressed).


-ifdef(TEST).
sign_test() ->
  SecKey = <<128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128>>,
  Msg32 = <<"Hello">>,
  << _/binary >> = Sig = secp256k1_ecdsa_sign(Msg32, SecKey, default, <<>>),
  ?assertEqual(correct, secp256k1_ecdsa_verify(Msg32, Sig, secp256k1_ec_pubkey_create(SecKey, false))),
  ?assertEqual(correct, secp256k1_ecdsa_verify(Msg32, Sig, secp256k1_ec_pubkey_create(SecKey, true))),
  ?assertEqual(incorrect, secp256k1_ecdsa_verify(<<1,Msg32/binary>>, Sig, secp256k1_ec_pubkey_create(SecKey, false))).
-endif.