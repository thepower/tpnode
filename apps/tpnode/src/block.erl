-module(block).
-export([blkid/1]).
-export([mkblock/1,binarizetx/1,extract/1,verify/1,sign/2,sign/3]).
-export([test/0]).
-export([pack_sign_ed/1,unpack_sign_ed/1,splitsig/1,unpacksig/1]).
-export([checksigs/2,checksig/2]).

test() ->
    {ok,[File]}=file:consult("block.txt"),
    P=maps:get(header, File),
    Blk=maps:merge(P,File),
    NewB=mkblock(Blk
            #{ 
              %txs=>[],
              %bals=>#{},
              settings=>[ {<<"key1">>,<<"value1">>}, {<<"key2">>,<<"value2">>} ] 
              %settings=>[] 
             }
           ),
    Key= <<174,31,206,162,246,54,109,34,119,150,198,143,244,102,85,35,247,216,24,24,222,
  51,33,218,86,115,238,11,251,108,247,98>>,
    Block=sign(NewB,Key),
    {Block,verify(Block)}.
    

checksig(BlockHash, SrcSig) ->
    HSig=unpacksig(SrcSig),
    #{binextra:=BExt,extra:=Xtra,signature:=Sig}=US=block:unpacksig(HSig),
    PubKey=proplists:get_value(pubkey,Xtra),
    Msg=crypto:hash(sha256,<<BExt/binary,BlockHash/binary>>),
    case secp256k1:secp256k1_ecdsa_verify(Msg, Sig, PubKey) of
        correct ->
            {true, US};
        _ ->
            false
    end.

checksigs(BlockHash, Sigs) ->
    lists:foldl(
      fun(SrcSig,{Succ,Fail}) ->
              case checksig(BlockHash, SrcSig) of
                  {true, US} ->
                      {[US|Succ], Fail};
                  false ->
                      {Succ, Fail+1}
              end
      end, {[],0}, Sigs).

verify(#{ header:=#{parent:=Parent, height:=H}, 
          hash:=HdrHash, 
          sign:=Sigs
        }=Blk) ->

    Txs=maps:get(txs,Blk,[]),
    Bals=maps:get(bals,Blk,#{}),
    Settings=maps:get(settings,Blk,[]),

    BTxs=binarizetx(Txs),
    TxMT=gb_merkle_trees:from_list(BTxs),
    %TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    SettingsMT=gb_merkle_trees:from_list(Settings),

    TxRoot=gb_merkle_trees:root_hash(TxMT),
    BalsRoot=gb_merkle_trees:root_hash(BalsMT),
    SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),

    BHeader=lists:foldl(
              fun({_,undefined},ABHhr) ->
                      ABHhr;
                 ({_N,Root},ABHhr) ->
                      <<ABHhr/binary,
                        Root/binary
                      >>
              end,
              <<H:64/integer, %8
                Parent/binary
              >>,
              [{txroot,TxRoot},
               {balroot,BalsRoot},
               {setroot,SettingsRoot}
              ]
             ),

    Hash=crypto:hash(sha256,BHeader),
    if Hash =/= HdrHash ->
           false;
       true ->
           %{ok, TK}=application:get_env(tpnode,trusted_keys),
           %Trusted=lists:map(
           %          fun(K) ->
           %                  hex:parse(K)
           %          end,
           %          TK),
           {true, checksigs(Hash, Sigs)}
    end.

splitsig(<<255,SLen:8/integer,Rest/binary>>) ->
    <<Signature:SLen/binary,Extradata/binary>>=Rest,
    {Signature,Extradata}.

unpacksig(HSig) when is_map(HSig) ->
    HSig;

unpacksig(BSig) when is_binary(BSig) ->
    {Signature,Hdr}=block:splitsig(BSig),
    #{ binextra => (Hdr),
       signature => (Signature),
       extra => block:unpack_sign_ed(Hdr)
     }.

mkblock(#{ txs:=Txs, parent:=Parent, height:=H, bals:=Bals, settings:=Settings }) ->
    BTxs=binarizetx(Txs),
    TxMT=gb_merkle_trees:from_list(BTxs),
    %TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    SettingsMT=gb_merkle_trees:from_list(Settings),

    TxRoot=gb_merkle_trees:root_hash(TxMT),
    BalsRoot=gb_merkle_trees:root_hash(BalsMT),
    SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),

    {BHeader,Hdr}=lists:foldl(
                    fun({_,undefined},{ABHhr,AHdr}) ->
                            {ABHhr,AHdr};
                       ({N,Root},{ABHhr,AHdr}) ->
                            {
                             <<ABHhr/binary,
                               Root/binary
                             >>,
                             maps:put(N,Root,AHdr)
                            }
                    end,

                    {
                     <<H:64/integer, %8
                       Parent/binary
                     >>,
                     #{ parent=>Parent, height=>H }
                    }, 
                    [{txroot,TxRoot},
                     {balroot,BalsRoot},
                     {setroot,SettingsRoot}
                    ]
                   ),

    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,T1).
    %gb_merkle_trees:merkle_proof (<<"aaa">>,T14) 
    %gb_merkle_trees:from_list([{<<"aaa">>,<<1>>},{<<"bbb">>,<<2>>},{<<"ccc">>,<<4>>}]).
    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,gb_merkle_trees:root_hash(T1),P1aaa)
    #{header=>Hdr,
      hash=>crypto:hash(sha256,BHeader),
      txs=>Txs,
      bals=>Bals,
      settings=>Settings,
      sign=>[] };

mkblock(Blk) ->
    case maps:is_key(settings,Blk) of
        false -> 
            mkblock(maps:put(settings, [], Blk));
        true ->
            io:format("s ~p~n",[maps:keys(Blk)]),
            throw(badmatch)
    end.

binarizetx([]) ->
    [];

binarizetx([{TxID,Tx}|Rest]) ->
    BTx=tx:pack(Tx),
    %TxIDLen=size(TxID),
    %TxLen=size(BTx),
    %<<TxIDLen:8/integer,TxLen:16/integer,TxID/binary,BTx/binary,(binarizetx(Rest))/binary>>.
    [{TxID,BTx}|binarizetx(Rest)].

extract(<<>>) ->
    [];

extract(<<TxIDLen:8/integer,TxLen:16/integer,Body/binary>>) ->
    <<TxID:TxIDLen/binary,Tx:TxLen/binary,Rest/binary>> = Body,
    [{TxID,tx:unpack(Tx)}|extract(Rest)].

    
bals2bin(NewBal) ->
    lists:foldl(
      fun({{Addr,Cur},
           #{amount:=Amount,
             seq:=Seq,
             t:=T
            }
          },Acc) ->
              BAmount=trunc(Amount*1.0e9),
              [{<<Addr/binary,":",Cur/binary>>,
                <<BAmount:64/big,
                  Seq:64/big,
                  T:64/big>>}|Acc]
      end, [],
      lists:keysort(1,maps:to_list(NewBal))
     ).

blkid(<<X:8/binary,_/binary>>) ->
    bin2hex:dbin2hex(X).

signhash(MsgHash, Timestamp, PrivKey) ->
    PubKey=secp256k1:secp256k1_ec_pubkey_create(PrivKey, true),
    BinExtra= pack_sign_ed([
             {pubkey,PubKey},
             {timestamp,Timestamp}
            ]),
    Msg=crypto:hash(sha256,<<BinExtra/binary,MsgHash/binary>>),
    Signature=secp256k1:secp256k1_ecdsa_sign(Msg, PrivKey, default, <<>>),
    <<255,(size(Signature)):8/integer,Signature/binary,BinExtra/binary>>.

sign(Blk, Timestamp, PrivKey) when is_map(Blk) ->
    Hash=maps:get(hash,Blk),
    Sign=signhash(Hash, Timestamp, PrivKey),
    Blk#{
      sign=>[Sign|maps:get(sign,Blk,[])]
     }.

sign(Blk, PrivKey) when is_map(Blk) ->
    Timestamp=os:system_time(millisecond),
    sign(Blk, Timestamp, PrivKey).

unpack_sign_ed(Bin) -> unpack_sign_ed(Bin,[]).
unpack_sign_ed(<<>>,Acc) -> lists:reverse(Acc);
unpack_sign_ed(<<Attr:8/integer,Len:8/integer,Bin/binary>>,Acc) ->
    <<Val:Len/binary,Rest/binary>>=Bin,
    unpack_sign_ed(Rest,[decode_edval(Attr,Val)|Acc]).


pack_sign_ed(List) ->
    lists:foldl( fun({K,V},Acc) ->
                         Val=encode_edval(K,V),
                         <<Acc/binary,Val/binary>>
                 end, <<>>, List).

decode_edval(1,<<Timestamp:64/big>>) -> {timestamp, Timestamp}; 
decode_edval(2,Bin) -> {pubkey, Bin}; 
decode_edval(255,Bin) -> {signature, Bin}; 
decode_edval(Key,BinVal) -> {Key, BinVal}.

encode_edval(timestamp, Integer) -> <<1,8,Integer:64/big>>;
encode_edval(pubkey, PK) -> <<2,(size(PK)):8/integer,PK/binary>>;
encode_edval(signature, PK) -> <<255,(size(PK)):8/integer,PK/binary>>;
encode_edval(_, _) -> <<>>.


