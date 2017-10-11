-module(scratchpad).
-compile(export_all).

node_id() ->
    {ok,K1}=application:get_env(tpnode,privkey),
    address:pub2addr(node,secp256k1:secp256k1_ec_pubkey_create(hex:parse(K1), true)).

sign(Message) ->
    {ok,PKeyH}=application:get_env(tpnode,privkey),
    PKey=hex:parse(PKeyH),
    Msg32 = crypto:hash(sha256, Message),
    Sig = secp256k1:secp256k1_ecdsa_sign(Msg32, PKey, default, <<>>),
    Pub=secp256k1:secp256k1_ec_pubkey_create(PKey, true),
    <<Pub/binary,Sig/binary,Message/binary>>.

verify(<<Public:33/binary,Sig:71/binary,Message/binary>>) ->
    {ok,TrustedKeys}=application:get_env(tpnode,trusted_keys),
    Found=lists:foldl(
      fun(_,true) -> true;
         (HexKey,false) ->
              Pub=hex:parse(HexKey),
              Pub == Public
      end,false, TrustedKeys),
    Msg32 = crypto:hash(sha256, Message),
    {Found,secp256k1:secp256k1_ecdsa_verify(Msg32, Sig, Public)}.




