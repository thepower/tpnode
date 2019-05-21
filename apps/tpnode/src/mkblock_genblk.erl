-module(mkblock_genblk).

-export([run_generate/3, spawn_generate/3]).

spawn_generate(MySet, PreTXM, PreSig) ->
  PID=spawn(?MODULE,run_generate,[MySet, PreTXM, PreSig]),
  %monitor(PID,process),
  PID.

run_generate(
  #{mychain:=MyChain, nodename:=NodeName}=MySet,
  PreTXM,
  PreSig ) ->
  BestHeiHash=case lists:sort(maps:keys(PreTXM)) of
                [undefined] -> undefined;
                [undefined,H0|_] -> H0;
                [H0|_] -> H0;
                [] -> undefined
              end,
  lager:info("pick txs parent block ~p",[BestHeiHash]),
  PreTXL0=maps:get(BestHeiHash, PreTXM, []),
  PreTXL1=lists:foldl(
            fun({TxID, TXB}, Acc) ->
                case maps:is_key(TxID, Acc) of
                  true ->
                    TXB1=tx:mergesig(TXB,
                                     maps:get(TxID, Acc)),
                    {ok, Tx1} = tx:verify(TXB1, [ {maxsize, txpool:get_max_tx_size()} ]),
                    maps:put(TxID, Tx1, Acc);
                  false ->
                    maps:put(TxID, TXB, Acc)
                end
            end, #{}, PreTXL0),
  PreTXL=lists:keysort(1, maps:to_list(PreTXL1)),

  stout:log(mkblock_process, [ {node, nodekey:node_name()} ]),

  AE=maps:get(ae, MySet, 0),
  B=blockchain:last_meta(),
  lager:info("Got blk from our blockchain ~p",[B]),

  {PHeight, PHash, PHeiHash}=mkblock:hei_and_has(B),
  PTmp=maps:get(temporary,B,false),

  lager:info("-------[MAKE BLOCK h=~w tmp=~p]-------",[PHeight,PTmp]),
  lager:info("Pre ~p",[PreTXL0]),

  PreNodes=try
             BK=maps:fold(
                  fun(_, {BH, _}, Acc) when BH =/= PHash ->
                      Acc;
                     (Node1, {_BH, Nodes2}, Acc) ->
                      [{Node1, Nodes2}|Acc]
                  end, [], PreSig),
             lists:sort(bron_kerbosch:max_clique(BK))
           catch
             Ec:Ee ->
               utils:print_error("Can't calc xsig", Ec, Ee, erlang:get_stacktrace()),
               []
           end,

  try
    if BestHeiHash == undefined -> ok;
       BestHeiHash == PHeiHash -> ok;
       true ->
         gen_server:cast(chainkeeper, are_we_synced),
         throw({'unsync',BestHeiHash,PHeiHash})
    end,
    T1=erlang:system_time(),
    lager:debug("MB pre nodes ~p", [PreNodes]),

    FindBlock=fun FB(H, N) ->
                  case blockchain:rel(H, self) of
                    undefined ->
                      undefined;
                    #{header:=#{parent:=P}}=Blk ->
                      if N==0 ->
                           block:minify(Blk);
                         true ->
                           FB(P, N-1)
                      end
                  end
              end,

    PropsFun=fun(mychain) ->
                 MyChain;
                (settings) ->
                 chainsettings:by_path([]);
                ({valid_timestamp, TS}) ->
                 abs(os:system_time(millisecond)-TS)<3600000;
                ({endless, From, Cur}) ->
                 EndlessPath=[<<"current">>, <<"endless">>, From, Cur],
                 chainsettings:by_path(EndlessPath)==true;
                ({get_block, Back}) when 32>=Back ->
                 FindBlock(last, Back)
             end,
    AddrFun=fun({Addr, _Cur}) ->
                case ledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  not_found -> bal:new()
                end;
               (Addr) ->
                case ledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  not_found -> bal:new()
                end
            end,

    NoTMP=maps:get(notmp, MySet, 0),

    Temporary = if AE==0 andalso PreTXL==[] ->
                     if(NoTMP=/=0) -> throw(empty);
                       true ->
                         if is_integer(PTmp) ->
                              PTmp+1;
                            true ->
                              1
                         end
                     end;
                   true ->
                     false
                end,
    GB=generate_block:generate_block(PreTXL,
                                     {PHeight, PHash},
                                     PropsFun,
                                     AddrFun,
                                     [ {<<"prevnodes">>, PreNodes} ],
                                     [ {temporary, Temporary} ]
                                    ),
    #{block:=Block, failed:=Failed, emit:=EmitTXs}=GB,
    T2=erlang:system_time(),

    case application:get_env(tpnode,mkblock_debug) of
      undefined ->
        ok;
      {ok, true} ->
        stout:log(mkblock_debug,
                  [
                   {node_name,NodeName},
                   {height, PHeight},
                   {phash, PHash},
                   {pretxl, PreTXL},
                   {fail, Failed},
                   {block, Block},
                   {temporary, Temporary}
                  ]);
      Any ->
        lager:notice("What does mkblock_debug=~p means?",[Any])
    end,
    Timestamp=os:system_time(millisecond),
    ED=[
        {timestamp, Timestamp},
        {createduration, T2-T1}
       ],
    SignedBlock=sign(Block, ED),
    #{header:=#{height:=NewH}}=Block,
    %cast whole block to my local blockvote
    stout:log(mkblock_done,
              [
               {node_name,NodeName},
               {height, PHeight},
               {block_hdr, maps:with([hash,header,sign,temporary], SignedBlock)}
              ]),

    gen_server:cast(blockvote, {new_block, SignedBlock, self()}),

    case application:get_env(tpnode, dumpblocks) of
      {ok, true} ->
        file:write_file("tmp/mkblk_" ++
                        integer_to_list(NewH) ++ "_" ++
                        binary_to_list(nodekey:node_id()),
                        io_lib:format("~p.~n", [SignedBlock])
                       );
      _ -> ok
    end,
    %Block signature for each other
    lager:debug("MB My sign ~p emit ~p",
                [
                 maps:get(sign, SignedBlock),
                 length(EmitTXs)
                ]),
    HBlk=msgpack:pack(
           #{null=><<"blockvote">>,
             <<"n">>=>node(),
             <<"hash">>=>maps:get(hash, SignedBlock),
             <<"sign">>=>maps:get(sign, SignedBlock),
             <<"chain">>=>MyChain
            }
          ),
    tpic:cast(tpic, <<"blockvote">>, HBlk),
    if EmitTXs==[] -> ok;
       true ->
         Push=gen_server:call(txpool, {push_etx, EmitTXs}),
         stout:log(push_etx,
                   [
                    {node_name,NodeName},
                    {txs, EmitTXs},
                    {res, Push}
                   ]),
         lager:info("Inject TXs ~p", [Push])
    end,
    done
  catch throw:empty ->
          lager:info("Skip empty block"),
          skip;
        throw:Other ->
          lager:info("Skip ~p",[Other]),
          error
  end.

sign(Blk, ED) when is_map(Blk) ->
  PrivKey=nodekey:get_priv(),
  block:sign(Blk, ED, PrivKey).

