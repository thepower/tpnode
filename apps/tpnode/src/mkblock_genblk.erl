-module(mkblock_genblk).

-export([run_generate/5, spawn_generate/5]).

spawn_generate(MySet, PreTXM, PreSig, MT, Ent) ->
  PID=spawn(?MODULE,run_generate,[MySet, PreTXM, PreSig, MT, Ent]),
  %monitor(PID,process),
  PID.

run_generate(
  #{mychain:=MyChain, nodename:=NodeName}=MySet,
  PreTXM,
  PreSig,
  MT,
  Ent) ->
  BestHeiHash=case lists:sort(maps:keys(PreTXM)) of
                [undefined] -> undefined;
                [undefined,H0|_] -> H0;
                [H0|_] -> H0;
                [] -> undefined
              end,
  logger:info("pick txs parent block ~p",[BestHeiHash]),
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
  logger:debug("Got blk from our blockchain ~p",[B]),

  {PHeight, PHash, PHeiHash}=mkblock:hei_and_has(B),
  PTmp=maps:get(temporary,B,false),

  logger:info("-------[MAKE BLOCK h=~w tmp=~p]-------",[PHeight,PTmp]),
  logger:info("Pre ~p",[PreTXL0]),

  PreNodes=try
             BK=maps:fold(
                  fun(_, {BH, _}, Acc) when BH =/= PHash ->
                      Acc;
                     (Node1, {_BH, Nodes2}, Acc) ->
                      [{Node1, Nodes2}|Acc]
                  end, [], PreSig),
             lists:sort(bron_kerbosch:max_clique(BK))
           catch
             Ec:Ee:S ->
               %S=erlang:get_stacktrace(),
               utils:print_error("Can't calc xsig", Ec, Ee, S),
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
    logger:debug("MB pre nodes ~p", [PreNodes]),

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

  MT1=[ 1000*(TT div 1000) || TT <- MT ],
  MeanTime=trunc(median(lists:sort( MT1 ))),
  logger:info("MT0 ~p",[MT]),
  logger:info("MT1 ~p",[MT1]),
  logger:info("MT ~p",[MeanTime]),
  Entropy=if Ent == [] ->
               <<>>;
             true ->
               case chainsettings:by_path([<<"current">>,<<"gatherentropy">>]) of
                 true ->
                   crypto:hash(sha256,[PHash,<<MeanTime:64/big>>|lists:usort(Ent)]);
                 1 ->
                   crypto:hash(sha256,[PHash,<<MeanTime:64/big>>|lists:usort(Ent)]);
                 _ ->
                   <<>>
               end
          end,
    case application:get_env(tpnode,mkblock_debug) of
      {ok, true} ->
        stout:log(mkblock_debug,
                  [
                   {node_name,NodeName},
                   {entropys, Ent},
                   {mean_times, MT}
                  ]);
      _ ->
        ok
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
                (entropy) -> Entropy;
                (mean_time) -> MeanTime;
                 ({get_block, Back}) when 32>=Back ->
                 FindBlock(last, Back)
             end,
    AddrFun=fun({storage,Addr,Key}) ->
                case mledger:get(Addr) of
                  #{state:=State} -> maps:get(Key,State,<<>>);
                  #{} -> <<>>;
                  undefined -> <<>>
                end;
               ({Addr, _Cur}) ->
                case mledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  undefined -> mbal:new()
                end;
               (Addr) ->
                case mledger:get(Addr) of
                  #{amount:=_}=Bal -> maps:without([changes],Bal);
                  undefined -> mbal:new()
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

    case application:get_env(tpnode, dumpmkblock) of
      {ok, true} ->
        file:write_file("tmp/mkblk_" ++
                        integer_to_list(PHeight) ++ "_" ++
                        binary_to_list(nodekey:node_id())++ "_" ++
                        integer_to_list(os:system_time())++ "_" ++
                        if is_integer(Temporary) ->
                             integer_to_list(Temporary);
                           true -> ""
                        end,
                        io_lib:format("~p.~n~p.~n~p.~n~p.~n",
                                      [PreTXL,
                                       {PHeight, PHash},
                                       [ {<<"prevnodes">>, PreNodes} ],
                                       [
                                        {temporary, Temporary},
                                        {entropy, Entropy},
                                        {mean_time, MeanTime}
                                       ]
                                      ])
                       );
      _ -> ok
    end,

    GB=generate_block:generate_block(PreTXL,
                                     {PHeight, PHash},
                                     PropsFun,
                                     AddrFun,
                                     [ {<<"prevnodes">>, PreNodes} ],
                                     [
                                      {temporary, Temporary},
                                      {entropy, Entropy},
                                      {mean_time, MeanTime}
                                     ]
                                    ),
    #{block:=Block, failed:=Failed, log:=Log}=GB,
    logger:info("NewS block ~p",[maps:get(bals,Block)]),
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
        logger:notice("What does mkblock_debug=~p mean?",[Any])
    end,
    Timestamp=os:system_time(millisecond),
    ED=[
        {timestamp, Timestamp},
        {createduration, T2-T1}
       ],
    SignedBlock=blocksign(Block, ED),
    #{header:=#{height:=NewH}}=Block,
    %cast whole block to my local blockvote
    stout:log(mkblock_done,
              [
               {node_name,NodeName},
               {height, PHeight},
               {block_hdr, maps:with([hash,header,sign,temporary], SignedBlock)}
              ]),

    gen_server:cast(blockvote, {new_block, SignedBlock, self(), #{log=>Log}}),

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
    logger:debug("MB My sign ~p",
                [
                 maps:get(sign, SignedBlock)
                ]),
    HBlk=msgpack:pack(
           #{null=><<"blockvote">>,
             <<"n">>=>node(),
             <<"hash">>=>maps:get(hash, SignedBlock),
             <<"sign">>=>maps:get(sign, SignedBlock),
             <<"chain">>=>MyChain
            }
          ),
    tpic2:cast(<<"blockvote">>, HBlk),

    done
  catch throw:empty ->
          logger:info("Skip empty block"),
          skip;
        throw:Other ->
          logger:info("Skip ~p",[Other]),
          error
  end.

blocksign(Blk, ED) when is_map(Blk) ->
  case nodekey:get_privs() of
    [K0] ->
      block:sign(Blk, ED, K0);
    [K0|Extra] ->
      %Ability to sign mutiple times for smart developers of smarcontracts only!!!!!
      %NEVER USE ON NETWORK CONNECTED NODE!!!
      block:sign(
        lists:foldl(
          fun(ExtraKey,Acc) ->
              ED2=[ {timestamp, proplists:get_value(timestamp, ED)+
                     trunc(-100+rand:uniform()*200)},
                    {createduration, proplists:get_value(createduration, ED)+
                     trunc(-250000+rand:uniform()*500000)}
                  ],
              block:sign(Acc, ED2, ExtraKey)
          end, Blk, Extra), ED, K0)
  end.

%blocksign(Blk, ED) when is_map(Blk) ->
%  PrivKey=nodekey:get_priv(),
%  block:sign(Blk, ED, PrivKey).

median([]) -> 0;

median([E]) -> E;

median(List) ->
  LL = length(List),
  DropL = (LL div 2) - 1,
  {_, [M1, M2 | _]} = lists:split(DropL, List),
  case LL rem 2 of
    0 -> %even elements
      (M1 + M2) / 2;
    1 -> %odd
      M2
  end.

