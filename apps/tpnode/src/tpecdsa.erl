-module(tpecdsa).
-export([generate_priv/0, minify/1, calc_pub/2, sign/2, verify/3]).
-export([export/2, export/3, import/1, import/2 ]).

-ifndef(TEST).
-define(TEST,1).
-endif.

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

export(<<PrivKey:32/binary>>,pem,Password) ->
  Der=export(PrivKey,der),
  {'ECPrivateKey', Encoded, {Cipher, IV}}=
  cipher({'ECPrivateKey', Der, "AES-128-CBC"}, Password),
  B64=base64:encode(Encoded),
  HexIV=hex:encode(IV),
  <<"-----BEGIN EC PRIVATE KEY-----\n",
    "Proc-Type: 4,ENCRYPTED\n",
    "DEK-Info: ",(list_to_binary(Cipher))/binary, ",", HexIV/binary, "\n\n",
    B64/binary,
    "\n-----END EC PRIVATE KEY-----">>;

export(<<PubKey:33/binary>>,pem, Password) ->
  Der=export(PubKey,der),
  {'ECPrivateKey', Encoded, {Cipher, IV}}=
  cipher({'ECPrivateKey', Der, "AES-128-CBC"}, Password),
  B64=base64:encode(Encoded),
  HexIV=hex:encode(IV),
  <<"-----BEGIN PUBLIC KEY-----\n",
    "Proc-Type: 4,ENCRYPTED\n",
    "DEK-Info: ",(list_to_binary(Cipher))/binary, ",", HexIV/binary, "\n\n",
    B64/binary,
    "\n-----END PUBLIC KEY-----">>.

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

import(PEM) -> import(PEM, undefined).

import(PEM, Password) ->
  case public_key:pem_decode(PEM) of
    [{KeyType, DerKey, not_encrypted}|_] ->
      import_der(KeyType, DerKey);
    [{KeyType, _Payload, {_Algo, _Params}}=E0|_] ->
      if(Password == undefined) ->
          throw('password_needed');
        true ->
          {_,DerKey, not_encrypted}=decipher(E0, Password),
          import_der(KeyType, DerKey)
      end
  end.

import_der(KeyType, DerKey) ->
  case public_key:der_decode(KeyType, DerKey) of
    #'ECPrivateKey'{
       version = 1,
       privateKey = PrivKey,
       %parameters = {namedCurve,{1,3,132,0,10}}
       parameters = {namedCurve,Curve}
      } ->
      {{priv, pubkey_cert_records:namedCurves(Curve)}, PrivKey};
    #'SubjectPublicKeyInfo'{
       %algorithm = #'AlgorithmIdentifier'{ algorithm={1,2,840,10045,2,1}},
       subjectPublicKey = PubKey
      } ->
      {pub, PubKey}
  end.

cipher({KeyType, Payload, "AES-128-CBC"=Cipher}, Password) ->
  IV=crypto:strong_rand_bytes(16),
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  {KeyType,
   crypto:block_encrypt(aes_cbc128, Key, IV, Payload),
   {Cipher, IV}
  }.

decipher({KeyType, Payload, {"AES-128-CBC"=Cipher, IV}}, Password) ->
%pubkey_pem:decipher({KeyType, Payload, {"AES-128-CBC", IV}}, Password).
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  {KeyType,
  crypto:block_decrypt(aes_cbc128, Key, IV, Payload),
  not_encrypted
  }.

password_to_key(Password, _Cipher, Salt, KeyLen) ->
  <<Key:KeyLen/binary, _/binary>> =
  pem_encrypt(<<>>, Password, Salt, ceiling(KeyLen div 16), <<>>, md5),
  Key.

pem_encrypt(_, _, _, 0, Acc, _) -> Acc;
pem_encrypt(Prev, Password, Salt, Count, Acc, Hash) ->
  Result = crypto:hash(Hash, [Prev, Password, Salt]),
  pem_encrypt(Result, Password, Salt, Count-1 , <<Acc/binary, Result/binary>>, Hash).

ceiling(Float) -> erlang:round(Float + 0.5).

-ifdef(TEST).
pem_keys_test() ->
  Unencrypted_PEM= <<"Some junk before key
-----BEGIN EC PRIVATE KEY-----
MC4CAQEEIMJ8QW3p7GwYMpe92Bcq19wY8PhzljbvOtrdkfaeD9KloAcGBSuBBAAK
-----END EC PRIVATE KEY-----">>,
  Encrypted_PEM= <<"-----BEGIN EC PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,1B4804AD8A132949D1D2229F1EB1577A

jgmW6eetwobwulutRhkjgIJyYr3k9m6Udj0UtdYeq8htuu8B19h+RGhufVxDbJ3h
pkZqWWLpB6DI2rHgjs1Xog==
-----END EC PRIVATE KEY-----">>,
  PubPEM= <<"-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEaiHwaL6SaXJotg2WxMqTBS7BBOSeADri
xAT5FoZDcvQTcDnoW8LLpJNbYGSyt5FQ2Z7cEMo8KRQqprfx4pSxWQ==
-----END PUBLIC KEY-----">>,
  RawPriv=hex:parse("C27C416DE9EC6C183297BDD8172AD7DC18F0F8739636EF3ADADD91F69E0FD2A5"),
  ExportedU=export(RawPriv, pem),
  ExportedE=export(RawPriv, pem, <<"test123">>),
  Pub=tpecdsa:calc_pub(RawPriv, false), %non compact key
  [
   ?assertEqual({pub,Pub}, import(PubPEM)),
   ?assertEqual({{priv,secp256k1},RawPriv}, import(Unencrypted_PEM)),
   ?assertEqual({{priv,secp256k1},RawPriv}, import(Encrypted_PEM, <<"123qwe">>)),
   ?assertEqual({{priv,secp256k1},RawPriv}, import(ExportedU)),
   ?assertEqual({{priv,secp256k1},RawPriv}, import(ExportedE, <<"test123">>))
  ].

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
