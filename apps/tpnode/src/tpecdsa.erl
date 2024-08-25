-module(tpecdsa).
-export([generate_priv/0, minify/1, calc_pub/2, sign/2, verify/3]).
-export([export/2, export/3, import/1, import/2, import/3 ]).
-export([generate_priv/1,import_der/2, calc_pub/1, upgrade_pubkey/1]).
-export([pem_decrypt/2]).
-export([keytype/1, rawkey/1, wrap_pubkey/2]).
-export([cmp_pubkey/1, decipher/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-include_lib("public_key/include/public_key.hrl").

generate_priv() ->
  generate_priv_secp256k1(10).

generate_priv(ed25519) ->
  {_Pub,Priv} = crypto:generate_key(eddsa,ed25519),
  % 302E0201 00300506 032B6570 0422
  % 0420
%  <<16#30,16#2e,16#02,16#01,
%    16#00,16#30,16#05,16#06,
%    16#03,16#2b,16#65,16#70,
%    16#04,16#22,16#04,16#20,Priv/binary>>;
  public_key:der_encode('PrivateKeyInfo',
                        #'ECPrivateKey'{
                           version = 1,
                           privateKey = Priv,
                           parameters = {
                             namedCurve,
                             pubkey_cert_records:namedCurves(ed25519)
                            }
                          }
                       );

generate_priv(secp256k1) ->
  Priv=generate_priv_secp256k1(10),
  %<<16#30,16#2e,16#02,16#01,16#01,
  %  16#04,16#20,Priv/binary,
  %  16#a0,16#07,
  %  16#06,16#05,16#2b,16#81,16#04,16#00,16#0a>>.
  public_key:der_encode('PrivateKeyInfo',
                        #'ECPrivateKey'{
                           version = 1,
                           privateKey = Priv,
                           parameters = {
                             namedCurve,
                             pubkey_cert_records:namedCurves(secp256k1)
                            },
                           publicKey = asn1_NOVALUE,
                           attributes = asn1_NOVALUE
                          }
                       ).

generate_priv_secp256k1(0) ->
  throw('cant_generate');

generate_priv_secp256k1(N) ->
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
    <<Gxp:8/integer, Gy:32/binary>> when Gxp==2 orelse Gxp==3->
      <<Gxp:8/integer, Gy:32/binary>>;
    <<Gxp:8/integer, Gy:32/binary, _:32/binary>> when Gxp==2 orelse Gxp==3->
      <<Gxp:8/integer, Gy:32/binary>>;
    <<4, Gy:32/binary, _:31/binary, Gxx:8/integer>> ->
      Gxp=if Gxx rem 2 == 1 -> 3;
             true -> 2
          end,
      <<Gxp:8/integer, Gy:32/binary>>
  end.

calc_pub(<<Priv:32/binary>>, false) -> %full X
  {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
  XPub;

calc_pub(<<Priv:32/binary>>, true) -> %compact X
  {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
  tpecdsa:minify(XPub);

calc_pub(Priv, _) ->
  calc_pub(Priv).

calc_pub(<<Priv:32/binary>>) ->
  {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
  Pub=tpecdsa:minify(XPub),
  public_key:der_encode('SubjectPublicKeyInfo',
                        #'SubjectPublicKeyInfo'{
                           algorithm =
                           #'AlgorithmIdentifier'{
                              algorithm = {1,2,840,10045,2,1},
                              parameters = asn1_NOVALUE
                             },
                           subjectPublicKey = Pub}
                       );

calc_pub(PrivKey) ->
  #'ECPrivateKey'{
     privateKey=Priv,
     parameters = {namedCurve,Curve}
    }=public_key:der_decode('PrivateKeyInfo',PrivKey),
  case pubkey_cert_records:namedCurves(Curve) of
    secp256k1 ->
      {XPub, _XPrivi} = crypto:generate_key(ecdh, crypto:ec_curve(secp256k1), Priv),
      Pub=tpecdsa:minify(XPub),
      public_key:der_encode('SubjectPublicKeyInfo',
                            #'SubjectPublicKeyInfo'{
                               algorithm =
                               #'AlgorithmIdentifier'{
                                  algorithm = {1,2,840,10045,2,1},
                                  parameters = asn1_NOVALUE
                                 },
                               subjectPublicKey = Pub}
                           );
    ed25519 ->
      {XPub, _XPriv} = crypto:generate_key(eddsa, ed25519, Priv),
      public_key:der_encode('SubjectPublicKeyInfo',
                            #'SubjectPublicKeyInfo'{
                               algorithm =
                               #'AlgorithmIdentifier'{
                                  algorithm = {1,3,101,112},
                                  parameters = asn1_NOVALUE
                                 },
                               subjectPublicKey = XPub}
                           )
  end.

wrap_pubkey(NakedKey, {1,3,101,112}=Algo) ->
  public_key:der_encode('SubjectPublicKeyInfo',
                        #'SubjectPublicKeyInfo'{
                           algorithm =
                           #'AlgorithmIdentifier'{
                              algorithm = Algo,
                              parameters = asn1_NOVALUE
                             },
                           subjectPublicKey = NakedKey}
                       ).

upgrade_pubkey(<<PubKey:33/binary>>) ->
  public_key:der_encode('SubjectPublicKeyInfo',
                        #'SubjectPublicKeyInfo'{
                           algorithm =
                           #'AlgorithmIdentifier'{
                              algorithm = {1,2,840,10045,2,1},
                              parameters = asn1_NOVALUE
                             },
                           subjectPublicKey = PubKey}
                       );
upgrade_pubkey(<<4,_:64/binary>> =PubKey) ->
  public_key:der_encode('SubjectPublicKeyInfo',
                        #'SubjectPublicKeyInfo'{
                           algorithm =
                           #'AlgorithmIdentifier'{
                              algorithm = {1,2,840,10045,2,1},
                              parameters = asn1_NOVALUE
                             },
                           subjectPublicKey = PubKey}
                       );
upgrade_pubkey(<<PubKey:32/binary>>) ->
  public_key:der_encode('SubjectPublicKeyInfo',
                            #'SubjectPublicKeyInfo'{
                               algorithm =
                               #'AlgorithmIdentifier'{
                                  algorithm = {1,3,101,112},
                                  parameters = asn1_NOVALUE
                                 },
                               subjectPublicKey = PubKey}
                           );

upgrade_pubkey(DerEncoded) when is_binary(DerEncoded) ->
  DerEncoded.

sign(Message, <<PrivKey:32/binary>>) ->
  crypto:sign(ecdsa, sha256, Message, [PrivKey, crypto:ec_curve(secp256k1)]);

sign(Message, PrivKey) ->
  #'ECPrivateKey'{
     privateKey=Priv,
     parameters = {namedCurve,Curve}
    }=public_key:der_decode('PrivateKeyInfo',PrivKey),
  case pubkey_cert_records:namedCurves(Curve) of
    secp256k1 ->
      crypto:sign(ecdsa, sha256, Message, [Priv, crypto:ec_curve(secp256k1)]);
    ed25519 ->
      crypto:sign(eddsa, none, Message, [Priv, ed25519])
  end.

verify(Message, <<Public:33/binary>>, Sig) ->
  R=crypto:verify(ecdsa, sha256, Message, Sig, [Public, crypto:ec_curve(secp256k1)]),
  if R -> correct;
     true -> incorrect
  end;

verify(Message, <<4,_:64/binary>> = Public, Sig) ->
  R=crypto:verify(ecdsa, sha256, Message, Sig, [Public, crypto:ec_curve(secp256k1)]),
  if R -> correct;
     true -> incorrect
  end;

verify(Message, Public, Sig) ->
  R=case public_key:der_decode('SubjectPublicKeyInfo', Public) of
      #'SubjectPublicKeyInfo'{
         algorithm = #'AlgorithmIdentifier'{
                        algorithm={1,2,840,10045,2,1} %secp256k1
                       },
         subjectPublicKey = PubKey
        } ->
        crypto:verify(ecdsa, sha256, Message, Sig, [PubKey, crypto:ec_curve(secp256k1)]);
      #'SubjectPublicKeyInfo'{
         algorithm = #'AlgorithmIdentifier'{
                        algorithm={1,3,101,112} %ed25519
                       },
         subjectPublicKey = PubKey
        } ->
        crypto:verify(eddsa, none, Message, Sig, [PubKey, ed25519])
    end,
  if R -> correct;
     true -> incorrect
  end.

cmp_pubkey(<<_:33/binary>>=Public) ->
  {secp256k1, Public};
cmp_pubkey(<<4,_:64/binary>>=Public) ->
  {secp256k1, Public};
cmp_pubkey(<<>>) ->
  {undefined, <<>>};
cmp_pubkey(DerPublic) ->
  case public_key:der_decode('SubjectPublicKeyInfo', DerPublic) of
    #'SubjectPublicKeyInfo'{
       algorithm = #'AlgorithmIdentifier'{
                      algorithm=Algo
                     },
       subjectPublicKey = PubKey
      } ->
      {pkalgo(Algo), PubKey}
  end.

pkalgo({1,2,840,10045,2,1}) ->
  secp256k1;
pkalgo(Algo) ->
  try
    pubkey_cert_records:namedCurves(Algo)
  catch _:_ ->
          Algo 
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
%  <<16#30,16#2e,16#02,16#01,  16#01,16#04,16#20,PrivKey/binary,
%    16#a0,16#07,16#06,16#05,16#2b,16#81,16#04,16#00,16#0a>>;
%  303E0201  00301006072A8648CE3D020106052B8104000A 042730250201 010420
%  FF00FF00000000000000000000000000000000000000000000000000000000FF
  public_key:der_encode('ECPrivateKey',
                        #'ECPrivateKey'{
                           version = 1,
                           privateKey = PrivKey,
                           parameters = {
                             namedCurve,
                             pubkey_cert_records:namedCurves(secp256k1)
                            },
                           publicKey = asn1_NOVALUE,
                           attributes = asn1_NOVALUE
                          }
                       );

export(<<PubKey:33/binary>>,pem) ->
  BDer=base64:encode(export(PubKey,der)),
  <<"-----BEGIN PUBLIC KEY-----\n",
    BDer/binary,
    "\n-----END PUBLIC KEY-----">>;

export(<<PubKey:33/binary>>,der) ->
  <<48,54,48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,10,3,34,0,
    PubKey/binary>>;

export(<<PubKey:65/binary>>,pem) ->
  BDer=base64:encode(export(PubKey,der)),
  <<"-----BEGIN PUBLIC KEY-----\n",
    BDer/binary,
    "\n-----END PUBLIC KEY-----">>;

export(<<PubKey:65/binary>>,der) ->
  <<48,(54+32),48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,10,3,(34+32),0,
    PubKey/binary>>;

export(Key, pem) ->
  case keytype(Key) of
    {pub, _} ->
      #'SubjectPublicKeyInfo'{
         algorithm = #'AlgorithmIdentifier'{
                        algorithm=_A %{1,2,840,10045,2,1}
                       },
         subjectPublicKey = _PubKey } = public_key:der_decode('SubjectPublicKeyInfo', Key),
      BDer=base64:encode(export(Key,der)),
      <<"-----BEGIN PUBLIC KEY-----\n",
        BDer/binary,
        "\n-----END PUBLIC KEY-----">>;
    {priv, secp256k1} ->
      #'ECPrivateKey'{
         version = 1,
         privateKey = _PrivKey,
         parameters = {namedCurve,_Curve} } = public_key:der_decode('PrivateKeyInfo', Key),
      PDer=base64:encode(export(Key,der)),
      <<"-----BEGIN EC PRIVATE KEY-----\n",
        PDer/binary,
        "\n-----END EC PRIVATE KEY-----">>;

    {priv, ed25519} ->
      #'ECPrivateKey'{
         version = 1,
         privateKey = _PrivKey,
         parameters = {namedCurve,_Curve} } = public_key:der_decode('PrivateKeyInfo', Key),
      PDer=base64:encode(export(Key,der)),
      <<"-----BEGIN PRIVATE KEY-----\n",
        PDer/binary,
        "\n-----END PRIVATE KEY-----">>
  end;


export(Key, der) ->
  Key.

keytype(<<_:32/binary>>) ->
  {priv, secp256k1_legacy};
keytype(<<_:33/binary>>) ->
  {pub, secp256k1_legacy};
keytype(<<4,_:64/binary>>) ->
  {pub, secp256k1_legacy};

keytype(Key) ->
  {Kind,Algo,_}=rawkey(Key),
  {Kind, Algo}.
  
rawkey(Key) ->
  try
    #'ECPrivateKey'{
       version = 1,
       privateKey = PrivKey,
       parameters = {namedCurve,Curve} } = public_key:der_decode('PrivateKeyInfo', Key),
    {priv, pubkey_cert_records:namedCurves(Curve), PrivKey}
  catch _:_ ->
    #'SubjectPublicKeyInfo'{
       algorithm = #'AlgorithmIdentifier'{
                      algorithm=A %{1,2,840,10045,2,1}
                     },
       subjectPublicKey = PubKey } = public_key:der_decode('SubjectPublicKeyInfo', Key),
    {pub, pkalgo(A), PubKey}
  end.


import(PEM) -> import(PEM, undefined).

import(PEM, Password, _Opts) ->
  DR=case erlang:function_exported(tpecdsa_pem,decode,1) of
       true ->
         tpecdsa_pem:decode(PEM);
       false ->
         public_key:pem_decode(PEM)
     end,
  import_proc(DR,
              if Password == undefined ->
                   #{};
                 is_binary(Password) ->
                   #{pw=>Password}
              end).

import_proc([{'ECPrivateKey', 
              <<48,62,2,1,0,48,16,6,
                7,42,134,72,206,61,2,1,
                6,5,43,129,4,0,10,4,
                39,48,37,2,1,1,4,32,PrivKey/binary>>,
              not_encrypted}|T],A) ->
  Priv=public_key:der_encode('PrivateKeyInfo',
                                #'ECPrivateKey'{
                                   version = 1,
                                   privateKey = PrivKey,
                                   parameters = {
                                     namedCurve,
                                     pubkey_cert_records:namedCurves(secp256k1)
                                    },
                                   publicKey = asn1_NOVALUE,
                                   attributes = asn1_NOVALUE
                                  }
                               ),
  import_proc(T,A#{priv => Priv});

import_proc([{'ExtraData', 
              <<48,20,12,8,80,87,82,95,65,68,68,82,4,8,Addr:8/binary>>,
              not_encrypted}|T],A) ->
    import_proc(T,A#{addr => Addr});

import_proc([{KeyType, DerKey, not_encrypted}|T],A) ->
  import_proc(T,A#{priv => import_der(KeyType, DerKey)});

import_proc([{_KeyType, _Payload, {_Algo, _Params}}=E0|T], A) ->
  case maps:is_key(pw,A) of
    false ->
      throw('password_needed');
    true ->
      Dst={_,_, not_encrypted}=decipher(E0, maps:get(pw,A)),
      import_proc([Dst|T],A)
      %A#{KeyType => import_der(KeyType, DerKey)}
  end;

import_proc([Other|T],A) ->
  io:format("Ignore ~p~n",[Other]),
  import_proc(T,A);

import_proc([],A) -> A.

pem_decrypt(PEM, Password) ->
  DR=case erlang:function_exported(tpecdsa_pem,decode,1) of
       true ->
         tpecdsa_pem:decode(PEM);
       false ->
         public_key:pem_decode(PEM)
     end,

  lists:map(
    fun({_KeyType, _DerKey, not_encrypted}=E0) ->
        E0;
       ({_KeyType, _Payload, {_Algo, _Params}}=E0) ->
        if(Password == undefined) ->
            throw('password_needed');
          true ->
            {_,_DerKey, not_encrypted}=E=decipher(E0, Password),
            E
        end
    end, DR).

import(PEM, Password) ->
  DR=pem_decrypt(PEM,Password),
  case DR of
    [{KeyType, DerKey, not_encrypted}|_] ->
      import_der(KeyType, DerKey)
  end.

import_der(priv, DerKey) ->
  import_der('PrivateKeyInfo', DerKey);

%import_der('ECPrivateKey', DerKey) ->
%  import_der('PrivateKeyInfo', DerKey);

import_der(pub, DerKey) ->
  import_der('SubjectPublicKeyInfo', DerKey);

import_der(KeyType, DerKey) ->
  io:format("~p ~p~n",[KeyType, DerKey]),
  case public_key:der_decode(KeyType, DerKey) of
    #'ECPrivateKey'{
       version = 1,
       privateKey = PrivKey,
       parameters = {namedCurve,Curve} } ->
      {{priv, pubkey_cert_records:namedCurves(Curve)}, PrivKey};
    #'SubjectPublicKeyInfo'{
       algorithm = #'AlgorithmIdentifier'{
                      algorithm=A %{1,2,840,10045,2,1}
                     },
       subjectPublicKey = PubKey } ->
      {{pub,A}, PubKey}
  end.

-if(?OTP_RELEASE<24).
cipher({KeyType, Payload, "AES-128-CBC"=Cipher}, Password) ->
  IV=crypto:strong_rand_bytes(16),
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  Val=crypto:block_encrypt(aes_cbc128, Key, IV, Payload),
  {KeyType,
   Val,
   {Cipher, IV}
  }.
-else.
cipher({KeyType, Payload, "AES-128-CBC"=Cipher}, Password) ->
  IV=crypto:strong_rand_bytes(16),
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  Val=crypto:crypto_one_time(aes_128_cbc, Key, IV, Payload, true),
  {KeyType,
   Val,
   {Cipher, IV}
  }.
-endif.


-if(?OTP_RELEASE<24).
decipher({KeyType, Payload, {"AES-128-CBC"=Cipher, IV}}, Password) ->
%pubkey_pem:decipher({KeyType, Payload, {"AES-128-CBC", IV}}, Password).
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  {KeyType,
  crypto:block_decrypt(aes_cbc128, Key, IV, Payload),
  not_encrypted
  }.
-else.
decipher({KeyType, Payload, {"AES-128-CBC"=Cipher, IV}}, Password) ->
%pubkey_pem:decipher({KeyType, Payload, {"AES-128-CBC", IV}}, Password).
  <<Salt:8/binary,_/binary>> = IV,
  Key = password_to_key(Password, Cipher, Salt, 16),
  Val=try
        crypto:crypto_one_time(aes_128_cbc, Key, IV, Payload, [{encrypt,false},{padding,pkcs_padding}])
      catch error:{error,_,_} ->
        crypto:crypto_one_time(aes_128_cbc, Key, IV, Payload, [{encrypt,false}])
      end,
  {KeyType,
   Val,
  not_encrypted
  }.
-endif.



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
   ?assertMatch({{pub,_},Pub}, import(PubPEM)),
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
                      calc_pub(SecKey, false),
                      Sig
                     )
              ).



-endif.


% ed25519 keys
% openssl genpkey -algorithm ED25519 > edk
% ✗  cat edk
%-----BEGIN PRIVATE KEY-----
%MC4CAQAwBQYDK2VwBCIEIKbdorPwjavv5sQJHDsQSeQVVHH+/CpNqkg8O78IBRMO
%-----END PRIVATE KEY-----
%
%> hex:encode(base64:decode("MC4CAQAwBQYDK2VwBCIEIKbdorPwjavv5sQJHDsQSeQVVHH+/CpNqkg8O78IBRMO")).
% 302E020100300506032B657004220420A6DDA2B3F08DABEFE6C4091C3B1049E4155471FEFC2A4DAA483C3BBF0805130E
%
%
% > [ hex:encode(E) || E<-tuple_to_list(crypto:generate_key(eddsa,ed25519,hex:decode("A6DDA2B3F08DABEFE6C4091C3B1049E4155471FEFC2A4DAA483C3BBF0805130E"))) ].
%[<<"3BC08BE12521391F10A4096F77A1F45ACBB3BEF43BC056C29A67B9AC6A86A525">>, %pub
% <<"A6DDA2B3F08DABEFE6C4091C3B1049E4155471FEFC2A4DAA483C3BBF0805130E">>] %priv
%
% 302E020100300506032B65700422
% 0420
% A6DDA2B3F08DABEFE6C4091C3B1049E4155471FEFC2A4DAA483C3BBF0805130E

