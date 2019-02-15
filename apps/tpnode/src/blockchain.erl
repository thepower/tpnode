-module(blockchain).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([apply_block_conf/2,
         apply_block_conf_meta/2,
         apply_ledger/2,
         last_meta/0,
         last/0, last/1, chain/0,
         backup/1, restore/1,
         chainstate/0,
         blkid/1,
         rel/2,
         send_block_real/4,
         tpiccall/3,
         exists/1]).

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

chain() ->
  {ok, Chain} = chainsettings:get_setting(mychain),
  Chain.

rel(Hash, Rel) when Rel==prev orelse Rel==child ->
  gen_server:call(blockchain, {get_block, Hash, Rel});

rel(Hash, self) ->
  gen_server:call(blockchain, {get_block, Hash}).

exists(Hash) ->
  gen_server:call(blockchain, {block_exists, Hash}).
  

last_meta() ->
  [{last_meta, Blk}]=ets:lookup(lastblock,last_meta),
  Blk.

last(N) ->
    gen_server:call(blockchain, {last_block, N}).

last() ->
    gen_server:call(blockchain, last_block).

chainstate() ->
  Candidates=lists:reverse(
               tpiccall(<<"blockchain">>,
                        #{null=><<"sync_request">>},
                        [last_hash, last_height, chain, prev_hash, last_temp]
                       ))++[{self,gen_server:call(?MODULE,sync_req)}],
  io:format("Cand ~p~n",[Candidates]),
  ChainState=lists:foldl( %first suitable will be the quickest
               fun({_, #{chain:=_HisChain,
                         %null:=<<"sync_available">>,
                         last_hash:=Hash,
                         last_temp:=Tmp,
%                         prev_hash:=PHash,
                         last_height:=Heig
                        }=A
                   }, Acc) ->
                   PHash=maps:get(prev_hash,A,<<0,0,0,0,0,0,0,0>>),
                   maps:put({Heig, Hash, PHash, Tmp}, maps:get({Heig, Hash, PHash, Tmp}, Acc, 0)+1, Acc);
                  ({_, _}, Acc) ->
                   Acc
               end, #{}, Candidates),
  erlang:display(maps:fold(
    fun({Heig,Has,PHas,Tmp},V,Acc) ->
        maps:put(iolist_to_binary([
                    integer_to_binary(Heig),
                    ":",blkid(Has),
                    "/",blkid(PHas),":",
                    integer_to_list(if Tmp==false -> 0; true -> Tmp end)
                                  ]),V,Acc)
    end, #{}, ChainState)),
  ChainState.


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    Table=ets:new(?MODULE,[named_table,protected,bag,{read_concurrency,true}]),
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
                  case Restore of
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
                  end;
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
        spawn(blockchain, restore, [Path1]);
      _ ->
        erlang:send_after(6000, self(), runsync)
    end,
    notify_settings(),
    erlang:spawn(fun() ->
                     timer:sleep(200),
                     notify_settings()
                 end),
    {ok, Res}.

handle_call(get_dbh, _From, #{ldb:=LDB}=State) ->
  {reply, {ok, LDB}, State};

handle_call({backup, Path}, From, #{lastblock:=#{hash:=LH}}=State) ->
  erlang:send(self(), {backup, Path, From, LH, 0}),
  {noreply, State};

handle_call(first_block, _From, #{ldb:=LDB, lastblock:=LB}=State) ->
    {reply, get_first_block(LDB, maps:get(hash, LB)), State};

handle_call(ready, _From, State) ->
    {reply, not maps:is_key(sync, State), State};

handle_call(extract_txs, _From, #{ldb:=LDB, lastblock:=LB}=State) ->
    try
        First=get_first_block(LDB,
                              maps:get(hash, LB)
                             ),
        Res=foldl(
              fun(Block, Acc) ->
                      H=maps:get(header, Block),
                      Set=maps:get(settings, Block, []),
                      Tx= lists:map(
                            fun({K, V}) ->
                                    {K, maps:without([public_key, signature], V)}
                            end,
                            maps:get(txs, Block)
                           ),
                      if Tx==[] ->
                             Acc;
                         true ->
                             [{maps:get(height, H, 0), Tx, Set}|Acc]
                      end
              end,
              [] , LDB, First),
        {reply, lists:reverse(Res), State}
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              {reply, {error, Ec, Ee, S}, State}
    end;


handle_call(fix_tables, _From, #{ldb:=LDB, lastblock:=LB}=State) ->
    try
        First=get_first_block(LDB,
                              maps:get(hash, LB)
                             ),
%        gen_server:call(ledger, '_flush'),
        Res=foldl(fun(Block, #{settings:=Sets}) ->
                          lager:info("Block@~s ~p",
                                     [
                                      blkid(maps:get(hash, Block)),
                                      maps:keys(Block)
                                     ]),
                          Sets1=apply_block_conf(Block, Sets),
                          apply_ledger(put, Block),
                          #{settings=>Sets1}
                  end,
                  #{
                    settings=>settings:new()
                   }, LDB, First),
        notify_settings(),
        {reply, Res, mychain(maps:merge(State, Res))}
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              {reply, {error, Ec, Ee, S}, State}
    end;

handle_call(sync_req, _From, State) ->
  {reply, sync_req(State), State};

handle_call({runsync, NewChain}, _From, State) ->
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, call} ]),
  self() ! runsync,
  {reply, sync, State#{mychain:=NewChain}};

handle_call({get_addr, Addr, _RCur}, _From, State) ->
    case ledger:get([Addr]) of
        #{Addr:=Bal} ->
            {reply, Bal, State};
        _ ->
            {reply, bal:new(), State}
    end;


handle_call({get_addr, Addr}, _From, State) ->
    case ledger:get([Addr]) of
        #{Addr:=Bal} ->
            {reply, Bal, State};
        _ ->
            {reply, bal:new(), State}
    end;

handle_call(fix_first_block, _From, #{ldb:=LDB, lastblock:=LB}=State) ->
    lager:info("Find first block"),
    try
        Res=first_block(LDB, maps:get(parent, maps:get(header, LB)), maps:get(hash, LB)),
        {reply, Res, State}
    catch Ec:Ee ->
              {reply, {error, Ec, Ee}, State}
    end;

handle_call(last_block_height, _From,
            #{mychain:=MC, lastblock:=#{header:=#{height:=H}}}=State) ->
    {reply, {MC, H}, State};

handle_call(status, _From,
            #{mychain:=MC, lastblock:=#{header:=H, hash:=BH}}=State) ->
    {reply, { MC, BH, H }, State};

handle_call(last, _From, #{lastblock:=L}=State) ->
    {reply, maps:with([child, header, hash], L), State};

handle_call(lastsig, _From, #{myname:=MyName,
                              chainnodes:=CN,
                              lastblock:=#{hash:=H, sign:=Sig}
                             }=State) ->
  SS=try
       lists:foldl(
         fun(#{extra:=PL}, Acc) ->
             case proplists:get_value(pubkey, PL, undefined) of
               undefined -> Acc;
               BinKey ->
                 case maps:get(BinKey, CN, undefined) of
                   undefined -> Acc;
                   NodeID ->
                     [NodeID|Acc]
                 end
             end
         end,
         [],
         Sig
        )
     catch _:_ -> []
     end,
  {reply, #{hash=>H,
            origin=>MyName,
            signed=>SS}, State};

handle_call({last_block, N}, _From, #{ldb:=LDB}=State) when is_integer(N) ->
    {reply, rewind(LDB,N), State};

handle_call(last_block, _From, #{tmpblock:=LB}=State) ->
    {reply, LB, State};

handle_call(last_block, _From, #{lastblock:=LB}=State) ->
    {reply, LB, State};

handle_call({get_block, last}, _From, #{tmpblock:=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, last}, _From, #{lastblock:=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, LBH}, _From, #{lastblock:=#{hash:=LBH}=LB}=State) ->
    {reply, LB, State};

handle_call({get_block, TBH}, _From, #{tmpblock:=#{hash:=TBH}=TB}=State) ->
    {reply, TB, State};

handle_call({get_block, BlockHash}, _From, #{ldb:=LDB, lastblock:=#{hash:=LBH}=LB}=State)
  when is_binary(BlockHash) ->
    %lager:debug("Get block ~p", [BlockHash]),
    Block=if BlockHash==LBH -> LB;
             true ->
                 ldb:read_key(LDB,
                              <<"block:", BlockHash/binary>>,
                              undefined)
          end,
    {reply, Block, State};

handle_call({get_block, BlockHash, Rel}, _From, #{ldb:=LDB, lastblock:=#{hash:=LBH}}=State)
  when is_binary(BlockHash) andalso is_atom(Rel) ->
  %lager:debug("Get block ~p", [BlockHash]),
  H=if BlockHash==last ->
         LBH;
       true ->
         BlockHash
    end,
  Res=block_rel(LDB, H, Rel),
  {reply, Res, State};

handle_call({block_exists, BlockHash}, _From, #{ldb:=LDB} = State)
  when is_binary(BlockHash) ->
  %lager:debug("Get block ~p", [BlockHash]),
  Exists =
    case ldb:read_key(LDB, <<"block:", BlockHash/binary>>, undefined) of
      undefined ->
        false;
      _ ->
        true
    end,
  {reply, Exists, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(saveset, _From, #{settings:=Settings}=State) ->
  file:write_file("tmp/settings.dump",
          io_lib:format("~p.~n", [Settings])),
    {reply, Settings, State};

handle_call(restoreset, _From, #{ldb:=LDB}=State) ->
  {ok, [S1]}=file:consult("tmp/settings.dump"),
  true=is_map(S1),
  save_sets(LDB, S1),
  notify_settings(),
  {reply, S1, State#{settings=>chainsettings:settings_to_ets(S1)}};

handle_call(rollback, _From, #{
                        pre_settings:=PreSets,
                        btable:=BTable,
                        lastblock:=#{header:=#{parent:=Parent}},
                        ldb:=LDB}=State) ->
  case block_rel(LDB, Parent, self) of
    Error when is_atom(Error) ->
      {reply, {error, Error}, State};
    #{hash:=H}=Blk ->
      LH=block:ledger_hash(Blk),
      case gen_server:call(ledger,{rollback, LH}) of
        {ok, LH} ->
          save_block(LDB, maps:remove(child,Blk), true),
          chainsettings:settings_to_ets(PreSets),
          lastblock2ets(BTable, Blk),
          {reply,
           {ok, H},
           maps:without(
             [pre_settings,tmpblock],
             State#{
               lastblock=>Blk,
               settings=>PreSets
              }
            )
          };
        {error, Err} ->
          {reply, {ledger_error, Err}, State}
      end
  end;

handle_call(rollback, _From, #{
                        btable:=_,
                        lastblock:=_,
                        ldb:=_}=State) ->
  {reply, {error, no_prev_state}, State};

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
                  tpic:cast(tpic, <<"blockchain">>,
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

                  {reply, ok, State#{
                                tmpblock=>MBlk
                               }};
                true ->
                  %normal block installation
                  {ok, LHash}=apply_ledger(check, MBlk),
                  %NewTable=apply_bals(MBlk, Tbl),
                  Sets1_pre=apply_block_conf(MBlk, Sets),
                  Sets1=apply_block_conf_meta(MBlk, Sets1_pre),
                  lager:info("Ledger dst hash ~s, block ~s",
                             [hex:encode(LHash),
                              hex:encode(maps:get(ledger_hash, Header, <<0:256>>))
                             ]
                            ),
                  lager:debug("Txs ~p", [ Txs ]),

                  NewLastBlock=LastBlock#{
                                 child=>BlockHash
                                },
                  T2=erlang:system_time(),
                  save_block(LDB, NewLastBlock, false),
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
                          save_sets(LDB, Sets1);
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

                  {ok, LH1} = apply_ledger(put, MBlk),
                  if(LH1 =/= LHash) ->
                      lager:error("Ledger error, hash mismatch on check and put"),
                      lager:error("Database corrupted");
                    true ->
                      ok
                  end,

                  stout:log(accept_block,
                            [
                             {temp, false},
                             {hash, BlockHash},
                             {sig, SigLen},
                             {node, nodekey:node_name()},
                             {height,maps:get(height, maps:get(header, Blk))},
                             {ledger_hash_actual, LH1},
                             {ledger_hash_checked, LHash}
                            ]),


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
                        catch XEc:XEe ->
                                S=erlang:get_stacktrace(),
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
                  tpic:cast(tpic, <<"blockchain">>,
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

                  lastblock2ets(BTable, MBlk),
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
        Ec:Ee ->
          S=erlang:get_stacktrace(),
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

handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                                <<"hash">>:=Hash,
                                <<"rel">>:=<<"child">>=Rel
                            }},
    #{ tmpblock:=#{ header:=#{ parent:=Hash } }=TmpBlock } = State) ->
  MyRel = child,
  lager:info("Pick temp block ~p ~p",[blkid(Hash),Rel]),
  BlockParts = block:split_packet(block:pack(TmpBlock)),
  Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => MyRel}},
  send_block(tpic, Origin, Map, BlockParts),
  {noreply, State};

handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                                <<"hash">>:=Hash,
                                <<"rel">>:=<<"child">>
                            }},
            #{tmpblock:=#{header:=#{parent:=Hash}}=TmpBlk} = State) ->
  BinBlock=block:pack(TmpBlk),
  lager:info("I was asked for ~s for blk ~s: ~p",[child,blkid(Hash),TmpBlk]),
  BlockParts = block:split_packet(BinBlock),
  Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => child}},
  send_block(tpic, Origin, Map, BlockParts),
  {noreply, State};


handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                                <<"hash">>:=Hash,
                                <<"rel">>:=Rel
                            }},
    #{ldb:=LDB} = State) ->
  lager:info("Pick block ~p ~p",[blkid(Hash),Rel]),
    MyRel = case Rel of
                <<"pre", _/binary>> -> prev;
                <<"child">> -> child;
                %<<"self">> -> self;
                _ -> self
            end,
    R=case block_rel(LDB, Hash, MyRel) of
      Error when is_atom(Error) ->
        #{error=> Error};
      Blk when is_map(Blk) ->
          #{block => block:pack(Blk)}
    end,
    lager:info("I was asked for ~s for blk ~s: ~p",[MyRel,blkid(Hash),R]),

    case maps:is_key(block, R) of
      false ->
        tpic:cast(tpic, Origin,
                  msgpack:pack(
                    maps:merge(
                      #{
                      null=> <<"block">>,
                      req=> #{<<"hash">> => Hash,
                              <<"rel">> => MyRel}
                     }, R))),
        {noreply, State};

      true ->
        #{block := BinBlock} = R,
        BlockParts = block:split_packet(BinBlock),
        Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => MyRel}},
        send_block(tpic, Origin, Map, BlockParts),
        {noreply, State}
    end;


handle_cast({tpic, Origin, #{null:=<<"instant_sync_run">>}},
            #{settings:=Settings, lastblock:=LastBlock}=State) ->
    lager:info("Starting instant sync source"),
    ledger_sync:run_source(tpic, Origin, LastBlock, Settings),
    {noreply, State};


handle_cast({tpic, Origin, #{null:=<<"sync_request">>}}, State) ->
  MaySync=sync_req(State),
  tpic:cast(tpic, Origin, msgpack:pack(MaySync)),
  {noreply, State};

handle_cast({tpic, Origin, #{null := <<"sync_block">>,
                             <<"block">> := BinBlock}},
            #{sync:=SyncOrigin }=State) when Origin==SyncOrigin ->
    Blk=block:unpack(BinBlock),
    handle_cast({new_block, Blk, Origin}, State);


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

handle_cast({tpic, Peer, #{null := <<"sync_done">>}},
            #{ldb:=LDB, settings:=Set,
              sync:=SyncPeer}=State) when Peer==SyncPeer ->
    %save_bals(LDB, Tbl),
    save_sets(LDB, Set),
    gen_server:cast(blockvote, blockchain_sync),
    notify_settings(),
    {noreply, maps:remove(sync, State#{unksig=>0})};

handle_cast({tpic, Peer, #{null := <<"continue_sync">>,
                         <<"block">> := BlkId,
                         <<"cnt">> := NextB}}, #{ldb:=LDB}=State) ->
    lager:info("SYNCout from ~s to ~p", [blkid(BlkId), Peer]),
    case ldb:read_key(LDB, <<"block:", BlkId/binary>>, undefined) of
        undefined ->
            lager:info("SYNC done at ~s", [blkid(BlkId)]),
            tpic:cast(tpic, Peer, msgpack:pack(#{null=><<"sync_done">>}));
        #{header:=#{}, child:=Child}=_Block ->
            lager:info("SYNC next block ~s to ~p", [blkid(Child), Peer]),
            handle_cast({continue_syncc, Child, Peer, NextB}, State);
        #{header:=#{}}=Block ->
            lager:info("SYNC last block ~p to ~p", [Block, Peer]),
            tpic:cast(tpic, Peer, msgpack:pack(#{null=><<"sync_block">>,
                                              block=>block:pack(Block)})),
            tpic:cast(tpic, Peer, msgpack:pack(#{null=><<"sync_done">>}))
    end,
    {noreply, State};


handle_cast({continue_syncc, BlkId, Peer, NextB}, #{ldb:=LDB,
                                                   lastblock:=#{hash:=LastHash}=LastBlock
                                                  }=State) ->
    case ldb:read_key(LDB, <<"block:", BlkId/binary>>, undefined) of
        _ when BlkId == LastHash ->
            lager:info("SYNCC last block ~s from state", [blkid(BlkId)]),
            tpic:cast(tpic, Peer, msgpack:pack(
                                  #{null=><<"sync_block">>,
                                    block=>block:pack(LastBlock)})),
            tpic:cast(tpic, Peer, msgpack:pack(
                                  #{null=><<"sync_done">>}));
        undefined ->
            lager:info("SYNCC done at ~s", [blkid(BlkId)]),
            tpic:cast(tpic, Peer, msgpack:pack(
                                  #{null=><<"sync_done">>}));
        #{header:=#{height:=H}, child:=Child}=Block ->
            P=msgpack:pack(
                #{null=><<"sync_block">>,
                  block=>block:pack(Block)}),
            lager:info("SYNCC send block ~w ~s ~w bytes to ~p",
                       [H, blkid(BlkId), size(P), Peer]),
            tpic:cast(tpic, Peer, P),

            if NextB > 1 ->
                   gen_server:cast(self(), {continue_syncc, Child, Peer, NextB-1});
               true ->
                   lager:info("SYNCC pause ~p", [BlkId]),
                   tpic:cast(tpic, Peer, msgpack:pack(
                                         #{null=><<"sync_suspend">>,
                                           <<"block">>=>BlkId}))
            end;
        #{header:=#{}}=Block ->
            lager:info("SYNCC last block at ~s", [blkid(BlkId)]),
            tpic:cast(tpic, Peer, msgpack:pack(
                                  #{null=><<"sync_block">>,
                                    block=>block:pack(Block)})),
            if (BlkId==LastHash) ->
                   lager:info("SYNC Real last");
               true ->
                   lager:info("SYNC Not really last")
            end,
            tpic:cast(tpic, Peer, msgpack:pack(#{null=><<"sync_done">>}))
    end,
    {noreply, State};

handle_cast({tpic, Peer, #{null := <<"sync_suspend">>,
                         <<"block">> := BlkId}},
            #{ sync:=SyncPeer,
               lastblock:=#{hash:=LastHash}=LastBlock
             }=State) when SyncPeer==Peer ->
    lager:info("Sync suspend ~s, my ~s", [blkid(BlkId), blkid(LastHash)]),
    lager:info("MyLastBlock ~p", [maps:get(header, LastBlock)]),
    if(BlkId == LastHash) ->
          lager:info("Last block matched, continue sync"),
          tpic:cast(tpic, Peer, msgpack:pack(#{
                                  null=><<"continue_sync">>,
                                  <<"block">>=>LastHash,
                                  <<"cnt">>=>2})),
          {noreply, State};
      true ->
          lager:info("SYNC ERROR"),
%          {noreply, run_sync(State)}
          {noreply, State}
    end;

handle_cast({tpic, Peer, #{null := <<"sync_suspend">>,
                         <<"block">> := _BlkId}}, State) ->
    lager:info("sync_suspend from bad peer ~p", [Peer]),
    {noreply, State};

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin, []) of
        {ok, Struct} ->
            lager:debug("Inbound TPIC ~p", [maps:get(null, Struct)]),
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            lager:info("Can't decode  TPIC ~p", [_Any]),
            lager:info("TPIC ~p", [Bin]),
            {noreply, State}
    end;

handle_cast({tpic, From, #{
                     null:=<<"tail">>
                    }},
            #{mychain:=MC, lastblock:=#{header:=#{height:=H},
                                      hash:=Hash }}=State) ->
    tpic:cast(tpic, From, msgpack:pack(#{null=><<"response">>,
                                                         mychain=>MC,
                                                         height=>H,
                                                         hash=>Hash
                                                        })),
    {noreply, State};


handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p", [_Msg]),
    file:write_file("tmp/unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
    file:write_file("tmp/unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
    {noreply, State}.

handle_info(runsync, #{sync:=_}=State) ->
  stout:log(runsync, [
    {node, nodekey:node_name()},
    {where, already_syncing}
  ]),
  {noreply, State};


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

handle_info({inst_sync, settings, Patches}, State) ->
    %sync almost done - got settings
    Settings=settings:patch(Patches, settings:new()),
    {noreply, State#{syncsettings=>Settings}};

handle_info({inst_sync, block, BinBlock}, State) ->
    #{hash:=Hash, header:=#{ledger_hash:=LH, height:=Height}}=Block=block:unpack(BinBlock),
    lager:info("BC Sync Got block ~p ~s~n", [Height, bin2hex:dbin2hex(Hash)]),
    lager:info("BS Sync Block's Ledger ~s~n", [bin2hex:dbin2hex(LH)]),
    %sync in progress - got block
    stout:log(inst_sync,
      [
        {node, nodekey:node_name()},
        {reason, block},
        {type, inst_sync},
        {height, Height},
        {lh, LH}
      ]
    ),
  
    {noreply, State#{syncblock=>Block}};

handle_info({inst_sync, ledger}, State) ->
    %sync in progress got ledger
    stout:log(inst_sync, [ {node, nodekey:node_name()}, {reason, ledger}, {type, inst_sync} ]),
    {noreply, State};

handle_info({inst_sync, done, Log}, #{ldb:=LDB,
                                      btable:=BTable
                                     }=State) ->
    stout:log(runsync, [ {node, nodekey:node_name()}, {where, inst} ]),
    lager:info("BC Sync done ~p", [Log]),
    lager:notice("Check block's keys"),
    {ok, C}=gen_server:call(ledger, {check, []}),
    lager:info("My Ledger hash ~s", [bin2hex:dbin2hex(C)]),
    #{header:=#{ledger_hash:=LH}}=Block=maps:get(syncblock, State),
    if LH==C ->
           lager:info("Sync done"),
           lager:notice("Verify settings"),
           CleanState=maps:without([sync, syncblock, syncpeer, syncsettings], State#{unksig=>0}),
       SS=maps:get(syncsettings, State),
           %self() ! runsync,
           save_block(LDB, Block, true),
           save_sets(LDB, SS),
           lastblock2ets(BTable, Block),
           {noreply, CleanState#{
                       settings=>chainsettings:settings_to_ets(SS),
                       lastblock=>Block,
                       candidates=>#{}
                      }
           };
       true ->
           lager:error("Sync failed, ledger hash mismatch"),
           {noreply, State}
    end;

handle_info({bbyb_sync, Hash},
            #{ sync:=bbyb,
               syncpeer:=Handler,
               sync_candidates:=Candidates} = State) ->
  flush_bbsync(),
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, bbsync} ]),
  lager:debug("run bbyb sync from hash: ~p", [blkid(Hash)]),
  case tpiccall(Handler,
                #{null=><<"pick_block">>, <<"hash">>=>Hash, <<"rel">>=>child},
                [block]
               ) of
    [{_, #{error:=Err}=R}] ->
      lager:error("No block part arrived (~p), broken sync ~p", [Err,R]),
      %%          erlang:send_after(10000, self(), runsync), % chainkeeper do that
      stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_no_block_part} ]),

      if(Err == <<"noblock">>) ->
          gen_server:cast(chainkeeper,
            {possible_fork, #{
              hash => Hash, % our hash which not found in current syncing peer
              mymeta => blockchain:last_meta()
            }});
        true ->
          ok
      end,
      {noreply,
       maps:without([sync, syncblock, syncpeer, sync_candidates], State#{
                              sync_candidates => skip_candidate(Candidates)
                             })
      };

    [{_, #{block:=BlockPart}=R}] ->
      lager:info("block found in received bbyb sync data ~p",[R]),
      try
        BinBlock = receive_block(Handler, BlockPart),
        #{hash:=NewH} = Block = block:unpack(BinBlock),
        %TODO Check parent of received block
        case block:verify(Block) of
          {true, _} ->
            gen_server:cast(self(), {new_block, Block, self()}),
            case maps:find(child, Block) of
              {ok, Child} ->
                self() ! {bbyb_sync, NewH},
                lager:info("block ~s have child ~s", [blkid(NewH), blkid(Child)]),
                {noreply, State};
              error ->
                %%                    erlang:send_after(1000, self(), runsync), % chainkeeper do that
                lager:info("block ~s no child, sync done?", [blkid(NewH)]),
                stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_no_child} ]),
                {noreply,
                 maps:without([sync, syncblock, syncpeer, sync_candidates],
                              State#{sync_candidates => skip_candidate(Candidates)})
                }
            end;
          false ->
            lager:error("Broken block ~s got from ~p. Sync stopped",
                        [blkid(NewH),
                         proplists:get_value(pubkey,
                                             maps:get(authdata, tpic:peer(Handler), [])
                                            )
                        ]),
            %%              erlang:send_after(10000, self(), runsync), % chainkeeper do that
            stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_broken_block} ]),

            {noreply,
             maps:without([sync, syncblock, syncpeer, sync_candidates],
                          State#{sync_candidates => skip_candidate(Candidates)})
            }
        end
      catch throw:broken_sync ->
              lager:notice("Broken sync"),
              stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_throw_broken_sync} ]),

              {noreply, maps:without([sync, syncblock, syncpeer, sync_candidates], State)}
      end;
    _ ->
      lager:error("bbyb no response"),
      %%      erlang:send_after(10000, self(), runsync),
      stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_no_response} ]),
      {noreply, maps:without(
                  [sync, syncblock, syncpeer, sync_candidates],
                  State#{
                    sync_candidates => skip_candidate(Candidates)
                   })
      }
  end;

handle_info(checksync, State) ->
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, checksync} ]),
  flush_checksync(),
%%  self() ! runsync,
  {noreply, State};

handle_info(checksync__, #{
        lastblock:=#{header:=#{height:=MyHeight}, hash:=_MyLastHash}
       }=State) ->
  Candidates=lists:reverse(
         tpiccall(<<"blockchain">>,
              #{null=><<"sync_request">>},
              [last_hash, last_height, chain]
             )),
  MS=getset(minsig,State),
  R=maps:filter(
    fun(_, Sources) ->
        Sources>=MS
    end,
    lists:foldl( %first suitable will be the quickest
      fun({_, #{chain:=_HisChain,
           last_hash:=Hash,
           last_height:=Heig,
           null:=<<"sync_available">>}
        }, Acc) when Heig>=MyHeight ->
          maps:put({Heig, Hash}, maps:get({Heig, Hash}, Acc, 0)+1, Acc);
       ({_, _}, Acc) ->
          Acc
      end, #{}, Candidates)
     ),
  case maps:size(R) > 0 of
    true ->
      lager:info("Looks like we laging behind ~p. Syncing", [R]),
      self() ! runsync;
    false ->
      ok
  end,
  {noreply, State};

handle_info(
  runsync,
  #{
    lastblock:=#{header:=#{height:=MyHeight0}, hash:=MyLastHash}
   } = State) ->
  MyHeight = case maps:get(tmpblock, State, undefined) of
               undefined -> MyHeight0;
               #{header:=#{height:=TmpHeight}} ->
                 TmpHeight
             end,
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, got_info} ]),
  lager:debug("got runsync, myHeight: ~p, myLastHash: ~p", [MyHeight, blkid(MyLastHash)]),

  GetDefaultCandidates =
  fun() ->
      lager:debug("use default list of candidates"),
      lists:reverse(
        tpiccall(<<"blockchain">>,
                 #{null=><<"sync_request">>},
                 [last_hash, last_height, chain, last_temp]
                ))
  end,

  Candidates =
  case maps:get(sync_candidates, State, default) of
    default ->
      GetDefaultCandidates();
    [] ->
      GetDefaultCandidates();
    SavedCandidates ->
      lager:debug("use saved list of candidates"),
      SavedCandidates
  end,

  handle_info({runsync, Candidates}, State);

handle_info(
  {runsync, Candidates},
  #{
    lastblock:=#{header:=#{height:=MyHeight0}, hash:=MyLastHash}
  } = State) ->
  flush_checksync(),

  MyHeight = case maps:get(tmpblock, State, undefined) of
               undefined -> MyHeight0;
               #{header:=#{height:=TmpHeight}} ->
                 TmpHeight
             end,

  Candidate=lists:foldl( %first suitable will be the quickest
              fun({CHandler, undefined}, undefined) ->
                  Inf=tpiccall(CHandler,
                               #{null=><<"sync_request">>},
                               [last_hash, last_height, chain, last_temp]
                              ),
                  case Inf of
                    {CHandler, #{chain:=_HisChain,
                                 last_hash:=_,
                                 last_height:=_,
                                 null:=<<"sync_available">>} = CInfo} ->
                      {CHandler, CInfo};
                    _ ->
                      undefined
                  end;
                 ({CHandler, #{chain:=_HisChain,
                               last_hash:=_,
                               last_height:=_,
                               null:=<<"sync_available">>} = CInfo}, undefined) ->
                  {CHandler, CInfo};
                 ({_, _}, undefined) ->
                  undefined;
                 ({_, _}, {AccH, AccI}) ->
                  {AccH, AccI}
              end,
              undefined,
              Candidates
             ),
  lager:info("runsync candidates: ~p", [proplists:get_keys(Candidates)]),
  case Candidate of
    undefined ->
      lager:notice("No candidates for sync."),
      {noreply, maps:without([sync, syncblock, syncpeer, sync_candidates], State#{unksig=>0})};

    {Handler,
     #{
       chain:=_Ch,
       last_hash:=_,
       last_height:=Height,
       last_temp:=Tmp,
       null:=<<"sync_available">>
      } = Info
    } ->
      lager:debug("chosen sync candidate info: ~p", [Info]),
      ByBlock = maps:get(<<"byblock">>, Info, false),
      Inst0 = maps:get(<<"instant">>, Info, false),
      Inst = case Inst0 of
               false ->
                 false;
               true ->
                 case application:get_env(tpnode, allow_instant) of
                   {ok, true} ->
                     lager:notice("Forced instant sync in config"),
                     true;
                   {ok, I} when is_integer(I) ->
                     Height - MyHeight >= I;
                   _ ->
                     lager:notice("Disabled instant syncin config"),
                     false
                 end
             end,
      MyTmp=case maps:find(tmpblock, State) of
              error -> false;
              {ok, #{temporary:=TmpNo}} -> TmpNo
            end,
      lager:info("Found candidate h=~w my ~w, bb ~s inst ~s/~s",
                 [Height, MyHeight, ByBlock, Inst0, Inst]),
      if (Height == MyHeight andalso Tmp == MyTmp) ->
           lager:info("Sync done, finish."),
           notify_settings(),
           {noreply,
            maps:without([sync, syncblock, syncpeer, sync_candidates], State#{unksig=>0})
           };
         Inst == true ->
           % try instant sync;
           gen_server:call(ledger, '_flush'),
           ledger_sync:run_target(tpic, Handler, ledger, undefined),
           {noreply, State#{
                       sync=>inst,
                       syncpeer=>Handler,
                       sync_candidates => Candidates
                      }};
         true ->
           %try block by block
           lager:error("RUN bbyb sync since ~s", [blkid(MyLastHash)]),
           self() ! {bbyb_sync, MyLastHash},
           {noreply, State#{
                       sync=>bbyb,
                       syncpeer=>Handler,
                       sync_candidates => Candidates
                      }}
      end
  end;

%begin of temporary code for debugging
handle_info(block2ets, #{btable:=BTable, tmpblock:=LB}=State) ->
  lastblock2ets(BTable, LB),
  {noreply, State};

handle_info(block2ets, #{btable:=BTable, lastblock:=LB}=State) ->
  lastblock2ets(BTable, LB),
  {noreply, State};
%end of temporary code

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
flush_bbsync() ->
  receive {bbyb_sync, _} ->
            flush_bbsync()
  after 0 ->
          done
  end.

flush_checksync() ->
  receive checksync ->
            flush_checksync();
          runsync ->
            flush_checksync()
  after 0 ->
          done
  end.


send_block(TPIC, PeerID, Map, Arr) ->
  spawn(?MODULE,send_block_real,[TPIC, PeerID, Map, Arr]),
  ok.

send_block_real(TPIC, PeerID, Map, [BlockHead]) ->
    tpic:cast(TPIC, PeerID, msgpack:pack(maps:merge(Map, #{block => BlockHead})));
send_block_real(TPIC, PeerID, Map, [BlockHead|BlockTail]) ->
    tpic:cast(TPIC, PeerID, msgpack:pack(maps:merge(Map, #{block => BlockHead}))),
    receive
        {'$gen_cast', {TPIC, PeerID, Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null := <<"pick_next_part">>}} ->
                    send_block_real(TPIC, PeerID, Map, BlockTail);
                {error, _} ->
                    error
            end;
        {'$gen_cast', Any} ->
            lager:info("Unexpected message ~p", [Any])
    after 30000 ->
        timeout
    end.

receive_block(Handler, BlockPart) ->
    receive_block(Handler, BlockPart, []).
receive_block(Handler, BlockPart, Acc) ->
    NewAcc = [BlockPart|Acc],
    <<Number:32, Length:32, _/binary>> = BlockPart,
    case length(NewAcc) of
        Length ->
            block:glue_packet(NewAcc);
        _ ->
            lager:debug("Received block part number ~p out of ~p", [Number, Length]),
            Response = tpiccall(Handler,  #{null => <<"pick_next_part">>}, [block]),
            lager:info("R ~p",[Response]),
            case Response of
              [{_, R}] ->
                #{block := NewBlockPart} = R,
                receive_block(Handler, NewBlockPart, NewAcc);
              [] ->
                lager:notice("Broken sync"),
                stout:log(runsync,
                  [
                    {node, nodekey:node_name()},
                    {error, broken_sync}
                  ]),
                
                throw('broken_sync')
            end
    end.

save_sets(ignore, _Settings) -> ok;
save_sets(LDB, Settings) ->
    ldb:put_key(LDB, <<"settings">>, erlang:term_to_binary(Settings)).

save_block(ignore, _Block, _IsLast) -> ok;
save_block(LDB, Block, IsLast) ->
    BlockHash=maps:get(hash, Block),
    ldb:put_key(LDB, <<"block:", BlockHash/binary>>, Block),
    if IsLast ->
           ldb:put_key(LDB, <<"lastblock">>, BlockHash);
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

apply_ledger(Action, #{bals:=S, hash:=BlockHash}) ->
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
    LR=ledger:Action(Patch, BlockHash),
    lager:info("Apply ~p", [LR]),
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


rewind(LDB, BlkNo) ->
  CurBlk=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),
  if(BlkNo<0) ->
      rewind(LDB, BlkNo-1, CurBlk);
    true ->
      rewind(LDB, BlkNo, CurBlk)
  end.

rewind(LDB, BlkNo, CurBlk) ->
    case ldb:read_key(LDB,
                      <<"block:", CurBlk/binary>>,
                      undefined
                     ) of
        undefined ->
            noblock;
      #{header:=#{}}=B when BlkNo == -1 ->
        B;
      #{header:=#{height:=H}}=B when BlkNo == H ->
        B;
      #{header:=#{parent:=Parent}} ->
        if BlkNo<0 ->
             rewind(LDB, BlkNo+1, Parent);
           BlkNo>=0 ->
             rewind(LDB, BlkNo, Parent)
        end
    end.


first_block(LDB, Next, Child) ->
    case ldb:read_key(LDB,
                      <<"block:", Next/binary>>,
                      undefined
                     ) of
        undefined ->
            lager:info("no_block before ~p", [Next]),
            noblock;
        #{header:=#{parent:=Parent}}=B ->
            BC=maps:get(child, B, undefined),
            lager:info("Block ~s child ~s",
                       [blkid(Next), BC]),
            if BC=/=Child ->
                   lager:info("Block ~s child ~p mismatch child ~s",
                              [blkid(Next), BC, blkid(Child)]),
                   save_block(LDB, B#{
                                    child=>Child
                                    }, false);
               true -> ok
            end,
            {ok, Parent};
        Block ->
            lager:info("Unknown block ~p", [Block])
    end.

get_first_block(LDB, Next) ->
    case ldb:read_key(LDB,
                      <<"block:", Next/binary>>,
                      undefined
                     ) of
        undefined ->
            lager:info("no_block before ~p", [Next]),
            noblock;
        #{header:=#{parent:=Parent}} ->
            if Parent == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
                   lager:info("First ~s", [ bin2hex:dbin2hex(Next) ]),
                   Next;
               true ->
                   lager:info("Block ~s parent ~s",
                              [blkid(Next), blkid(Parent)]),
                   get_first_block(LDB, Parent)
            end;
        Block ->
            lager:info("Unknown block ~p", [Block])
    end.

foldl(Fun, Acc0, LDB, BlkId) ->
    case ldb:read_key(LDB,
                      <<"block:", BlkId/binary>>,
                      undefined
                     ) of
        undefined ->
            Acc0;
       #{child:=Child}=Block ->
            try
                Acc1=Fun(Block, Acc0),
                foldl(Fun, Acc1, LDB, Child)
            catch throw:finish ->
                      Acc0
            end;
        Block ->
            try
                Fun(Block, Acc0)
            catch throw:finish ->
                      Acc0
            end
    end.

notify_settings() ->
    gen_server:cast(txpool, settings),
    gen_server:cast(txqueue, settings),
    gen_server:cast(mkblock, settings),
    gen_server:cast(blockvote, settings),
    gen_server:cast(synchronizer, settings),
    gen_server:cast(xchain_client, settings).

mychain(#{settings:=S}=State) ->
  KeyDB=maps:get(keys, S, #{}),
  NodeChain=maps:get(nodechain, S, #{}),
  PubKey=nodekey:get_pub(),
  %lager:info("My key ~s", [bin2hex:dbin2hex(PubKey)]),
  ChainNodes0=maps:fold(
                fun(Name, XPubKey, Acc) ->
                    maps:put(XPubKey, Name, Acc)
                end, #{}, KeyDB),
  MyName=maps:get(PubKey, ChainNodes0, undefined),
  MyChain=maps:get(MyName, NodeChain, 0),
  ChainNodes=maps:filter(
               fun(_PubKey, Name) ->
                   maps:get(Name, NodeChain, 0) == MyChain
               end, ChainNodes0),
  lager:info("My name ~p chain ~p ournodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
  ets:insert(?MODULE,[{myname,MyName},{chainnodes,ChainNodes},{mychain,MyChain}]),
  maps:merge(State,
             #{myname=>MyName,
               chainnodes=>ChainNodes,
               mychain=>MyChain
              }).

tpiccall(Handler, Object, Atoms) ->
    Res=tpic:call(tpic, Handler, msgpack:pack(Object)),
    lists:filtermap(
      fun({Peer, Bin}) ->
              case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
                  {ok, Decode} ->
                      {true, {Peer, Decode}};
                  _ -> false
              end
      end, Res).

getset(Name,#{settings:=Sets, mychain:=MyChain}=_State) ->
  chainsettings:get(Name, Sets, fun()->MyChain end).

sync_req(#{lastblock:=#{hash:=Hash, header:=#{height:=Height, parent:=Parent}} = LastBlock,
  mychain:=MyChain
} = State) ->
  BLB = block:pack(maps:with([hash, header, sign], LastBlock)),
  TmpBlock = maps:get(tmpblock, State, undefined),
  Ready=not maps:is_key(sync, State),
  Template =
    case TmpBlock of
      undefined ->
        #{last_height=>Height,
          last_hash=>Hash,
          last_temp=>false,
          tempblk=>false,
          lastblk=>BLB,
          prev_hash=>Parent,
          chain=>MyChain
        };
      #{hash:=TH,
        header:=#{height:=THei, parent:=TParent},
        temporary:=TmpNo} = Tmp ->
        #{last_height=>THei,
          last_hash=>TH,
          last_temp=>TmpNo,
          tempblk=>block:pack(Tmp),
          lastblk=>BLB,
          prev_hash=>TParent,
          chain=>MyChain
        }
    end,
  if not Ready -> %I am not ready
    Template#{
      null=><<"sync_unavailable">>,
      byblock=>false,
      instant=>false
    };
    true -> %I am working and could be source for sync
      Template#{
        null=><<"sync_available">>,
        byblock=>true,
        instant=>true
      }
  end.
  
backup(Dir) ->
  {ok,DBH}=gen_server:call(blockchain,get_dbh),
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

      ok=gen_server:call(blockchain,{new_block, Blk, self()}),
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

%% ------------------------------------------------------------------

% removes one sync candidate from the list of sync candidates
skip_candidate([])->
  [];

skip_candidate(default)->
  [];

skip_candidate(Candidates) when is_list(Candidates) ->
  tl(Candidates).

%% ------------------------------------------------------------------
