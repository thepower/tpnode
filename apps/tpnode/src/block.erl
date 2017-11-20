-module(block).
-export([blkid/1]).
-export([mkblock/1,binarizetx/1,extract/1,verify/1,sign/2]).
-export([test/0]).

test() ->
    {ok,[File]}=file:consult("block.txt"),
    P=maps:get(header, File),
    Blk=maps:merge(P,File),
    NewB=mkblock(Blk
            #{ 
              txs=>[],
              bals=>#{}
              %settings=>[ {<<"key1">>,<<"value1">>}, {<<"key2">>,<<"value2">>} ] 
             }
           ),
    Key= <<174,31,206,162,246,54,109,34,119,150,198,143,244,102,85,35,247,216,24,24,222,
  51,33,218,86,115,238,11,251,108,247,98>>,
    sign(NewB,Key).

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

verify(#{ txs:=Txs, header:=#{parent:=Parent, height:=H}, hash:=HdrHash, sign:=Sigs, bals:=Bals }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsHash=crypto:hash(sha256,BalsBin),
    BHeader = <<H:64/integer, %8
               TxHash/binary, %32
               Parent/binary,
               BalsHash/binary
             >>,
    Hash=crypto:hash(sha256,BHeader),
    if Hash =/= HdrHash ->
           false;
       true ->
           {ok, TK}=application:get_env(tpnode,trusted_keys),
           Trusted=lists:map(
                     fun(K) ->
                             hex:parse(K)
                     end,
                     TK),
           {true,lists:foldl(
             fun({PubKey,Sig},{Succ,Fail}) ->
                     case lists:member(PubKey,Trusted) of
                         false ->
                             {Succ, Fail+1};
                         true ->
                             case secp256k1:secp256k1_ecdsa_verify(Hash, Sig, PubKey) of
                                 correct ->
                                     {[{PubKey,Sig}|Succ], Fail};
                                 _ ->
                                     {Succ, Fail+1}
                             end
                     end
             end, {[],0}, Sigs)}
    end.

    
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
    BinTS= <<Timestamp:64/big>>,
    Msg=crypto:hash(sha256,<<BinTS/binary,MsgHash/binary>>),
    {secp256k1:secp256k1_ec_pubkey_create(PrivKey, true),
     BinTS,
     secp256k1:secp256k1_ecdsa_sign(Msg, PrivKey, default, <<>>)}.

sign(Blk, PrivKey) when is_map(Blk) ->
    Hash=maps:get(hash,Blk),
    Timestamp=os:system_time(millisecond),
    Sign=signhash(Hash, Timestamp, PrivKey),
    Blk#{
      sign=>[Sign|maps:get(sign,Blk,[])]
     }.


