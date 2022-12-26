-module(bsig).
-export([checksig/3, checksig/2]).
-export([checksig1/3, checksig1/2]).
-export([signhash/3, signhash1/3]).
-export([packsig/1, unpacksig/1]).
-export([pack_sign_ed/1, unpack_sign_ed/1]).
-export([add_sig/2]).
-export([extract_pubkey/1, extract_pubkeys/1]).

checksig1(BlockHash, SrcSig) ->
  checksig1(BlockHash, SrcSig, undefined).

checksig1(BlockHash, SrcSig, CheckFun) ->
    HSig=unpacksig(SrcSig),
    #{binextra:=BExt, extra:=Xtra, signature:=Sig}=US=unpacksig(HSig),
    PubKey=proplists:get_value(pubkey, Xtra),
    Msg= <<BExt/binary, BlockHash/binary>>,
    Vrf=tpecdsa:verify(Msg, PubKey, Sig),
    case Vrf of
        correct ->
            C2=if is_function(CheckFun) ->
                    CheckFun(PubKey,US);
                  CheckFun==undefined ->
                    true
               end,
            if C2 ->
                 {true, US};
               true ->
                 false
            end;
        _ ->
            false
    end.

checksig(BlockHash, Sigs) ->
  checksig(BlockHash, Sigs, undefined).

checksig(BlockHash, Sigs, CheckFun) ->
    lists:foldl(
      fun(SrcSig, {Succ, Fail}) ->
              case checksig1(BlockHash, SrcSig, CheckFun) of
                  {true, US} ->
                      {[US|Succ], Fail};
                  false ->
                      {Succ, Fail+1}
              end
      end, {[], 0}, Sigs).

extract_pubkey(#{extra:=Xtra}) ->
        proplists:get_value(pubkey, Xtra).

extract_pubkeys(BSList) ->
  lists:map(fun extract_pubkey/1, BSList).

signhash1(MsgHash, ExtraData, PrivKey) ->
    BinExtra=pack_sign_ed(ExtraData),
    Msg= <<BinExtra/binary, MsgHash/binary>>,
    Signature=tpecdsa:sign(Msg, PrivKey),
    <<255, (size(Signature)):8/integer, Signature/binary, BinExtra/binary>>.

signhash(MsgHash, ExtraData, PrivKey) ->
  PubKey=tpecdsa:calc_pub(PrivKey),
  signhash1(MsgHash, [{pubkey, PubKey}|ExtraData], PrivKey).

unpack_sign_ed(Bin) -> unpack_sign_ed(Bin, []).
unpack_sign_ed(<<>>, Acc) -> lists:reverse(Acc);
unpack_sign_ed(<<Attr:8/integer, Len:8/integer, Bin/binary>>, Acc) when Len<128 ->
    <<Val:Len/binary, Rest/binary>>=Bin,
    unpack_sign_ed(Rest, [decode_edval(Attr, Val)|Acc]).

pack_sign_ed(List) ->
    lists:foldl( fun({K, V}, Acc) ->
                         Val=encode_edval(K, V),
                         <<Acc/binary, Val/binary>>
                 end, <<>>, List).

% general pupose fields
decode_edval(1, <<Timestamp:64/big>>) -> {timestamp, Timestamp};
decode_edval(2, Bin) -> {pubkey, Bin};
decode_edval(3, <<TimeDiff:64/big>>) -> {createduration, TimeDiff};
decode_edval(4, <<TimeDiff:64/big>>) -> {createduration, TimeDiff};
decode_edval(240, <<KL:8/integer, Rest/binary>>=Raw) ->
  try
    <<Key:KL/binary, Val/binary>>=Rest,
    {Key, Val}
  catch _:_ ->
        {240, Raw}
  end;

decode_edval(254, Bin) -> {purpose, Bin};
decode_edval(255, Bin) -> {signature, Bin};
decode_edval(Key, BinVal) -> {Key, BinVal}.

encode_edval(timestamp, Integer) -> <<1, 8, Integer:64/big>>;
encode_edval(pubkey, PK) -> <<2, (size(PK)):8/integer, PK/binary>>;
encode_edval(createduration, Integer) -> <<3, 8, Integer:64/big>>;
encode_edval(signature, PK) -> <<255, (size(PK)):8/integer, PK/binary>>;
encode_edval(purpose, PK) -> <<254, (size(PK)):8/integer, PK/binary>>;
encode_edval(N, PK) when is_binary(N) andalso is_binary(PK) ->
  TS=size(N)+size(PK)+1,
  if TS>=64 ->
       throw('binkey_too_big');
     true ->
       <<240, TS:8/integer, (size(N)):8/integer, N/binary, PK/binary>>
  end;
encode_edval(_, _) -> <<>>.

splitsig(<<255, SLen:8/integer, Signature:SLen/binary, Rest/binary>>) ->
    {Signature, Rest}.

unpacksig(HSig) when is_map(HSig) ->
    HSig;

unpacksig(BSig) when is_binary(BSig) ->
    {Signature, Hdr}=splitsig(BSig),
    #{ binextra => (Hdr),
       signature => (Signature),
       extra => unpack_sign_ed(Hdr)
     }.

packsig(BinSig) when is_binary(BinSig) ->
    BinSig;
packsig(#{signature:=Signature, binextra:=BinExtra}) ->
    <<255, (size(Signature)):8/integer, Signature/binary, BinExtra/binary>>.

add_sig(OldSigs, NewSigs) ->
  Apply=fun(#{extra:=EPL}=Sig, Acc) ->
            case proplists:get_value(pubkey, EPL) of
              undefined -> Acc;
              Bin -> 
                PK=tpecdsa:cmp_pubkey(Bin),
                case maps:is_key(PK, Acc) of
                  true -> Acc;
                  false -> maps:put(PK, Sig, Acc)
                end
            end
        end,
  Map1=lists:foldl(Apply, #{}, OldSigs),
  Map2=lists:foldl(Apply, Map1, NewSigs),
  maps:values(Map2).

