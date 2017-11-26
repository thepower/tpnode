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


gentx(BFrom,To,Amount,HPrivKey) when is_binary(BFrom)->
    From=binary_to_list(BFrom),
    Cur= <<"FTT">>,
    inets:start(),
    {ok,{{_HTTP11,200,_OK},_Headers,Body}}=
    httpc:request(get,{"http://127.0.0.1:43280/api/address/"++From,[]},[],[{body_format,binary}]),
    #{<<"info">>:=C}=jsx:decode(Body,[return_maps]),
    #{<<"seq">>:=Seq}=maps:get(Cur,C,#{<<"amount">> => 0,<<"seq">> => 0}),
    Tx=#{
      amount=>Amount,
      cur=>Cur,
      extradata=>jsx:encode(#{
                   message=><<"preved from gentx">>
                  }),
      from=>BFrom,
      to=>To,
      seq=>Seq+1,
      timestamp=>os:system_time()
     },
    io:format("TX1 ~p.~n",[Tx]),
    NewTx=tx:sign(Tx,address:parsekey(HPrivKey)),
    io:format("TX2 ~p.~n",[NewTx]),
    BinTX=bin2hex:dbin2hex(NewTx),
    io:format("TX3 ~p.~n",[BinTX]),
    {
    tx:unpack(NewTx),
    httpc:request(post,
                  {"http://127.0.0.1:43280/api/tx/new",[],"application/json",<<"{\"tx\":\"0x",BinTX/binary,"\"}">>},
                  [],[{body_format,binary}])
    }.

test_sign_patch() ->
    {ok,HexPrivKey}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(HexPrivKey),
    {Patch, Signature}=settings:sign_patch(
      [
       #{t=>set,p=>[globals,patchsigs], v=>2},
       #{t=>set,p=>[chain,0,blocktime], v=>3}
      ],
      PrivKey),
    MPatch=#{
       patch=>Patch,
       signatures=>[Signature]
      },
    gen_server:call(txpool, {patch, MPatch}).
    %settings:pack_patch(Patch,[Signature]).
