-module(eth).

-export([
    identity_from_private/1,
    id_from_pubkey/1,
    encode_tx/8,
    encode_tx2/2,
    decode_tx/1,
    decode_tx/2,
    parse_signature/1
    ]).


int_to_bin(0) -> <<>>;
int_to_bin(I) when is_integer(I) -> erlp:int_to_bin(I).

parse_signature(<<48,L1:8/integer,ASN1:L1/binary>>) ->
  <<2,L2:8/integer,R:(L2*8)/big,2,L3:8/integer,S:(L3*8)/big>> = ASN1,
  {R,S}.

identity_from_private(Priv) when is_binary(Priv) andalso size(Priv) == 32 ->
  {<<4:8, Public:64/binary>>, _} = crypto:generate_key(ecdh, secp256k1, Priv),
  Address = id_from_pubkey(Public),
  {Address, Public, Priv};

identity_from_private(_Priv) -> error(badarg).

id_from_pubkey(<<04,Pub:64/binary>>) ->
  {ok,<<_:12/bytes, Address/binary>>} = ksha3:hash(256,Pub),
  Address;

id_from_pubkey(<<Pub:64/binary>>) ->
  {ok,<<_:12/bytes, Address/binary>>} = ksha3:hash(256,Pub),
  Address;

id_from_pubkey(_Pub) -> error(badarg).

encode_tx2(#{chain:=ChainId,
             nonce:=Nonce,
             gasPrice:=GasPrice,
             gasLimit:=GasLimit,
             to:=To,
             value:=Value,
             data:=Data}=M, PrivKey) ->
  case size(To) of
    20 -> ok;
    0 -> ok;
    _ -> throw('bad_address')
  end,
  HTX=[
       int_to_bin(ChainId),
       int_to_bin(Nonce),
       int_to_bin(maps:get(prioGasPrice,M,GasPrice)),
       int_to_bin(GasPrice),
       int_to_bin(GasLimit),
       To,
       int_to_bin(Value),
       Data,
       []
      ],

 PrepTxRLP = erlp:encode(HTX),
% io:format("Pre~n",[]),
% hex:hexdump(PrepTxRLP),
 {ok,Digest} = ksha3:hash(256,<<2,PrepTxRLP/binary>>),
% io:format("Digest ~p~n",[hex:encode(Digest)]),
% {Address, Pub, Priv} =identity_from_private(PrivKey),
% io:format("Priv   ~p~n",[hex:encode(Priv)]),
% io:format("Pub    ~p~n",[hex:encode(Pub)]),
% io:format("Address~p~n",[hex:encode(Address)]),
 Random = crypto:strong_rand_bytes(32),
% Random = <<0:256/big>>,
% io:format("Random ~p~n",[hex:encode(Random)]),
 {ok,<<R:32/binary,S:32/binary>>,V} = ecrecover:sign(Digest, PrivKey, Random),
 V1=int_to_bin(V),
 FinalTx = HTX ++ [V1, R, S],
% io:format("V ~p~nR ~p~nS ~p~n",[V,R,S]),
  %io:format("Final ~p~n",[FinalTx]),
 <<2,(erlp:encode(FinalTx))/binary>>.


encode_tx(ChainId, PrivKey, Nonce, GasPrice, GasLimit, To, Value, Data) ->
 PrepTx = [
  erlp:int_to_bin(Nonce),
  erlp:int_to_bin(GasPrice),
  erlp:int_to_bin(GasLimit),
  To,
  erlp:int_to_bin(Value),
  Data,
  erlp:int_to_bin(ChainId),
 <<>>,
 <<>>],
 PrepTxRLP = erlp:encode(PrepTx),
 {ok,Digest} = ksha3:hash(256,PrepTxRLP),
 %io:format("Digest ~p~n",[hex:encode(Digest)]),
 %io:format("Priv   ~p~n",[hex:encode(PrivKey)]),
 Random = crypto:strong_rand_bytes(32),
 %io:format("Random ~p~n",[hex:encode(Random)]),
 {R,S,V} = ecrecover:sign(Digest, PrivKey, Random),
 FinalTx = [
  erlp:int_to_bin(Nonce),
  erlp:int_to_bin(GasPrice),
  erlp:int_to_bin(GasLimit),
  To,
  erlp:int_to_bin(Value),
  Data,
  erlp:int_to_bin(ChainId * 2 + 35 + V),
  R,
  S],
 erlp:encode(FinalTx).


decode_tx(FinalTxRLP) ->
  decode_tx(0,FinalTxRLP).

decode_tx(_ChainId, <<2,FinalTxRLP/binary>>) ->
  [BChid,
   BNonce,
   MaxPriorityFeePerGas,
   MaxFeePerGas,
   GasLimit,
   To,
   Value,
   Data,
   List,
   BV,
   Rr,
   Sr ] = erlp:decode(FinalTxRLP),
  PrepTxRLP = erlp:encode([BChid,
                           BNonce,
                           MaxPriorityFeePerGas,
                           MaxFeePerGas,
                           GasLimit,
                           To,
                           Value,
                           Data,
                           List]),
  %hex:hexdump(PrepTxRLP),
  {ok,Digest} = ksha3:hash(256,<<2,PrepTxRLP/binary>>),
  R=pad32(Rr),
  S=pad32(Sr),
  {ok,PubKey} = ecrecover:recover(Digest, <<R/binary, S/binary>>, erlp:bin_to_int(BV)),
  From = id_from_pubkey(PubKey),
  [{from,(From)},
   {type,2},
   {chainId,erlp:bin_to_int(BChid)},
   {nonce,erlp:bin_to_int(BNonce)},
   {maxPriorityFeePerGas,erlp:bin_to_int(MaxPriorityFeePerGas)},
   {maxFeePerGas,erlp:bin_to_int(MaxFeePerGas)},
   {gasPrice,erlp:bin_to_int(MaxFeePerGas)},
   {gas,erlp:bin_to_int(GasLimit)},
   {to,To},
   {value, erlp:bin_to_int(Value)},
   {input, Data},
   {accessList,List},
   {v, BV},
   {r, R},
   {s, S},
   {hash, Digest},
   {pubkey, PubKey}
  ];

decode_tx(ChainId, FinalTxRLP) ->
 [Nonce, BGasPrice, BGasLimit, To, BValue, Data, BV, Rr, Sr] = erlp:decode(FinalTxRLP),
 R=pad32(Rr),
 S=pad32(Sr),
 {PrepTx, EIP, V}
 = case erlp:bin_to_int(BV) of
     X when X == 0; X == 1 -> %no EIP-155
       {[Nonce, BGasPrice, BGasLimit, To, BValue, Data], 0, X };
     X when X == 27; X == 28 -> %no EIP-155
       {[Nonce, BGasPrice, BGasLimit, To, BValue, Data], 0, X - 27 };
     X when ChainId==0 -> % EIP-155
       LChid=(X-35)div 2,
       {[Nonce, BGasPrice, BGasLimit, To, BValue, Data,
         erlp:int_to_bin(LChid), <<>>, <<>>], LChid,  X-(LChid*2)-35};
     X when X - ChainId * 2 == 35 ; X - ChainId * 2 == 36 -> % EIP-155
       {[Nonce, BGasPrice, BGasLimit, To, BValue, Data,
         erlp:int_to_bin(ChainId), <<>>, <<>>], (X-35)div 2,  X  - 2 * ChainId- 35};
     _Other ->
       logger:error("eth tx decode error, v=~w requested chainid ~w",[_Other, ChainId]),
       error(badarg)
   end,
 PrepTxRLP = erlp:encode(PrepTx),
 {ok,Digest} = ksha3:hash(256,PrepTxRLP),
 {ok,PubKey} = ecrecover:recover(Digest, <<R/binary, S/binary>>, V),
 From = id_from_pubkey(PubKey),
 [{nonce, erlp:bin_to_int(Nonce)},
  {maxFeePerGas, erlp:bin_to_int(BGasPrice)},
  {chainId, EIP},
  {gasPrice,erlp:bin_to_int(BGasPrice)},
  {gas, erlp:bin_to_int(BGasLimit)},
  {from, From},
  {to, To},
  {value, erlp:bin_to_int(BValue)},
  {input, Data},
  {v, V},
  {r, R},
  {s, S},
  {hash, Digest},
  {pubkey, PubKey},
  {eip155, EIP>0}].

pad32(<<X:32/binary>>) ->
  X;
pad32(X) when size(X)<32 ->
  <<0:((32-size(X))*8)/big,X/binary>>.

