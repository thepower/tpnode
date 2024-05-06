-module(bsig).
-export([checksig/3, checksig/2]).
-export([checksig1/3, checksig1/2]).
-export([signhash/3, signhash1/3]).
-export([packsig/1, unpacksig/1]).
-export([add_localdata/2]).
-export([set_localdata/2]).
-export([get_localdata/1]).
-export([pack_sign_ed/1, unpack_sign_ed/1]).
-export([add_sig/2]).
-export([extract_pubkey/1, extract_pubkeys/1]).

checksig1(BlockHash, SrcSig) ->
  checksig1(BlockHash, SrcSig, undefined).

checksig1(BlockHash, SrcSig, CheckFun) ->
    HSig=unpacksig(SrcSig),
    #{binextra:=BExt, extra:=Xtra0, signature:=Sig}=US0=unpacksig(HSig),
    PubKey=proplists:get_value(pubkey, Xtra0),
    Xtra=lists:map(
           fun({poa, Bin}) ->
               case checksig1(PubKey,Bin) of
                 false ->
                   {poa_invalid, Bin};
                 {true, Data} ->
                   {poa_valid, Data}
               end;
              (Any) ->
               Any
           end,
           Xtra0),
    US=US0#{extra=>Xtra},

    Msg= <<BExt/binary, BlockHash/binary>>,
    Vrf=tpecdsa:verify(Msg, PubKey, Sig),
    case Vrf of
      correct ->
        BPK=beneficiary(Xtra,#{}),
        C2=if is_function(CheckFun,2) ->
                CheckFun(PubKey,US);
              is_function(CheckFun,3) ->
                CheckFun(maps:get(pubkey,BPK),maps:remove(pubkey,BPK),US);
              CheckFun==undefined ->
                true
           end,
        case {C2,BPK} of
          {true,#{pubkey:=BenPub}} ->
             {true, US#{beneficiary=>BenPub}};
          {true,_} ->
             {true, US};
          {{true, Data}, _} ->
             {true, Data};
          _ ->
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

extract_pubkey(#{beneficiary:=BPK}) ->
  BPK;

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
unpack_sign_ed(<<Attr:8/integer, 1:1, Len:15/integer, Val:Len/binary, Rest/binary>>, Acc) ->
  unpack_sign_ed(Rest, [decode_edval(Attr, Val)|Acc]);

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
decode_edval(5, Bin) -> {poa, Bin};
decode_edval(6, <<Timestamp:64/big>>) -> {expire, Timestamp};
decode_edval(7, <<Address:8/binary, Seq:64/big>>) -> {baldep, {Address,Seq}};
decode_edval(240, <<KL:8/integer, Rest/binary>>=Raw) ->
  try
    <<Key:KL/binary, Val/binary>>=Rest,
    {Key, Val}
  catch _:_ ->
        {240, Raw}
  end;

%decode_edval(254, Bin) -> {purpose, Bin};
decode_edval(255, Bin) -> {signature, Bin};
decode_edval(254, Bin) -> {local_data, Bin};
decode_edval(Key, BinVal) -> {Key, BinVal}.

encode_edval(timestamp, Integer) -> <<1, 8, Integer:64/big>>;
encode_edval(pubkey, PK) -> <<2, (size(PK)):8/integer, PK/binary>>;
encode_edval(createduration, Integer) -> <<3, 8, Integer:64/big>>;
encode_edval(poa, BSig) when size(BSig)<128 ->
  <<5, (size(BSig)):8/integer, BSig/binary>>;
encode_edval(poa, BSig) when size(BSig) < 32767 ->
  <<5, 1:1, (size(BSig)):15/integer, BSig/binary>>;
encode_edval(expire, Integer) -> <<6, 8, Integer:64/big>>;
encode_edval(baldep, {Address,Seq}) ->
  8=size(Address),
  <<7, 16, Address/binary, Seq:64/big>>;
encode_edval(signature, PK) -> <<255, (size(PK)):8/integer, PK/binary>>;
%encode_edval(purpose, PK) -> <<254, (size(PK)):8/integer, PK/binary>>;
encode_edval(N, PK) when is_binary(N) andalso is_binary(PK) ->
  TS=size(N)+size(PK)+1,
  if TS>=64 ->
       throw('binkey_too_big');
     true ->
       <<240, TS:8/integer, (size(N)):8/integer, N/binary, PK/binary>>
  end;
encode_edval(_, _) -> <<>>.

splitsig(Bin) ->
  splitsig(Bin,#{}).

splitsig(<<255, SLen:8/integer, Signature:SLen/binary, Rest/binary>>,A) ->
  A#{signature => Signature,
     binextra => Rest};

splitsig(<<254, LLen:8/integer, LocalData:LLen/binary, Rest/binary>>,A) ->
  splitsig(Rest,A#{local_data => LocalData}).

unpacksig(HSig) when is_map(HSig) ->
    HSig;

unpacksig(BSig) when is_binary(BSig) ->
  #{binextra:=BE}=Split=splitsig(BSig),
  Split#{extra=> unpack_sign_ed(BE)}.

get_localdata(<<254, LLen:8/integer, LD0:LLen/binary, _Rest/binary>>) ->
  LD0;
get_localdata(#{local_data:=LD0}) ->
  LD0;
get_localdata(_) ->
  <<>>.

add_localdata(<<255,_/binary>> = Sig, LD) ->
  <<254, (size(LD)):8/integer, LD/binary, Sig/binary>>;

add_localdata(#{local_data:=LD0}=Sig,LD1) ->
  Sig#{
    local_data => <<LD0/binary,LD1/binary>>
   };

add_localdata(#{}=Sig,LD1) ->
  Sig#{
    local_data => <<LD1/binary>>
   }.

set_localdata(<<255,_/binary>> = Sig, LD) ->
  <<254, (size(LD)):8/integer, LD/binary, Sig/binary>>;

set_localdata(<<254, LLen:8/integer, _LD0:LLen/binary, Rest/binary>>, LD1) ->
  <<254, (size(LD1)):8/integer, LD1/binary, Rest/binary>>;

set_localdata(#{}=Sig,LD1) ->
  Sig#{ local_data => <<LD1/binary>> }.

packsig(BinSig) when is_binary(BinSig) ->
    BinSig;

packsig(#{local_data:=LD, signature:=Signature, binextra:=BinExtra}) ->
    <<254, (size(LD)):8/integer, LD/binary,
      255, (size(Signature)):8/integer, Signature/binary,
      BinExtra/binary>>;

packsig(#{signature:=Signature, binextra:=BinExtra}) ->
    <<255, (size(Signature)):8/integer, Signature/binary,
      BinExtra/binary>>.


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

act(A, L) ->
  lists:foldl(
    fun({baldep,{Addr,Seq}},Acc) ->
        Acc#{ baldep=>[{Addr,Seq}|maps:get(baldep,Acc,[])] };
       ({expire,T},Acc) ->
        Acc#{ tmax => min(T, maps:get(tmax,A,inf)) };
       ({timestamp,T},Acc) ->
        Acc#{ tmin => max(T, maps:get(tmin,A,0)) };
       (_,Acc) -> Acc
    end, A, L).

beneficiary(L,A) ->
  case proplists:get_value(poa_valid,L) of
    undefined ->
      act(A#{ pubkey => proplists:get_value(pubkey, L)}, L);
    #{extra:=L1} when is_list(L1) ->
      beneficiary(L1, act(A,L))
  end.

