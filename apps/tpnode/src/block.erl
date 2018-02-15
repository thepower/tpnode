-module(block).
-export([blkid/1]).
-export([mkblock/1,binarizetx/1,extract/1,outward_mk/2]).
-export([verify/1,outward_verify/1,sign/2,sign/3]).
-export([pack/1,unpack/1]).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

pack(Block) ->
    Prepare=maps:map(
              fun(bals,BalsSnap) ->
                      maps:fold(
                        fun(Address,Snap,Acc) ->
                                maps:put(Address,Snap,Acc)
                        end,#{},BalsSnap);
                 (sync,SyncState) ->
                      maps:fold(
                        fun(Chain,{BlkNo,BlkHash},Acc) ->
                                maps:put(Chain,[BlkNo,BlkHash],Acc)
                        end,#{},SyncState);
                 (sign,Sigs) ->
                      lists:map(
                        fun(Sig) ->
                                bsig:packsig(Sig)
                        end, Sigs);
                 (settings,Txs) ->
                      maps:from_list(
                        lists:map(
                          fun({TxID,T}) ->
                                  {TxID,tx:pack(T)}
                          end, Txs)
                       );
                 (outbound,Txp) ->
                      lager:notice("FIXME: save outbound flag in tx"),
                      lists:map(
                        fun({TxID,Cid}) ->
                                [TxID,Cid]
                        end, Txp
                       );
                 (tx_proof,Txp) ->
                      lists:map(
                        fun({TxID,{A,{B,C}}}) ->
                                [TxID,A,B,C];
                           ({TxID,{A,B}}) ->
                                [TxID,A,B]
                        end, Txp
                       );
                 (txs,Txs) ->
                      lists:map(
                        fun({TxID,T}) ->
                                [TxID,tx:pack(T)]
                        end, Txs
                       );
                 (_,V) ->
                      V
              end,
              Block
             ),
%    file:write_file("tmp/origblk.txt",[io_lib:format("~p.~n",[Block])]),
%    file:write_file("tmp/prepblk.txt",[io_lib:format("~p.~n",[Prepare])]),
    msgpack:pack(Prepare).

unpack(Block) when is_binary(Block) ->
    case msgpack:unpack(Block,[{known_atoms,
                                [hash,outbound,header,settings,txs,sign,bals,
                                 balroot,ledger_hash,height,parent,txroot,tx_proof,
                                 amount,lastblk,seq,t,child,setroot]}]) of
        {ok, Hash} ->
            maps:map(
              fun
                  (bals,BalsSnap) ->
                      maps:fold(
                        fun(Address,Snap,Acc) ->
                                maps:put(Address,Snap,Acc)
                        end,#{},BalsSnap);
                  (sync,SyncState) ->
                      maps:fold(
                        fun(Chain,[BlkNo,BlkHash],Acc) ->
                                maps:put(Chain,{BlkNo,BlkHash},Acc)
                        end,#{},SyncState);
                  (outbound,TXs) ->
                      lists:map(
                        fun([TxID,Cid]) ->
                                {TxID, Cid}
                        end, TXs);
                  (tx_proof,TXs) ->
                      lists:map(
                        fun([TxID,A,B,C]) ->
                                {TxID, {A,{B,C}}};
                           ([TxID,A,B]) ->
                                {TxID, {A,B}}
                        end, TXs);
                  (txs,TXs) ->
                      lists:map(
                        fun([TxID,Tx]) ->
                                {TxID, tx:unpack(Tx)}
                        end, TXs);
                  (settings,Txs) ->
                      lists:map(
                        fun({TxID,T}) ->
                                {TxID,tx:unpack(T)}
                        end, maps:to_list(Txs)
                       );
                  (sign,Sigs) ->
                      lists:map(
                        fun(Sig) ->
                                bsig:unpacksig(Sig)
                        end, Sigs);
                  (_,V) ->
                      V
              end, Hash);
        {error,Err} ->
            throw({block_unpack,Err})
    end.



outward_verify(#{ header:=#{parent:=Parent, height:=H}=Header, 
                  hash:=HdrHash, 
                  sign:=Sigs
                }=Blk) ->
    try
        Txs=maps:get(txs,Blk,[]),
        Txp=maps:get(tx_proof,Blk,[]),
        BTxs=binarizetx(Txs),

        TxRoot=maps:get(txroot,Header,undefined),
        BalsRoot=maps:get(balroot,Header,undefined),
        SettingsRoot=maps:get(setroot,Header,undefined),

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
                   {ledger_hash,maps:get(ledger_hash, Header, undefined)},
                   {setroot,SettingsRoot}
                  ]
                 ),
        Hash=crypto:hash(sha256,BHeader),
        if Hash =/= HdrHash -> throw(false); true -> ok end,
        TxFail=lists:foldl(
                 fun(_,true) -> 
                         true;
                    ({TxID,TxBin},false) ->
                         Proof=proplists:get_value(TxID,Txp),
                         Res=gb_merkle_trees:verify_merkle_proof(TxID,
                                                                 TxBin,
                                                                 TxRoot,
                                                                 Proof),
                         Res=/=ok
                 end, false, BTxs),
        if TxFail -> throw(false); true -> ok end,

        {true, bsig:checksig(Hash, Sigs)}

    catch throw:false ->
              false
    end.

verify(#{ header:=#{parent:=Parent, height:=H}=Header, 
          hash:=HdrHash, 
          sign:=Sigs
        }=Blk) ->

    Txs=maps:get(txs,Blk,[]),
    Bals=maps:get(bals,Blk,#{}),
    Settings=maps:get(settings,Blk,[]),

    BTxs=binarizetx(Txs),
    TxMT=gb_merkle_trees:from_list(BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    BSettings=binarize_settings(Settings),
    SettingsMT=gb_merkle_trees:from_list(BSettings),

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
               {ledger_hash,maps:get(ledger_hash, Header, undefined)},
               {setroot,SettingsRoot}
              ]
             ),

    Hash=crypto:hash(sha256,BHeader),
    %io:format("H1 ~s ~nH2 ~s~n~n",[bin2hex:dbin2hex(Hash),
    %                             bin2hex:dbin2hex(HdrHash)]),
    if Hash =/= HdrHash ->
           false;
       true ->
           {true, bsig:checksig(Hash, Sigs)}
    end.


binarize_settings([]) -> [];
binarize_settings([{TxID,#{ patch:=_LPatch }=Patch}|Rest]) ->
    [{TxID,tx:pack(Patch)}|binarize_settings(Rest)].


mkblock(#{ txs:=Txs, parent:=Parent, height:=H, bals:=Bals, settings:=Settings }=Req) ->
    LH=maps:get(ledger_hash,Req,undefined),
    Txsl=lists:keysort(1,lists:usort(Txs)),
    BTxs=binarizetx(Txsl),
    TxMT=gb_merkle_trees:from_list(BTxs),
    %TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    BSettings=binarize_settings(Settings),
    SettingsMT=gb_merkle_trees:from_list(BSettings),

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
                     {ledger_hash,LH},
                     {setroot,SettingsRoot}
                    ]
                   ),

    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,T1).
    %gb_merkle_trees:merkle_proof (<<"aaa">>,T14) 
    %gb_merkle_trees:from_list([{<<"aaa">>,<<1>>},{<<"bbb">>,<<2>>},{<<"ccc">>,<<4>>}]).
    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,gb_merkle_trees:root_hash(T1),P1aaa)
    Block=#{header=>Hdr,
      hash=>crypto:hash(sha256,BHeader),
      txs=>Txsl,
      bals=>Bals,
      settings=>Settings,
      sign=>[] },
    Block1=case maps:get(tx_proof, Req, []) of
               [] ->
                   Block;
               List ->
                   Proof=lists:map(
                           fun(TxID) ->
                                   {TxID,gb_merkle_trees:merkle_proof (TxID,TxMT)}
                           end, List),
                   maps:put(tx_proof,Proof,Block)
           end,
    case maps:get(inbound_blocks, Req, []) of
               [] ->
                   Block1;
               List2 ->
                   maps:put(inbound_blocks,
                            lists:map(
                              fun({InBlId, InBlk}) ->
                                      {InBlId, maps:remove(txs,InBlk)} 
                              end,List2),
                            Block1)
           end;

mkblock(Blk) ->
    case maps:is_key(settings,Blk) of
        false -> 
            mkblock(maps:put(settings, [], Blk));
        true ->
            io:format("s ~p~n",[maps:keys(Blk)]),
            throw(badmatch)
    end.

outward_mk(TxS,Block) -> 
    outward(TxS,Block,#{}).

outward([],Block,Acc) -> 
    maps:map(
      fun(_K,{Tx,Tp}) ->
              MiniBlock=maps:with([hash,header,sign],Block),
              MiniBlock#{ txs=>Tx, tx_proof=>Tp }
      end,
      Acc);

outward([{TxID,Chain}|Rest],#{txs:=Txs,tx_proof:=Proofs}=Block,Acc) ->
    {ChainTx,ChainTp}=maps:get(Chain,Acc,{[],[]}),
    Tx=proplists:get_value(TxID,Txs),
    Proof=proplists:get_value(TxID,Proofs),
    outward(Rest,
              Block,
              maps:put(Chain,
                       { [{TxID,Tx}|ChainTx], [{TxID,Proof}|ChainTp] } ,Acc)
             ).


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
    L=lists:keysort(1,maps:to_list(NewBal)),
    lists:foldl(
      fun({Addr, %generic bal
           #{amount:=_}=Bal
          } ,Acc) ->
              %TODO: check with integer addresses
              [{Addr, bal:pack(Bal)}|Acc];
         ({Addr, %port
           #{chain:=NewChain}
          },Acc) ->
              [{<<Addr/binary>>,
                <<"pout", NewChain:64/big>>}|Acc]
      end, [], L).

blkid(<<X:8/binary,_/binary>>) ->
    bin2hex:dbin2hex(X).


sign(Blk, ED, PrivKey) when is_map(Blk) ->
    Hash=maps:get(hash,Blk),
    Sign=bsig:signhash(Hash, ED, PrivKey),
    Blk#{
      sign=>[Sign|maps:get(sign,Blk,[])]
     }.

sign(Blk, PrivKey) when is_map(Blk) ->
    Timestamp=os:system_time(millisecond),
    ED=[{timestamp,Timestamp}],
    sign(Blk, ED, PrivKey).


-ifdef(TEST).
block_test() ->
    Priv1Key= <<200,100,200,100,200,100,200,100,200,100,200,100,200,100,200,100,
                200,100,200,100,200,100,200,100,200,100,200,100,200,100,200,100>>,
    Priv2Key= <<200,300,200,100,200,100,200,100,200,100,200,100,200,100,200,100,
                200,300,200,100,200,100,200,100,200,100,200,100,200,100,200,100>>,
    Pub1=tpecdsa:secp256k1_ec_pubkey_create(Priv1Key, true),
    Pub2=tpecdsa:secp256k1_ec_pubkey_create(Priv2Key, true),
    RPatch=[
             #{t=>set,p=>[globals,patchsigs], v=>2},
             #{t=>set,p=>[chains], v=>[0]},
             #{t=>set,p=>[chain,0,minsig], v=>2},
             #{t=>set,p=>[keys,node1], v=>Pub1},
             #{t=>set,p=>[keys,node2], v=>Pub2},
             #{t=>set,p=>[nodechain], v=>#{node1=>0, node2=>0 } }
            ],
    SPatch1= settings:sign(RPatch, Priv1Key),
    SPatch2= settings:sign(SPatch1, Priv2Key),
    lager:info("SPatch ~p",[SPatch2]),
    NewB=mkblock(#{ parent=><<0,0,0,0,0,0,0,0>>,
                    height=>0,
                    txs=>[],
                    bals=>#{},
                    settings=>[
                               {
                                <<"patch123">>,
                                SPatch2
                               }
                              ],
                    sign=>[]
                  }
          ),
    Block=sign(sign(NewB,Priv1Key),Priv2Key),
    Repacked=unpack(pack(Block)),
    [
    %?_assertEqual(Block,unpack(pack(Block))),
    ?_assertMatch({true,{_,0}},verify(Block)),
    ?_assertEqual(Block,Repacked),
    ?_assertEqual(true,lists:all(
                         fun(#{extra:=E}) ->
                                 P=proplists:get_value(pubkey,E),
                                 P==Pub2 orelse P==Pub1
                         end,
                         element(1,element(2,verify(Block))))
                         )
    ].
 
outward_test() ->
    OWBlock= #{hash =>
               <<14,1,228,218,193,8,244,9,208,200,240,233,71,180,102,74,228,105,51,218,
                 183,50,35,187,180,162,124,160,31,202,79,181>>,
               header =>
               #{balroot =>
                 <<242,197,194,74,83,63,114,106,170,29,171,100,110,145,156,229,248,
                   193,67,96,252,37,74,167,55,118,102,39,230,116,92,37>>,
                 height => 2,
                 parent =>
                 <<228,113,37,150,139,59,113,4,159,188,72,2,209,228,10,113,234,19,
                   89,222,207,171,172,247,11,52,88,128,55,212,255,12>>,
                 txroot =>
                 <<152,24,115,240,203,150,198,199,248,230,189,172,102,188,31,1,165,
                   252,31,99,255,128,158,57,173,33,45,254,184,234,184,112>>},
               sign =>
               [<<255,70,48,68,2,32,9,192,225,152,36,213,20,185,130,242,124,4,152,56,
                  254,25,201,20,117,34,110,181,169,142,149,231,180,41,127,45,91,238,2,
                  32,58,8,8,179,135,155,118,195,65,189,150,50,16,110,155,152,100,240,
                  75,192,205,172,202,154,80,130,185,185,68,207,86,99,2,33,3,27,132,197,
                  86,123,18,100,64,153,93,62,213,170,186,5,101,215,30,24,52,96,72,25,
                  255,156,23,245,233,213,221,7,143,1,8,0,0,1,96,6,83,146,206>>],
               tx_proof =>
               [{<<"3crosschain">>,
                 {<<251,228,7,181,109,3,10,116,89,65,126,226,94,160,65,107,54,6,57,240,
                    190,94,81,94,110,18,100,225,240,244,193,225>>,
                  {<<116,218,137,92,172,222,193,162,49,219,55,17,33,216,114,180,76,1,
                     115,192,130,194,213,81,112,18,4,31,143,91,102,98>>,
                   <<22,213,23,196,75,239,21,127,57,214,89,128,188,225,152,85,12,
                     190,58,84,22,187,223,26,60,226,166,182,89,161,134,98>>}}}],
               txs =>
               [{<<"3crosschain">>,
                 #{amount => 9.0,cur => <<"FTT">>,extradata => <<>>,
                   from => <<"73Pa34g3R27Co7KzzNYT7t4UaPjQvpKA6esbuZxB">>,
                   outbound => 1,
                   sig => #{
                   <<"046A21F068BE92697268B60D96C4CA93052EC104E49E003AE2C404F916864372F4137039E85BC2CBA4935B6064B2B79150D99EDC10CA3C29142AA6B7F1E294B159">>
                   =>
                   <<"30440220455607D99DC5566660FCEB508FA980C954F74D4C344F4FCA0AE7709E7CBF4AA802202DC0B61A998AD98FDDB7AFD814F464EF0EFBC6D82CB15C2E0D912AE9D5C33498">>
                    },  %this is incorrect signature for new block format!!!
                   seq => 3,
                   timestamp => 1511934628557211514,
                   to => <<"73f9e9yvV5BVRm9RUw3THVFon4rVqUMfAS1BNikC">>}}]},
    BinOW=pack(OWBlock),
    Repacked=unpack(BinOW),

    [
     ?_assertMatch({true,{_,0}},outward_verify(OWBlock)),
     ?_assertMatch({true,{_,0}},outward_verify(Repacked)),
     ?_assertEqual(Repacked,OWBlock)
    ].

-endif.

