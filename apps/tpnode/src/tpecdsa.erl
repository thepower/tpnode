-module(tpecdsa).
-export([generate_priv/0,minify/1,calc_pub/2,sign/2,verify/3]).
-export([secp256k1_ecdsa_sign/4,
         secp256k1_ecdsa_verify/3, 
         secp256k1_ec_pubkey_create/2,
         secp256k1_ec_pubkey_create/1
        ]).
-export([simple/0]).

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

%crypto:ec_curve(secp256k1)
%
%{{prime_field,<<"ÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿþÿÿü/">>}, 
% p=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
%
%{<<0>>,<<7>>,none},
% a=0
% b=7
%
%<<4,121,190,102,126,249,220,187,172,85,160,98,149,206,135,11,7,2,155,252,219,
%  45,206,40,217,89,242,129,91,22,248,23,152,72,58,218,119,38,163,196,101,93,
%  164,251,252,14,17,8,168,253,23,180,72,166,133,84,25,156,71,208,143,251,16,
%  212,184>>,
%G=04 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798 483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C4
%
%<<255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,254,186,174,220,
%  230,175,72,160,59,191,210,94,140,208,54,65,65>>,
%n=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
%
%<<1>>}
%h=1 group cofactor

simple() ->
    {{prime_field,<<23:256/big>>}, 
     {<<13>>,<<10>>,none},
     <<4,18:256/big,2:256/big>>,
     <<19:256/big>>,
     <<1>>}.

