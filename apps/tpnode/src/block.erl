-module(block).
-include("include/tplog.hrl").
-export([blkid/1]).
-export([mkblock2/1, binarizetx/1, extract/1, outward_mk/2, outward_mk/1]).
-export([verify/2]).
-export([verify/1, outward_verify/1, sign/2, sign/3, sigverify/2]).
-export([prepack/1, binarizefail/1]).
-export([pack/1, unpack/1]).
-export([packsig/1, unpacksig/1]).
-export([split_packet/2, split_packet/1, glue_packet/1]).
-export([outward_chain/2, outward_ptrs/2]).
-export([pack_mproof/1, unpack_mproof/1]).
-export([ledger_hash/1]).

-export([bals2bin/1]).
-export([minify/1]).

%% split large blocks to small packets of that size
-define(SPLIT_PACKET_SIZE, 64*1024).

unpack_mproof(M) ->
  list_to_tuple(
    lists:map(
      fun(E) when is_binary(E) -> E;
         (E) when is_list(E) -> unpack_mproof(E)
      end, M)).

pack_mproof(M) ->
  lists:map(
    fun(E) when is_binary(E) -> E;
       (E) when is_tuple(E) -> pack_mproof(E);
       (E) when is_list(E) -> pack_mproof(E)
    end,
    if is_tuple(M) ->
         tuple_to_list(M);
       is_list(M) ->
         M
    end).

ledger_hash(#{header:=#{roots:=R}}) ->
  proplists:get_value(ledger_hash, R, <<0:256>>).

minify(#{hash:=_,header:=_,sign:=_}=Block) ->
  maps:with([hash, header, sign], Block).

prepack(Block) ->
  maps:map(
    fun(header, #{roots:=R}=Header) ->
        Header#{
          roots=>[ [RK,RV] || {RK,RV} <- R ]
         };
       (bals, BalsSnap) ->
        maps:fold(
          fun(Address, Snap, Acc) ->
              maps:put(Address, mbal:pack(Snap), Acc)
          end, #{}, BalsSnap);
       (sync, SyncState) ->
        maps:fold(
          fun(Chain, {BlkNo, BlkHash}, Acc) ->
              maps:put(Chain, [BlkNo, BlkHash], Acc)
          end, #{}, SyncState);
       (sign, Sigs) ->
        lists:map(
          fun(Sig) ->
              bsig:packsig(Sig)
          end, Sigs);
       (settings, Txs) ->
        maps:from_list(
          lists:map(
            fun({TxID, T}) ->
                {TxID, pack_patch(T)}
            end, Txs)
         );
       (inbound_blocks, Blocks) ->
        maps:from_list(
          lists:map(
            fun({TxID, T}) ->
                {TxID, block:pack(T)}
            end, Blocks)
         );
       (outbound, Txp) ->
        ?LOG_NOTICE("FIXME: save outbound flag in tx"),
        lists:map(
          fun({TxID, Cid}) ->
              [TxID, Cid]
          end, Txp
         );
       (tx_proof, Txp) ->
        lists:map(
          fun({TxID, MProof}) ->
              [TxID, pack_mproof(MProof)];
             (Any) ->
              throw({dont_know_how_to_pack, Any})
          end, Txp
         );
       (extdata, ED) when is_list(ED) ->
        lists:map(
          fun({Key, Val}) ->
              [Key, Val]
          end, ED
         );
       (extdata, ED) ->
        ?LOG_NOTICE("TODO: there is maps here sometimes. Find out problem in unpacker ~p",[ED]),
        lists:map(
          fun({Key, Val}) ->
              [Key, Val]
          end, maps:to_list(ED)
         );
       (failed, Txs) ->
        lists:map(
          fun({TxID, #{<<"ext">>:=Arr}=T}) when is_list(Arr) ->
              [TxID, T#{<<"ext">>=>{array, Arr}}];
             ({TxID, T}) ->
              [TxID, T]
          end, Txs
         );
       (etxs, Txs) ->
        lists:map(
          fun({TxID, T}) ->
              [TxID, tx:pack(T,[withext])]
          end, Txs
         );
       (txs, Txs) ->
        lists:map(
          fun({TxID, T}) ->
              [TxID, tx:pack(T,[withext])]
          end, Txs
         );
       (_, V) ->
        V
    end,
    Block
   ).
pack(Block) ->
  Prepare=prepack(Block),
  %    file:write_file("tmp/origblk.txt", [io_lib:format("~p.~n", [Block])]),
  %    file:write_file("tmp/prepblk.txt", [io_lib:format("~p.~n", [Prepare])]),
  Packed=msgpack:pack(Prepare),
  if is_binary(Packed) ->
       Packed;
     true ->
       file:write_file("log/pack_error.txt",
                       [io_lib:format("~p.~n", [Block])]),
       throw({cant_pack, Packed})
  end.

unpack(Block) when is_binary(Block) ->
  Atoms=[hash, outbound, header, settings, txs, etxs, sign, bals,
         balroot, ledger_hash, height, parent, txroot, tx_proof,
         amount, lastblk, seq, t, child, setroot, tmp, ver,
         inbound_blocks, chain, extdata, roots, failed,
         mean_time, entropy, etxroot],
  case msgpack:unpack(Block, [{known_atoms, Atoms}]) of
    {ok, DMP} ->
      ConvertFun=fun (header, #{roots:=RootsList}=Header) ->
                     Header#{
                       roots=>[ {RK,RV} || [RK,RV] <- RootsList ]
                      };
                     (bals, BalsSnap) ->
                     maps:fold(
                       fun(Address, BinSnap, Acc) ->
                           maps:put(Address, mbal:unpack(BinSnap), Acc)
                       end, #{}, BalsSnap);
                     (sync, SyncState) ->
                     maps:fold(
                       fun(Chain, [BlkNo, BlkHash], Acc) ->
                           maps:put(Chain, {BlkNo, BlkHash}, Acc)
                       end, #{}, SyncState);
                     (outbound, TXs) ->
                     lists:map(
                       fun([TxID, Cid]) ->
                           {TxID, Cid}
                       end, TXs);
                     (tx_proof, TXs) ->
                     lists:map(
                       fun([TxID, Proof]) ->
                           {TxID, unpack_mproof(Proof)}
                       end, TXs);
                     (failed, TXs) ->
                     lists:map(
                       fun([TxID, Tx]) ->
                           {TxID, Tx}
                       end, TXs);
                     (etxs, TXs) ->
                     lists:map(
                       fun([TxID, Tx]) ->
                           {TxID, tx:unpack(Tx,[trusted])}
                       end, TXs);
                     (txs, TXs) ->
                     lists:map(
                       fun([TxID, Tx]) ->
                           {TxID, tx:unpack(Tx,[trusted])}
                       end, TXs);
                     (extdata, ED) ->
                     lists:map(
                       fun([Key, Val]) ->
                           {Key, Val}
                       end, ED);
                     (inbound_blocks, Blocks) ->
                     lists:map(
                       fun({TxID, T}) ->
                           {TxID, block:unpack(T)}
                       end, maps:to_list(Blocks)
                      );
                     (settings, Txs) ->
                     lists:map(
                       fun({TxID, T}) ->
                           {TxID, tx:unpack(T,[trusted])}
                       end, maps:to_list(Txs)
                      );
                     (sign, Sigs) ->
                     lists:map(
                       fun(Sig) ->
                           bsig:unpacksig(Sig)
                       end, Sigs);
                     (_, V) ->
                     V
                 end,
      #{header:=H}=UBlk=maps:map(ConvertFun, DMP),
      case maps:get(roots, H, undefined) of
        undefined -> UBlk;
        RootsPL ->
          case lists:keyfind(tmp,1,RootsPL) of
            {tmp, <<TmpID:64/big>>} ->
              UBlk#{temporary => TmpID };
            false -> UBlk
          end
      end;
    {error, Err} ->
      throw({block_unpack, Err})
  end.



outward_verify(#{ header:=#{parent:=Parent, height:=H}=Header,
                  hash:=HdrHash,
                  sign:=Sigs
                }=Blk) ->
  try
    Txs=maps:get(txs, Blk, []),
    Txp=maps:get(tx_proof, Blk, []),
    BTxs=binarizetx(Txs),

    TxRoot=maps:get(txroot, Header, undefined),
    BalsRoot=maps:get(balroot, Header, undefined),
    SettingsRoot=maps:get(setroot, Header, undefined),

    BHeader=lists:foldl(
              fun({_, undefined}, ABHhr) ->
                  ABHhr;
                 ({_N, Root}, ABHhr) ->
                  <<ABHhr/binary,
                    Root/binary
                  >>
              end,
              <<H:64/integer, %8
                Parent/binary
              >>,
              [{txroot, TxRoot},
               {balroot, BalsRoot},
               {ledger_hash, maps:get(ledger_hash, Header, undefined)},
               {setroot, SettingsRoot}
              ]
             ),
    Hash=crypto:hash(sha256, BHeader),
    if Hash =/= HdrHash -> throw(false); true -> ok end,
    TxFail=lists:foldl(
             fun(_, true) ->
                 true;
                ({TxID, TxBin}, false) ->
                 Proof=proplists:get_value(TxID, Txp),
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

sigverify(#{hash:=Hash}, Sigs) ->
  bsig:checksig(Hash, Sigs).

verify(#{ header:=#{parent:=Parent, %blkv2
                    height:=H,
                    chain:=Chain,
                    roots:=Roots0
                   }=_Header,
          hash:=HdrHash,
          sign:=Sigs
        }=Blk, Opts) ->
  CheckHdr=lists:member(hdronly, Opts),

  Roots=lists:map(
    fun
      (Root) when CheckHdr ->
        Root;
      ({balroot, Hash}) ->
        Bals=maps:get(bals, Blk, #{}),
        BalsBin=bals2bin(Bals),
        BalsMT=gb_merkle_trees:from_list(BalsBin),
        NewHash=gb_merkle_trees:root_hash(BalsMT),
        if (NewHash =/= Hash) ->
             io:format("bal root mismatch~n"),
             ?LOG_NOTICE("bal root mismatch");
          true -> ok
        end,
        %io:format("BR1 ~p~n",[Hash]),
        %io:format("BR2 ~p~n",[NewHash]),
        {balroot, NewHash};
      ({setroot, Hash}) ->
        Settings=maps:get(settings, Blk, []),
        BSettings=binarize_settings(Settings),
        SettingsMT=gb_merkle_trees:from_list(BSettings),
        NewHash=gb_merkle_trees:root_hash(SettingsMT),
        if (NewHash =/= Hash) ->
             io:format("set root mismatch~n"),
             ?LOG_NOTICE("set root mismatch");
           true -> ok
        end,
        {setroot, NewHash};
      ({etxroot, Hash}) ->
        Txs=maps:get(etxs, Blk, []),
        BTxs=binarizetx(Txs),
        TxMT=gb_merkle_trees:from_list(BTxs),
        NewHash=gb_merkle_trees:root_hash(TxMT),
        if (NewHash =/= Hash) ->
             io:format("etxs root mismatch~n"),
             ?LOG_NOTICE("etxs root mismatch");
          true -> ok
        end,
        {etxroot, NewHash};
      ({txroot, Hash}) ->
        Txs=maps:get(txs, Blk, []),
        BTxs=binarizetx(Txs),
        TxMT=gb_merkle_trees:from_list(BTxs),
        NewHash=gb_merkle_trees:root_hash(TxMT),
        if (NewHash =/= Hash) ->
             io:format("txs root mismatch~n"),
             ?LOG_NOTICE("txs root mismatch");
          true -> ok
        end,
        {txroot, NewHash};
      ({failed, Hash}) ->
        Fail=maps:get(failed, Blk, []),
        NewHash=if Fail==[] ->
                      undefined;
                    true ->
                     FailMT=gb_merkle_trees:from_list(binarizefail(Fail)),
                     gb_merkle_trees:root_hash(FailMT)
                 end,
        if (NewHash =/= Hash) ->
             io:format("failed root mismatch~n"),
             ?LOG_NOTICE("failed root mismatch");
           true -> ok
        end,
        {failed, NewHash};
      ({ledger_hash, Hash}) ->
        {ledger_hash, Hash};
      ({tmp, IsTmp}) ->
        {tmp, IsTmp};
      ({mean_time, IsTmp}) ->
        {mean_time, IsTmp};
      ({entropy, IsTmp}) ->
        {entropy, IsTmp};
      ({settings_hash, SH}) ->
        {settings_hash, SH};
      ({<<"settings_hash">>, SH}) ->
        {settings_hash, SH};
      ({<<"log_hash">>, SH}) ->
        {log_hash, SH};
      ({Key, Value}) ->
        ?LOG_INFO("Unknown root ~p",[Key]),
        {Key, Value}
    end, Roots0),

  {BHeader, #{roots:=_NewRoots}}=build_header2(Roots, Parent, H, Chain),
  %io:format("HI ~p~n", [Roots0]),
  %io:format("vHI ~p~n", [_NewRoots]),

  Hash=crypto:hash(sha256, BHeader),
  %io:format("H1 ~s ~nH2 ~s~n~n", [bin2hex:dbin2hex(Hash),
  %                             bin2hex:dbin2hex(HdrHash)]),
  if Hash =/= HdrHash ->
       ?LOG_NOTICE("Block hash mismatch"),
       false;
     true ->
       case lists:keyfind(checksig,1,Opts) of
         false ->
           {true, bsig:checksig(Hash, Sigs)};
         {checksig, CheckFun} ->
           {true, bsig:checksig(Hash, Sigs, CheckFun)}
       end
  end;

verify(#{ header:=#{parent:=Parent, %blkv1
                    height:=H
                   }=Header,
          hash:=HdrHash,
          sign:=Sigs
        }=Blk, Opts) ->
  CheckHdr=lists:member(hdronly, Opts),

  HLedgerHash=maps:get(ledger_hash, Header, undefined),

  TxRoot=if CheckHdr ->
            maps:get(txroot, Header, undefined);
          true ->
         gb_merkle_trees:root_hash(
           gb_merkle_trees:from_list(
              binarizetx(
                maps:get(txs, Blk, []))
             )
          )
       end,
  BalsRoot=if CheckHdr ->
              maps:get(balroot, Header, undefined);
            true ->
              gb_merkle_trees:root_hash(
                gb_merkle_trees:from_list(
                  bals2bin(
                    maps:get(bals, Blk, #{})
                   )
                 )
               )
         end,
  SetRoot=if CheckHdr ->
                  maps:get(setroot, Header, undefined);
                true ->
                  gb_merkle_trees:root_hash(
                    gb_merkle_trees:from_list(
                      binarize_settings(
                        maps:get(settings, Blk, [])
                       )
                     )
                   )
             end,

  HeaderItems=[{txroot, TxRoot},
               {balroot, BalsRoot},
               {ledger_hash, HLedgerHash},
               {setroot, SetRoot}|
               case maps:is_key(chain, Header) of
                 false -> [];
                 true ->
                   [{chain, maps:get(chain, Header)}]
               end],

  {BHeader, _Hdr}=build_header(HeaderItems, Parent, H),

  Hash=crypto:hash(sha256, BHeader),
  %io:format("H1 ~s ~nH2 ~s~n~n", [bin2hex:dbin2hex(Hash),
  %                             bin2hex:dbin2hex(HdrHash)]),
  if Hash =/= HdrHash ->
       HSetRoot=maps:get(setroot, Header, undefined),
       HTxRoot=maps:get(txroot, Header, undefined),
       HBalsRoot=maps:get(balroot, Header, undefined),

       if TxRoot =/= HTxRoot ->
            ?LOG_NOTICE("TX root mismatch ~s vs ~s",
                         [
                          bin2hex:dbin2hex(TxRoot),
                          bin2hex:dbin2hex(HTxRoot)
                         ]);
          SetRoot =/= HSetRoot ->
            ?LOG_NOTICE("Set root mismatch ~s vs ~s",
                         [
                          bin2hex:dbin2hex(SetRoot),
                          bin2hex:dbin2hex(HSetRoot)
                         ]);
          BalsRoot =/= HBalsRoot ->
            ?LOG_NOTICE("Bals root mismatch ~s vs ~s",
                         [
                          bin2hex:dbin2hex(BalsRoot),
                          bin2hex:dbin2hex(HBalsRoot)
                         ]);
          true ->
            ?LOG_NOTICE("Something mismatch ~p ~p",[Header,HeaderItems])
       end,
       false;
     true ->
       case lists:keyfind(checksig,1,Opts) of
         false ->
           {true, bsig:checksig(Hash, Sigs)};
         {checksig, CheckFun} ->
           {true, bsig:checksig(Hash, Sigs, CheckFun)}
       end
  end.




verify(#{ header:=#{roots:=_}}=Block) ->
  verify(Block, []);

verify(#{ header:=#{parent:=_,
                    height:=_
                   },
          hash:=_,
          sign:=_
        }=Block) ->
  verify(Block, []).



binarize_settings([]) -> [];
binarize_settings([{TxID, Patch}|Rest]) ->
  [{TxID, pack_patch(Patch)}|binarize_settings(Rest)].

pack_patch(#{ patch:=P }) ->
  tx:pack(tx:construct_tx(#{patches=>P, kind=>patch, ver=>2}));
pack_patch(#{ kind:=patch, ver:=2, patches:=_, body:=_ }=Patch) ->
  tx:pack(Patch);
pack_patch(#{ kind:=patch, ver:=2, patches:=_ }=Patch) ->
  tx:pack(tx:construct_tx(Patch)).

mkblock2(#{ txs:=Txs, parent:=Parent,
            height:=H, bals:=Bals0,
            settings:=Settings,
            mychain:=Chain
          }=Req) ->
  TempID=case maps:get(temporary, Req, false) of
           X when is_integer(X) -> X;
           _ -> false
         end,
  Bals=if TempID==false -> Bals0;
          true -> #{} %avoid calculating bals_root on temporary block
       end,
  LH=maps:get(ledger_hash, Req, undefined),

  ETxsl=lists:keysort(1, lists:usort(maps:get(etxs, Req, []))),

  ETxRoot=case ETxsl of
            [] ->
              undefined;
            _ ->
              BETxs=binarizetx(ETxsl),
              ETxMT=gb_merkle_trees:from_list(BETxs),
              gb_merkle_trees:root_hash(ETxMT)
          end,

  Txsl=lists:keysort(1, lists:usort(Txs)),
  BTxs=binarizetx(Txsl),
  TxMT=gb_merkle_trees:from_list(BTxs),
  TxRoot=gb_merkle_trees:root_hash(TxMT),

  BalsBin=bals2bin(Bals),
  BalsMT=gb_merkle_trees:from_list(BalsBin),
  BalsRoot=gb_merkle_trees:root_hash(BalsMT),

  BSettings=binarize_settings(Settings),
  SettingsMT=gb_merkle_trees:from_list(BSettings),
  SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),

  ExtraRoots=case maps:is_key(extra_roots, Req) of
               true ->
                 maps:get(extra_roots, Req);
               false ->
                 []
             end,

  ?LOG_INFO("ER ~p",[ExtraRoots]),
  TempRoot=if TempID == false -> ExtraRoots;
              true -> [{tmp, <<TempID:64/big>>}|ExtraRoots]
           end,

  Failed=prepare_fail(maps:get(failed, Req,[])),
  %io:format("Fail1 ~p~n",[Failed]),
  FTxs=binarizefail(Failed),
  %io:format("Fail2 ~p~n",[FTxs]),
  FailRoot=if FTxs==[] ->
                TempRoot;
              true ->
                FailMT=gb_merkle_trees:from_list(FTxs),
                [{failed,gb_merkle_trees:root_hash(FailMT)}|TempRoot]
           end,

  HeaderItems0=[{txroot, TxRoot},
                {etxroot, ETxRoot},
                {balroot, BalsRoot},
                {ledger_hash, LH},
                {setroot, SettingsRoot}
                |FailRoot],
  HeaderItems =
    case maps:get(settings_hash, Req, unknown) of
      unknown ->
        HeaderItems0;
      SettingsHash ->
        [{settings_hash, SettingsHash} | HeaderItems0]
    end,
  {BHeader, Hdr}=build_header2(HeaderItems, Parent, H, Chain),

  Block=#{header=>Hdr,
          hash=>crypto:hash(sha256, BHeader),
          txs=>Txsl,
          bals=>Bals,
          settings=>Settings,
          sign=>[] },
  Block0=if TempID == false -> Block;
            true ->
              Block#{temporary=>TempID}
         end,
  Block1=case maps:get(tx_proof, Req, []) of
           [] ->
             Block0;
           List ->
             Proof=lists:map(
                     fun(TxID) ->
                         {TxID, gb_merkle_trees:merkle_proof (TxID, TxMT)}
                     end, List),
             maps:put(tx_proof, Proof, Block0)
         end,
  Block2=case maps:get(inbound_blocks, Req, []) of
           [] ->
             Block1;
           List2 ->
             maps:put(inbound_blocks,
                      lists:map(
                        fun({InBlId, InBlk}) ->
                            {InBlId, maps:remove(txs, InBlk)}
                        end, List2),
                      Block1)
         end,
  Block3=case maps:get(extdata, Req, []) of
    [] ->
      Block2;
    List3 ->
      maps:put(extdata, List3, Block2)
  end,
  Block4=maps:put(failed, Failed, Block3),
  maps:put(etxs,ETxsl, Block4).


%mkblock(#{ txs:=Txs, parent:=Parent, height:=H, bals:=Bals, settings:=Settings }=Req) ->
%  LH=maps:get(ledger_hash, Req, undefined),
%  Txsl=lists:keysort(1, lists:usort(Txs)),
%  BTxs=binarizetx(Txsl),
%  TxMT=gb_merkle_trees:from_list(BTxs),
%  BalsBin=bals2bin(Bals),
%  BalsMT=gb_merkle_trees:from_list(BalsBin),
%  BSettings=binarize_settings(Settings),
%  SettingsMT=gb_merkle_trees:from_list(BSettings),
%
%  TxRoot=gb_merkle_trees:root_hash(TxMT),
%  BalsRoot=gb_merkle_trees:root_hash(BalsMT),
%  SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),
%
%  HeaderItems=[{txroot, TxRoot},
%               {balroot, BalsRoot},
%               {ledger_hash, LH},
%               {setroot, SettingsRoot}|
%               case maps:is_key(mychain, Req) of
%                 false -> [];
%                 true ->
%                   [{chain, maps:get(mychain, Req)}]
%               end],
%  {BHeader, Hdr}=build_header(HeaderItems, Parent, H),
%  %?LOG_INFO("HI ~p", [Hdr]),
%
%  Block=#{header=>Hdr,
%          hash=>crypto:hash(sha256, BHeader),
%          txs=>Txsl,
%          bals=>Bals,
%          settings=>Settings,
%          sign=>[] },
%  Block1=case maps:get(tx_proof, Req, []) of
%           [] ->
%             Block;
%           List ->
%             Proof=lists:map(
%                     fun(TxID) ->
%                         {TxID, gb_merkle_trees:merkle_proof (TxID, TxMT)}
%                     end, List),
%             maps:put(tx_proof, Proof, Block)
%         end,
%  Block2=case maps:get(inbound_blocks, Req, []) of
%           [] ->
%             Block1;
%           List2 ->
%             maps:put(inbound_blocks,
%                      lists:map(
%                        fun({InBlId, InBlk}) ->
%                            {InBlId, maps:remove(txs, InBlk)}
%                        end, List2),
%                      Block1)
%         end,
%  case maps:get(extdata, Req, []) of
%    [] ->
%      Block2;
%    List3 ->
%      maps:put(extdata, List3, Block2)
%  end;
%
%mkblock(Blk) ->
%  case maps:is_key(settings, Blk) of
%    false ->
%      mkblock(maps:put(settings, [], Blk));
%    true ->
%      io:format("s ~p~n", [maps:keys(Blk)]),
%      throw(badmatch)
%  end.

outward_mk(Block) ->
  outward(maps:get(outbound, Block, []), Block, #{}).

outward_mk(TxS, Block) ->
  outward(TxS, Block, #{}).

outward([], Block, Acc) ->
  maps:map(
    fun(Chain, {Tx, Tp}) ->
        Settings=maps:get(settings, Block),
        MiniBlock=maps:with([hash, header, sign, settings_proof], Block),
        Patch=proplists:lookup(<<"outch:",(integer_to_binary(Chain))/binary>>, Settings),
        NewSet=case Patch of
                 {_,_} -> [Patch];
                 none -> []
               end,
        MiniBlock#{ txs=>Tx, tx_proof=>Tp, settings=>NewSet }
    end,
    Acc);

outward([{TxID, Chain}|Rest], #{txs:=Txs, tx_proof:=Proofs}=Block, Acc) ->
  {ChainTx, ChainTp}=maps:get(Chain, Acc, {[], []}),
  Tx=proplists:get_value(TxID, Txs),
  Proof=proplists:get_value(TxID, Proofs),
  outward(Rest,
          Block,
          maps:put(Chain,
                   { [{TxID, Tx}|ChainTx], [{TxID, Proof}|ChainTp] } , Acc)
         ).

outward_chain(Block, Chain) ->
  outward_chain(
    maps:get(outbound, Block, []),
    Block,
    Chain,
    {[],[]}).


outward_chain([], _Block, _Chain, {[], _}) ->
  none;

outward_chain([], Block, Chain, {Tx, Tp}) ->
  Settings=maps:get(settings, Block),
  CS=outward_ptrs(Settings, Chain),
  MiniBlock=maps:with([hash, header, sign, settings_proof], Block),
  Patch=proplists:lookup(<<"outch:",(integer_to_binary(Chain))/binary>>, Settings),
  NewSet=case Patch of
           {_,_} -> [Patch];
           none -> []
         end,
  MB=MiniBlock#{ txs=>Tx, tx_proof=>Tp, settings=>NewSet },
  case CS of
    #{<<"pre_height">>:=PH,
      <<"pre_parent">>:=PP} ->
      MB#{
        extdata => [
                    {pre_parent, PP},
                    {pre_height, PH}
                   ]
       };
    #{<<"parent">>:=_} ->
      MB#{
        extdata => []
       }
  end;

outward_chain([{TxID, Chain}|Rest],
              #{txs:=Txs, tx_proof:=Proofs}=Block,
              ReqChain, {ChainTx, ChainTp}) when Chain==ReqChain ->
  Tx=proplists:get_value(TxID, Txs),
  Proof=proplists:get_value(TxID, Proofs),
  outward_chain(Rest,
                Block,
                ReqChain,
                { [{TxID, Tx}|ChainTx], [{TxID, Proof}|ChainTp] }
               );

outward_chain([{_, _}|Rest], Block, ReqChain, Acc) ->
  outward_chain(Rest, Block, ReqChain, Acc).

outward_ptrs(Settings, Chain) ->
  Patch=proplists:get_value(<<"outch:",(integer_to_binary(Chain))/binary>>, Settings),
  if Patch==undefined ->
       error;
     true ->
       S1=settings:patch(Patch,#{}),
       lists:foldl( fun maps:get/2,
                    S1,
                    [<<"current">>,
                     <<"outward">>,
                     <<"ch:",(integer_to_binary(Chain))/binary>>]
                  )
  end.

to_binary(L) when is_atom(L) -> atom_to_binary(L,utf8);
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(L) when is_binary(L) -> L.

prepare_fail(Fail) ->
  lists:map(
    fun({TxID, A}) when is_atom(A) ->
        R=#{<<"reason">>=>atom_to_binary(A,utf8)},
        {TxID, R};
       ({TxID, T}) when is_list(T) ->
        {TxID, T};
       ({TxID, T}) when is_tuple(T) ->
        [E|L]=tuple_to_list(T),
        R=#{ <<"reason">>=> to_binary(E), <<"ext">>=>L },
        {TxID, R};
       ({TxID, T}) when is_binary(T) ->
        {TxID, T};
       ({TxID, #{}=Tx}) ->
        {TxID, Tx}
    end, Fail).

binarizefail(Fail) ->
  lists:map(
    fun({TxID, T}) when is_binary(T) ->
        {TxID, T};
       ({TxID, T}) when is_list(T) ->
        {TxID, list_to_binary(T)};
       ({TxID, #{ver:=2}=Tx}) ->
        BTx=tx:pack(Tx,[withext]),
        {TxID, BTx};
       ({TxID, #{<<"reason">>:=_}=Any}) ->
        %io:format("Binarize ~p~n",[Any]),
        BTx=msgpack:pack(Any,[{spec,new},{pack_str,from_list}]),
        {TxID, BTx}
    end, Fail).


binarizetx([]) ->
  [];

binarizetx([{TxID, Tx}|Rest]) ->
  BTx=tx:pack(Tx,[withext]),
  %TxIDLen=size(TxID),
  %TxLen=size(BTx),
  %<<TxIDLen:8/integer, TxLen:16/integer, TxID/binary, BTx/binary, (binarizetx(Rest))/binary>>.
  [{TxID, BTx}|binarizetx(Rest)].

extract(<<>>) ->
  [];

extract(<<TxIDLen:8/integer, TxLen:16/integer, Body/binary>>) ->
  <<TxID:TxIDLen/binary, Tx:TxLen/binary, Rest/binary>> = Body,
  [{TxID, tx:unpack(Tx,[trusted])}|extract(Rest)].


bals2bin(NewBal) ->
  L=lists:keysort(1, maps:to_list(NewBal)),
  lists:foldl(
    fun({Addr, %generic bal
         #{amount:=_}=Bal
        } , Acc) ->
        %TODO: check with integer addresses
        [{Addr, mbal:pack(Bal)}|Acc];
       ({Addr, %port
         #{chain:=NewChain}
        }, Acc) ->
        [{<<Addr/binary>>,
          <<"pout", NewChain:64/big>>}|Acc];
       (Any, _) ->
        throw({"Bad bal", Any})
    end, [], L).

blkid(<<X:8/binary, _/binary>>) ->
  bin2hex:dbin2hex(X).


sign(Blk, ED, PrivKey) when is_map(Blk) ->
  Hash=maps:get(hash, Blk),
  %There is needs for tests, but breakes packing.
  %TODO: Fix
  %Sign=bsig:unpacksig(bsig:signhash(Hash, ED, PrivKey)),
  Sign=bsig:signhash(Hash, ED, PrivKey),
  Blk#{
    sign=>[Sign|maps:get(sign, Blk, [])]
   }.

sign(Blk, PrivKey) when is_map(Blk) ->
  Timestamp=os:system_time(millisecond),
  ED=[{timestamp, Timestamp}],
  sign(Blk, ED, PrivKey).

build_header2(HeaderItems, Parent, H, ChainNo) ->
  {Bin,Roots}=lists:foldl(
          fun({_, undefined}, {ABHhr, AHdr}) ->
              {ABHhr, AHdr};
             ({N, Root}, {ABHhr, AHdr}) ->
              { <<ABHhr/binary, Root/binary >>, [{N, Root}| AHdr]
              }
          end,
          {
           << ChainNo:64/big,
              H:64/integer, %8
              Parent/binary
           >>,
           []
          },
          HeaderItems
         ),
  {Bin,
   #{ roots=>lists:reverse(Roots),
      parent=>Parent,
      height=>H,
      chain=>ChainNo,
      ver=>2 }
  }.


build_header(HeaderItems, Parent, H) ->
  lists:foldl(
    fun({_, undefined}, {ABHhr, AHdr}) ->
        {ABHhr, AHdr};
       ({chain, ChainNo}, {ABHhr, AHdr}) ->
        {
         <<ABHhr/binary, ChainNo:64/big >>,
         maps:put(chain, ChainNo, AHdr)
        };
       ({N, Root}, {ABHhr, AHdr}) ->
        {
         <<ABHhr/binary,
           Root/binary
         >>,
         maps:put(N, Root, AHdr)
        }
    end,
    {
     <<H:64/integer, %8
       Parent/binary
     >>,
     #{ parent=>Parent, height=>H }
    },
    HeaderItems
   ).

unpacksig(Block) ->
  maps:map(
    fun(sign, Sigs) ->
        lists:map(
          fun(Sig) ->
              bsig:unpacksig(Sig)
          end, Sigs);
       (_, Val) -> Val
    end, Block).

packsig(Block) ->
  maps:map(
    fun(sign, Sigs) ->
        lists:map(
          fun(Sig) ->
              bsig:packsig(Sig)
          end, Sigs);
       (_, Val) -> Val
    end, Block).

split_packet(Data) ->
  Size = ?SPLIT_PACKET_SIZE,
  Length = erlang:ceil(byte_size(Data) / Size),
  split_packet(Size, Data, 1, Length).
split_packet(Size, Data) ->
  Length = erlang:ceil(byte_size(Data) / Size),
  split_packet(Size, Data, 1, Length).
split_packet(Size, Data, Seq, Length) when Size > 0 ->
  case Data of
    <<Packet:Size/binary, Rest/binary>> ->
      [<<Seq:32, Length:32, Packet/binary>> | split_packet(Size, Rest, Seq + 1, Length)];
    <<>> ->
      [];
    _ ->
      [<<Seq:32, Length:32, Data/binary>>]
  end.

glue_packet(List) ->
  SortedList = lists:sort(
                 fun(<<N1:32, _/binary>>, <<N2:32, _/binary>>) ->
                     N1 =< N2
                 end, List),
  {_, _, Valid} = lists:foldl(
                    fun(<<Seq:32, Length:32, _/binary>>,
                        {PrevSeq, PrevLength, Acc}) ->
                        {Seq, Length, Acc and
                         (PrevSeq + 1 =:= Seq) and
                         (PrevLength =:= Length)}
                    end,
                    {0, length(SortedList), true},
                    SortedList),
  if Valid ->
       list_to_binary(
         lists:map(
           fun(<<_:32, _:32, Val/binary>>) ->
               Val
           end,
           SortedList)
        );
     true ->
       ?LOG_ERROR("Received block is broken ~p", [SortedList]),
       throw(broken)
  end.

