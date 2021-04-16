-module(blockchain_updater).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([new_block/1, new_sig/2]).
-export([apply_block_conf/2,
         apply_block_conf_meta/2,
         apply_ledger/2,
         backup/1, restore/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

new_block(Blk) ->
  gen_server:cast(blockchain_updater, {new_block, Blk, self()}).

new_sig(BlockHash, Sigs) ->
  gen_server:cast(blockchain_updater, {signature, BlockHash, Sigs}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  Table=ets:new(blockchain,[named_table,protected,bag,{read_concurrency,true}]),
  lager:info("Table created: ~p",[Table]),
  BTable=ets:new(lastblock,[named_table,protected,set,{read_concurrency,true}]),
  lager:info("Table created: ~p",[BTable]),
  NodeID=nodekey:node_id(),
  filelib:ensure_dir("db/"),
  {ok, LDB}=ldb:open("db/db_" ++ atom_to_list(node())),
  LastBlockHash=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),
  Restore=case os:getenv("TPNODE_RESTORE") of
            false ->
              case os:getenv("TPNODE_GENESIS") of
                false ->
                  default;
                Genesis_Path ->
                  {genesis, Genesis_Path}
              end;
            RestoreDir ->
              {backup, RestoreDir}
          end,
  LastBlock=case ldb:read_key(LDB,
                              <<"block:", LastBlockHash/binary>>,
                              undefined
                             ) of
              undefined ->
                LBLK=case Restore of
                  default -> genesis:genesis();
                  {genesis, Path} ->
                    lager:notice("Genesis from ~s",[Path]),
                    {ok, [Genesis]}=file:consult(Path),
                    Genesis;
                  {backup, Path} ->
                    P=Path++"/0.txt",
                    lager:notice("Restoring from ~s",[P]),
                    {ok, [Genesis]}=file:consult(P),
                    Genesis
                end,
                save_block(LDB, LBLK, true),
                LBLK;
              Block ->
                Block
            end,
  Conf=load_sets(LDB, LastBlock),
  lager:info("My last block hash ~s",
             [bin2hex:dbin2hex(LastBlockHash)]),
  lastblock2ets(BTable, LastBlock),
  Res=mychain(#{
        nodeid=>NodeID,
        ldb=>LDB,
        candidates=>#{},
        settings=>chainsettings:settings_to_ets(Conf),
        lastblock=>LastBlock,
        btable=>BTable
       }),
  case Restore of
    {backup, Path1} ->
      spawn(blockchain_updater, restore, [Path1]);
    _ ->
      erlang:send_after(6000, self(), runsync)
  end,
  notify_settings(),
  gen_server:cast(blockchain_reader,update),
  erlang:spawn(fun() ->
                   timer:sleep(200),
                   notify_settings()
               end),
  {ok, Res}.

handle_call(get_dbh, _From, #{ldb:=LDB}=State) ->
  {reply, {ok, LDB}, State};

handle_call(ready, _From, State) ->
    {reply, not maps:is_key(sync, State), State};

handle_call({backup, Path}, From, #{lastblock:=#{hash:=LH}}=State) ->
  erlang:send(self(), {backup, Path, From, LH, 0}),
  {noreply, State};

handle_call(last, _From, #{lastblock:=L}=State) ->
  {reply, maps:with([child, header, hash], L), State};

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(saveset, _From, #{settings:=Settings}=State) ->
  file:write_file("tmp/settings.dump",
                  io_lib:format("~p.~n", [Settings])),
  {reply, Settings, State};

handle_call(rollback, _From, #{
                        btable:=BTable,
                        settings:=Settings,
                        lastblock:=#{header:=#{parent:=Parent,height:=Hei}}=Last,
                        ldb:=LDB}=State) ->
  try
    case block_rel(LDB, Parent, self) of
      Error when is_atom(Error) ->
        {reply, {error, Error}, State};
      #{hash:=H}=Blk ->
        LH=block:ledger_hash(Blk),
        PreSets=case maps:get(settings, Last, []) of
                  [] ->
                    Settings;
                  _ ->
                    case ldb:read_key(LDB,
                                      <<"settings:", Parent/binary>>,
                                      undefined
                                     ) of
                      undefined ->
                        throw(no_pre_set);
                      Bin when is_binary(Bin) ->
                        binary_to_term(Bin)
                    end
                end,
        case mledger:rollback(Hei, LH) of
          {ok, LH} ->
            save_block(LDB, maps:remove(child,Blk), true),
            chainsettings:settings_to_ets(PreSets),
            lastblock2ets(BTable, Blk),
            NewState=maps:without(
                       [pre_settings,tmpblock],
                       State#{
                         lastblock=>Blk,
                         settings=>PreSets
                        }
                      ),
            {reply, {ok, H}, NewState};
          {error, Err} ->
            {reply, {ledger_error, Err}, State};
          Any ->
            {reply, {unknown_error, Any}, State}
        end
    end
  catch throw:no_pre_set ->
          {reply, {error, no_prev_state}, State}
  end;

handle_call({new_block, #{hash:=BlockHash,
                          header:=#{height:=Hei}=Header}=Blk, PID}=_Message,
            _From,
            #{candidates:=Candidates, ldb:=LDB0,
              settings:=Sets,
              btable:=BTable,
              lastblock:=#{header:=#{parent:=Parent}, hash:=LBlockHash}=LastBlock,
              mychain:=MyChain
             }=State) ->
  FromNode=if is_pid(PID) -> node(PID);
              is_tuple(PID) -> PID;
              true -> emulator
           end,
  lager:info("Arrived block from ~p Verify block with ~p",
             [FromNode, maps:keys(Blk)]),

  lager:info("New block (~p/~p) hash ~s (~s/~s)",
             [
              Hei,
              maps:get(height, maps:get(header, LastBlock)),
              blkid(BlockHash),
              blkid(Parent),
              blkid(LBlockHash)
             ]),
  try
    LDB=if is_pid(PID) -> LDB0;
           is_tuple(PID) -> LDB0;
           true -> ignore
        end,
    T0=erlang:system_time(),
    case block:verify(Blk) of
      false ->
        stout:log(got_new_block,
                  [
                   {hash, BlockHash},
                   {node, nodekey:node_name()},
                   {verify, false},
                   {height,maps:get(height, maps:get(header, Blk))}
                  ]),
        T1=erlang:system_time(),
        file:write_file("tmp/bad_block_" ++
                        integer_to_list(maps:get(height, Header)) ++ ".txt",
                        io_lib:format("~p.~n", [Blk])
                       ),
        lager:info("Got bad block from ~p New block ~w arrived ~s, verify (~.3f ms)",
                   [FromNode, Hei, blkid(BlockHash), (T1-T0)/1000000]),
        throw(ignore);
      {true, {Success, _}} ->
        LenSucc=length(Success),
        stout:log(got_new_block,
                  [
                   {hash, BlockHash},
                   {node, nodekey:node_name()},
                   {verify, LenSucc},
                   {height, maps:get(height, maps:get(header, Blk))}
                  ]),
        T1=erlang:system_time(),
        Txs=maps:get(txs, Blk, []),
        if LenSucc>0 ->
             lager:info("from ~p New block ~w arrived ~s, txs ~b, verify ~w sig (~.3f ms)",
                        [FromNode, maps:get(height, maps:get(header, Blk)),
                         blkid(BlockHash), length(Txs), length(Success), (T1-T0)/1000000]),
             ok;
           true ->
             lager:info("from ~p New block ~w arrived ~s, txs ~b, no sigs (~.3f ms)",
                        [FromNode, maps:get(height, maps:get(header, Blk)),
                         blkid(BlockHash), length(Txs), (T1-T0)/1000000]),
             throw(ingore)
        end,
        MBlk=case maps:get(BlockHash, Candidates, undefined) of
               undefined ->
                 Blk;
               #{sign:=BSig}=ExBlk ->
                 NewSigs=lists:usort(BSig ++ Success),
                 ExBlk#{
                   sign=>NewSigs
                  }
             end,
        SigLen=length(maps:get(sign, MBlk)),
        lager:debug("Signs ~p", [Success]),
        MinSig=getset(minsig,State),
        lager:info("Sig ~p ~p", [SigLen, MinSig]),
        if SigLen>=MinSig ->
             IsTemp=maps:get(temporary,Blk,false) =/= false,
             Header=maps:get(header, Blk),
             %enough signs. Make block.
             NewPHash=maps:get(parent, Header),

             if LBlockHash==BlockHash ->
                 lager:info("Ignore repeated block ~s",
                             [
                              blkid(LBlockHash)
                             ]),
                  throw({error,ignore});
                true ->
                  ok
             end,
             if LBlockHash=/=NewPHash ->
                  stout:log(sync_needed, [
                                          {temp, maps:get(temporary,Blk,false)},
                                          {hash, BlockHash},
                                          {phash, NewPHash},
                                          {lblockhash, LBlockHash},
                                          {sig, SigLen},
                                          {node, nodekey:node_name()},
                                          {height,maps:get(height, maps:get(header, Blk))}
                                         ]),
                  lager:info("Probably I need to resynchronize, height ~p/~p new block parent ~s, but my ~s",
                             [
                              maps:get(height, maps:get(header, Blk)),
                              maps:get(height, maps:get(header, LastBlock)),
                              blkid(NewPHash),
                              blkid(LBlockHash)
                             ]),
                  throw({error,need_sync});
                true ->
                  ok
             end,
             if IsTemp ->
                  stout:log(accept_block,
                            [
                             {temp, maps:get(temporary,Blk,false)},
                             {hash, BlockHash},
                             {sig, SigLen},
                             {node, nodekey:node_name()},
                             {height,maps:get(height, maps:get(header, Blk))}
                            ]),

                  lastblock2ets(BTable, MBlk),
                  tpic2:cast(<<"blockchain">>,
                            {<<"chainkeeper">>,
                             msgpack:pack(
                               #{
                               null=> <<"block_installed">>,
                               blk => block:pack(#{
                                        hash=> BlockHash,
                                        header => Header,
                                        sig_cnt=>LenSucc
                                       })
                              })
                            }),
                  gen_server:cast(blockchain_reader,update),
                  {reply, ok, State#{
                                tmpblock=>MBlk
                               }};
                true ->
                  Roots=maps:get(roots,Header,[]),
                  %normal block installation
                  %Filename="ledger_"++integer_to_list(os:system_time(millisecond))++atom_to_list(node())++"_bcupd",
                  %lager:info("Dumping to file ~s",[Filename]),
                  %mledger:dump_ledger({block_roots,Roots},Filename),
                  %
                  %
                  BlockLedgerHash=proplists:get_value(ledger_hash,Roots,<<0,0,0,0>>),

                  %NewTable=apply_bals(MBlk, Tbl),
                  Sets1_pre=apply_block_conf(MBlk, Sets),
                  Sets1=apply_block_conf_meta(MBlk, Sets1_pre),
                  lager:debug("Txs ~p", [ Txs ]),

                  NewLastBlock=LastBlock#{
                                 child=>BlockHash
                                },
                  T2=erlang:system_time(),

                  LApply=apply_ledger(
                           case BlockLedgerHash of
                             <<0,0,0,0>> ->
                               put;
                             _ ->
                               {checkput, BlockLedgerHash}
                           end, MBlk),
                  lager:info("LApply ~p",[LApply]),

                  LHash=case LApply of
                          {ok, LH11} ->
                            LH11;
                          {error, LH11} ->
                            %mledger:dump_ledger(MBlk,Filename++"FUCK"),
                            lager:error("Ledger error, hash mismatch on check and put ~p =/= ~p",
                                        [LH11, BlockLedgerHash]),
                            lager:error("Database corrupted"),
                            tpnode:die("Ledger hash mismatch")
                        end,

                  save_block(LDB, NewLastBlock, false),
                  lastblock2ets(BTable, MBlk),
                  save_block(LDB, MBlk, true),

                  case maps:is_key(sync, State) of
                    true ->
                      ok;
                    false ->
                      case maps:is_key(inbound_blocks, MBlk) of
                        true ->
                          gen_server:cast(txqueue,
                                          {done,
                                           proplists:get_keys(maps:get(inbound_blocks, MBlk))});
                        false -> ok
                      end,

                      if(Sets1 =/= Sets) ->
                          notify_settings(),
                          save_sets(LDB, MBlk, Sets, Sets1);
                        true -> ok
                      end
                  end,

                  SendSuccess=lists:map(
                                fun({TxID, #{register:=_, address:=Addr}}) ->
                                    {TxID, #{address=>Addr, block=>BlockHash}};
                                   ({TxID, #{kind:=register, ver:=2,
                                             extdata:=#{<<"addr">>:=Addr}}}) ->
                                    {TxID, #{address=>Addr, block=>BlockHash}};
                                   ({TxID, _Any}) ->
                                    lager:info("TX ~p",[_Any]),
                                    {TxID, #{block=>BlockHash}}
                                end, Txs),

                  stout:log(blockchain_success, [{result, SendSuccess}, {failed, nope}]),
                  gen_server:cast(txqueue, {done, SendSuccess}),
                  case maps:get(failed, MBlk, []) of
                    [] -> ok;
                    Failed ->
                      %there was failed tx. Block empty?
                      stout:log(blockchain_success, [{result, Failed}, {failed, yep}]),
                      gen_server:cast(txqueue, {failed, Failed})
                  end,

                  Settings=maps:get(settings, MBlk, []),
                  stout:log(blockchain_success, [{result, proplists:get_keys(Settings)}, {failed, nope}]),
                  gen_server:cast(txqueue, {done, proplists:get_keys(Settings)}),

                  T3=erlang:system_time(),
                  lager:info("enough confirmations ~w/~w. Installing new block ~s h= ~b (~.3f ms)/(~.3f ms)",
                             [
                              SigLen, MinSig,
                              blkid(BlockHash),
                              maps:get(height, maps:get(header, Blk)),
                              (T3-T2)/1000000,
                              (T3-T0)/1000000
                             ]),


                  gen_server:cast(tpnode_ws_dispatcher, {new_block, MBlk}),

                  stout:log(accept_block,
                            [
                             {temp, false},
                             {hash, BlockHash},
                             {sig, SigLen},
                             {node, nodekey:node_name()},
                             {height,maps:get(height, maps:get(header, Blk))},
                             {ledger_hash_actual, LHash}
                            ]),


                  case maps:get(etxs, Blk, []) of
                    [] -> ok;
                    EmitTXs when is_list(EmitTXs) ->
                      EmitBTXs=lists:filtermap(
                                 fun({_,#{extdata:=#{<<"auto">>:=0}}}) ->
                                     false;
                                    ({TxID,Tx}) ->
                                     {true,{TxID,
                                            tx:pack(
                                              tx:sign(
                                                tx:set_ext(origin_height,Hei,
                                                           tx:set_ext(origin_block,BlockHash,
                                                                      Tx
                                                                     )
                                                          ),
                                                nodekey:get_priv()),
                                              [withext])
                                           }}
                                 end, EmitTXs),
                      IDs=[ TxID || {TxID, _} <- EmitTXs ],
                      lager:info("Inject TXs ~p", [EmitTXs]),
                      Push=gen_server:cast(txstorage, {store_etxs, EmitBTXs}),
                      lager:info("Inject TXs res ~p", [EmitBTXs]),
                      gen_server:cast(txqueue,{push_head, [ {TxID, null} || TxID <- IDs]}),
                      stout:log(push_etx,
                                [
                                 %{node_name,NodeName},
                                 {txs, EmitTXs},
                                 {res, Push}
                                ])
                  end,

                  maps:fold(
                    fun(ChainID, OutBlock, _) ->
                        try
                          lager:info("Out to ~b ~p",
                                     [ChainID, OutBlock]),
                          Chid=xchain:pack_chid(ChainID),
                          xchain_dispatcher:pub(
                            Chid,
                            {outward_block,
                             MyChain,
                             ChainID,
                             block:pack(OutBlock)
                            })
                        catch XEc:XEe:S ->
                                %S=erlang:get_stacktrace(),
                                lager:error("Can't publish outward block: ~p:~p",
                                            [XEc, XEe]),
                                lists:foreach(
                                  fun(Se) ->
                                      lager:error("at ~p", [Se])
                                  end, S)
                        end
                    end, 0, block:outward_mk(MBlk)),
                  gen_server:cast(txpool,{new_height, Hei}),
                  gen_server:cast(txqueue,{new_height, Hei}),
                  tpic2:cast(<<"blockchain">>,
                            {<<"chainkeeper">>,
                             msgpack:pack(
                               #{
                               null=> <<"block_installed">>,
                               blk => block:pack(#{
                                        hash=> BlockHash,
                                        header => Header,
                                        sig_cnt=>LenSucc
                                       })
                              })
                            }),


                  S1=maps:remove(tmpblock, State),

                  {reply, ok, S1#{
                                prevblock=> NewLastBlock,
                                lastblock=> MBlk,
                                unksig => 0,
                                pre_settings => Sets,
                                settings=>if Sets==Sets1 ->
                                               Sets;
                                             true ->
                                               chainsettings:settings_to_ets(Sets1)
                                          end,
                                candidates=>#{}
                               }
                  }
             end;
           true ->
             %not enough
             {reply, {ok, no_enough_sig}, State#{
                                            candidates=>
                                            maps:put(BlockHash,
                                                     MBlk,
                                                     Candidates)
                                           }
             }
        end
    end
  catch throw:ignore ->
          {reply, {ok, ignore}, State};
        throw:{error, Descr} ->
          {reply, {error, Descr}, State};
        Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          lager:error("BC new_block error ~p:~p", [Ec, Ee]),
          lists:foreach(
            fun(Se) ->
                lager:error("at ~p", [Se])
            end, S),
          {reply, {error, unknown}, State}
  end;

handle_call(_Request, _From, State) ->
  lager:info("Unhandled ~p",[_Request]),
  {reply, unhandled_call, State}.

handle_cast({new_block, #{hash:=BlockHash}=Blk,  PID},
            #{ sync:=SyncPid }=State) when self()=/=PID ->
  stout:log(got_new_block,
            [
             {ignore, sync},
             {hash, BlockHash},
             {node, nodekey:node_name()},
             {height,maps:get(height, maps:get(header, Blk))}
            ]),
  lager:info("Ignore block from ~p during sync with ~p", [PID, SyncPid]),
  {noreply, State};

handle_cast({new_block, #{hash:=_}, _PID}=Message, State) ->
  {reply, _, NewState} = handle_call(Message, self(), State),
  {noreply, NewState};

handle_cast({signature, BlockHash, Sigs},
            #{ldb:=LDB,
              tmpblock:=#{
                hash:=LastBlockHash,
                sign:=OldSigs
               }=LastBlk
             }=State) when BlockHash==LastBlockHash ->
  {Success, _} = block:sigverify(LastBlk, Sigs),
  %NewSigs=lists:usort(OldSigs ++ Success),
  NewSigs=bsig:add_sig(OldSigs, Success),
  if(OldSigs=/=NewSigs) ->
      lager:info("Extra confirmation of prev. block ~s +~w=~w",
                 [blkid(BlockHash),
                  length(Success),
                  length(NewSigs)
                 ]),
      NewLastBlk=LastBlk#{sign=>NewSigs},
      save_block(LDB, NewLastBlk, false),
      {noreply, State#{tmpblock=>NewLastBlk}};
    true ->
      lager:info("Extra confirm not changed ~w/~w",
                 [length(OldSigs), length(NewSigs)]),
      {noreply, State}
  end;

handle_cast({signature, BlockHash, Sigs},
            #{ldb:=LDB,
              lastblock:=#{
                hash:=LastBlockHash,
                sign:=OldSigs
               }=LastBlk
             }=State) when BlockHash==LastBlockHash ->
  {Success, _} = block:sigverify(LastBlk, Sigs),
  %NewSigs=lists:usort(OldSigs ++ Success),
  NewSigs=bsig:add_sig(OldSigs, Success),
  if(OldSigs=/=NewSigs) ->
      lager:info("Extra confirmation of prev. block ~s +~w=~w",
                 [blkid(BlockHash),
                  length(Success),
                  length(NewSigs)
                 ]),
      NewLastBlk=LastBlk#{sign=>NewSigs},
      save_block(LDB, NewLastBlk, false),
      {noreply, State#{lastblock=>NewLastBlk}};
    true ->
      lager:info("Extra confirm not changed ~w/~w",
                 [length(OldSigs), length(NewSigs)]),
      {noreply, State}
  end;

handle_cast({signature, BlockHash, _Sigs}, State) ->
  lager:info("Got sig for block ~s, but it's not my last block",
             [blkid(BlockHash) ]),
  T=maps:get(unksig,State,0),
  if(T>=2) ->
      self() ! checksync,
      {noreply, State};
    true ->
      {noreply, State#{unksig=>T+1}}
  end;

handle_cast(_Msg, State) ->
  lager:info("Unknown cast ~p", [_Msg]),
  file:write_file("tmp/unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
  file:write_file("tmp/unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
  {noreply, State}.

handle_info({backup, Path, From, LH, Cnt}, #{ldb:=LDB}=State) ->
  case ldb:read_key(LDB,
                    <<"block:", LH/binary>>,
                    undefined
                   ) of
    undefined ->
      gen_server:reply(From,{noblock, LH, Cnt});
    #{header:=#{parent:=Parent,height:=Hei}} ->
      lager:info("B ~p",[Hei]),
      if(Cnt rem 10 == 0) ->
          erlang:send(self(), {backup, Path, From, Parent, Cnt+1});
        true ->
          handle_info({backup, Path, From, Parent, Cnt+1}, State)
      end;
    #{header:=#{}} ->
      gen_server:reply(From,{done, Cnt})
  end,
  {noreply, State};

handle_info(_Info, State) ->
  lager:info("BC unhandled info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  lager:error("Terminate blockchain ~p", [_Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

format_status(_Opt, [_PDict, State]) ->
  State#{
    ldb=>handler
   }.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
save_sets(ignore, _Blk, _OldSettings, _Settings) -> ok;

save_sets(LDB, #{hash:=Hash, header:=#{parent:=Parent}}, OldSettings, Settings) ->
  ldb:put_key(LDB, <<"settings:",Parent/binary>>, erlang:term_to_binary(OldSettings)),
  ldb:put_key(LDB, <<"settings:",Hash/binary>>, erlang:term_to_binary(Settings)),
  ldb:put_key(LDB, <<"settings">>, erlang:term_to_binary(Settings)).

save_block(ignore, _Block, _IsLast) -> ok;
save_block(LDB, Block, IsLast) ->
  BlockHash=maps:get(hash, Block),
  ldb:put_key(LDB, <<"block:", BlockHash/binary>>, Block),
  if IsLast ->
       ldb:put_key(LDB, <<"lastblock">>, BlockHash),
       gen_server:cast(blockchain_reader,update);
     true ->
       ok
  end.

load_sets(LDB, LastBlock) ->
  case ldb:read_key(LDB, <<"settings">>, undefined) of
    undefined ->
      apply_block_conf(LastBlock, settings:new());
    Bin ->
      binary_to_term(Bin)
  end.

apply_ledger(Action, #{bals:=S, hash:=BlockHash, header:=#{height:=Height}}) ->
  Patch=maps:fold(
          fun(_Addr, #{chain:=_NewChain}, Acc) ->
              Acc;
             (Addr, #{amount:=_}=V, Acc) -> %modern format
              [{Addr, V}|Acc];
             %legacy blocks
             ({Addr, Cur}, Val, Acc) when is_integer(Val) ->
              [{Addr, #{amount=>#{Cur=>Val}}}|Acc];
             ({Addr, Cur}, #{amount:=Am}=Val, Acc) when is_map(Val) ->
              [{Addr,
                maps:merge(
                  #{amount=>#{Cur=>Am}},
                  maps:with([t, seq], Val)
                 )
               }|Acc]
          end, [], S),
  lager:info("Apply bals ~p", [Patch]),
  lager:info("Apply patches ~p", [mledger:bals2patch(Patch)]),
  LR=case Action of
       {checkput, Hash} ->
         mledger:apply_patch(mledger:bals2patch(Patch), {commit, {Height, BlockHash}, Hash});
%       check ->
%         mledger:apply_patch(mledger:bals2patch(Patch), check);
       put ->
         {ok,mledger:apply_patch(mledger:bals2patch(Patch), {commit, {Height, BlockHash}})}
     end,
  lager:info("Apply ~p ~p", [Action, LR]),
  LR.

apply_block_conf_meta(#{hash:=Hash}=Block, Conf0) ->
  Meta=#{ublk=>Hash},
  S=maps:get(settings, Block, []),
  lists:foldl(
    fun({_TxID, #{patch:=Body}}, Acc) -> %old patch
        settings:patch(settings:make_meta(Body,Meta), Acc);
       ({_TxID, #{patches:=Body,kind:=patch}}, Acc) -> %new patch
        settings:patch(settings:make_meta(Body,Meta), Acc)
    end, Conf0, S).

apply_block_conf(Block, Conf0) ->
  S=maps:get(settings, Block, []),
  if S==[] -> ok;
     true ->
       file:write_file("tmp/applyconf.txt",
                       io_lib:format("APPLY BLOCK CONF ~n~p.~n~n~p.~n~p.~n",
                                     [Block, S, Conf0])
                      )
  end,
  lists:foldl(
    fun({_TxID, #{patch:=Body}}, Acc) -> %old patch
        lager:notice("TODO: Must check sigs"),
        %Hash=crypto:hash(sha256, Body),
        settings:patch(Body, Acc);
       ({_TxID, #{patches:=Body,kind:=patch}}, Acc) -> %new patch
        lager:notice("TODO: Must check sigs"),
        %Hash=crypto:hash(sha256, Body),
        settings:patch(Body, Acc)
    end, Conf0, S).

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).

notify_settings() ->
  gen_server:cast(txpool, settings),
  gen_server:cast(txqueue, settings),
  gen_server:cast(mkblock, settings),
  gen_server:cast(blockvote, settings),
  gen_server:cast(synchronizer, settings),
  gen_server:cast(xchain_client, settings).

mychain(State) ->
  {MyChain, MyName, ChainNodes}=blockchain_reader:mychain(),
  lager:info("My name ~p chain ~p ournodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
  ets:insert(blockchain,[{myname,MyName},{chainnodes,ChainNodes},{mychain,MyChain}]),
  maps:merge(State,
             #{myname=>MyName,
               chainnodes=>ChainNodes,
               mychain=>MyChain
              }).

getset(Name,#{settings:=Sets, mychain:=MyChain}=_State) ->
  chainsettings:get(Name, Sets, fun()->MyChain end).

backup(Dir) ->
  {ok,DBH}=gen_server:call(blockchain_updater,get_dbh),
  backup(DBH, Dir, ldb:read_key(DBH,<<"lastblock">>,undefined), 0).


backup(_DBH, _Path, <<0,0,0,0,0,0,0,0>>, Cnt) ->
  {done, Cnt};

backup(DBH, Path, LH, Cnt) ->
  case ldb:read_key(DBH,
                    <<"block:", LH/binary>>,
                    undefined
                   ) of
    undefined ->
      {noblock, LH, Cnt};
    #{header:=#{parent:=Parent,height:=Hei}}=Blk ->
      ok=file:write_file(Path++"/"++integer_to_list(Hei)++".txt",
                         [io_lib_pretty:print(Blk,[{strings,true}]),".\n"],
                         [{encoding, utf8}]),
      lager:info("B ~p",[Hei]),
      backup(DBH, Path, Parent, Cnt+1);
    #{header:=#{}} ->
      {done, Cnt}
  end.

restore(Path) ->
  timer:sleep(500),
  #{hash:=LH,header:=#{height:=Hei}}=blockchain:last(),
  restore(Path, Hei+1, LH, 0).

restore(Dir, N, Prev, C) ->
  P=Dir++"/"++integer_to_list(N)++".txt",
  case file:consult(P) of
    {error, enoent} -> {done,N-1,C};
    {ok, [#{header:=#{height:=Hei,parent:=Parent},hash:=Hash}=Blk]} when Hei==N,
                                                                         Prev==Parent ->

      ok=gen_server:call(blockchain_updater,{new_block, Blk, self()}),
      restore(Dir, N+1, Hash, C+1);
    {ok, [#{header:=Header}]} ->
      lager:error("Block in ~s (~p) is invalid for parent ~p",
                  [P,Header,Prev]),
      {done, N-1, C}
  end.

block_rel(LDB,Hash,Rel) when Rel==prev orelse Rel==child orelse Rel==self ->
  case ldb:read_key(LDB, <<"block:", Hash/binary>>, undefined) of
    undefined ->
      noblock;
    #{header:=#{}} = Block when Rel == self ->
      Block;
    #{header:=#{}, child:=Child} = _Block when Rel == child ->
      case ldb:read_key(LDB, <<"block:", Child/binary>>, undefined) of
        undefined ->
          havenochild;
        #{header:=#{}} = SBlock ->
          SBlock
      end;
    #{header:=#{}} = _Block when Rel == child ->
      nochild;
    #{header:=#{parent:=Parent}} = _Block when Rel == prev ->
      case ldb:read_key(LDB, <<"block:", Parent/binary>>, undefined) of
        undefined ->
          havenoprev;
        #{header:=#{}} = SBlock ->
          SBlock
      end;
    #{header:=#{}} = _Block when Rel == prev ->
      noprev;
    _ ->
      unknown
  end.

lastblock2ets(TableID, #{header:=Hdr,hash:=Hash,sign:=Sign,temporary:=Tmp}) ->
  ets:insert(TableID,[
                      {tmp_temporary, Tmp},
                      {tmp_header,Hdr},
                      {tmp_hash,Hash},
                      {tmp_sign,Sign},
                      {last_meta,
                       #{
                         header=>Hdr,
                         hash=>Hash,
                         sign=>Sign,
                         temporary=>Tmp
                        }
                      }
                     ]);

lastblock2ets(TableID, #{header:=Hdr,hash:=Hash,sign:=Sign}) ->
  ets:delete(TableID, tmp_temporary),
  ets:delete(TableID, tmp_header),
  ets:delete(TableID, tmp_hash),
  ets:delete(TableID, tmp_sign),
  ets:insert(TableID,[
                      {header,Hdr},
                      {hash,Hash},
                      {sign,Sign},
                      {last_meta,
                       #{
                         header=>Hdr,
                         hash=>Hash,
                         sign=>Sign
                        }
                      }
                     ]).
