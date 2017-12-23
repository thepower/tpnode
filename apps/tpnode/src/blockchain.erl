-module(blockchain).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([get_settings/1,get_settings/2,get_settings/0,apply_block_conf/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    pg2:create(blockchain),
    pg2:join(blockchain,self()),
    NodeID=tpnode_tools:node_id(),
    {ok,LDB}=ldb:open("db_"++atom_to_list(node())),
    T2=load_bals(LDB),
    LastBlockHash=ldb:read_key(LDB,<<"lastblock">>,<<0,0,0,0,0,0,0,0>>),
    LastBlock=ldb:read_key(LDB,
                           <<"block:",LastBlockHash/binary>>,
                           genesis:genesis()
                           ),
    Conf=load_sets(LDB,LastBlock),
    lager:info("My last block hash ~s",
               [bin2hex:dbin2hex(LastBlockHash)]),
    #{mychain:=MyChain}=Res=mychain(#{
          table=>T2,
          nodeid=>NodeID,
          ldb=>LDB,
          candidates=>#{},
          settings=>Conf,
          lastblock=>LastBlock
         }),
    pg2:create({blockchain,MyChain}),
    pg2:join({blockchain,MyChain},self()),
    erlang:send_after(6000, self(), runsync),
    {ok, Res}.

handle_call(fix_tables, _From, #{ldb:=LDB,lastblock:=LB}=State) ->
    try
        First=get_first_block(LDB,
                              maps:get(hash,LB)
                             ),
        Res=foldl(fun(Block, #{table:=Bals,settings:=Sets}) ->
                          lager:info("Block@~b ~s ~p",
                                     [
                                      blkid(maps:get(hash,Block)),
                                      maps:keys(Block)
                                     ]),
                          %_Tx=maps:get(txs,Block),
                          Sets1=apply_block_conf(Block, Sets),
                          Bals1=apply_bals(Block, Bals),
                          #{table=>Bals1,settings=>Sets1} 
                  end, 
                  #{
                    table=>tables:init(#{index=>[address,cur]}),
                    settings=>settings:new()
                   }, LDB, First),
        notify_settings(),
        {reply, Res, mychain(maps:merge(State,Res))}
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              {reply, {error, Ec, Ee, S}, State}
    end;


handle_call(runsync, _From, State) ->
    State1=run_sync(State),
    {reply, sync, State1};

handle_call({get_addr, Addr, RCur}, _From, #{table:=Table}=State) ->
    case tables:lookup(address,Addr,Table) of
        {ok,E} ->
            {reply,
             lists:foldl(
               fun(#{cur:=Cur}=E1,_A) when Cur==RCur -> 
                       maps:with([amount,seq,t,lastblk,preblk],E1);
                  (_,A) ->
                       A
               end, 
               #{amount => 0,seq => 0,t => 0},
               E), State};
        _ ->
            {reply, not_found, State}
    end;

handle_call({get_addr, Addr}, _From, #{table:=Table}=State) ->
    case tables:lookup(address,Addr,Table) of
        {ok,E} ->
            {reply,
             lists:foldl(
               fun(#{cur:=Cur}=E1,A) -> 
                       maps:put(Cur,
                                maps:with([amount,seq,t,cur,lastblk,preblk],E1),
                                A)
               end, 
               #{},
               E), State};
        _ ->
            {reply, not_found, State}
    end;

handle_call(fix_first_block, _From, #{ldb:=LDB,lastblock:=LB}=State) ->
    lager:info("Find first block"),
    try
        Res=first_block(LDB,maps:get(parent,maps:get(header,LB)),maps:get(hash,LB)),
        {reply, Res, State}
    catch Ec:Ee ->
              {reply, {error, Ec, Ee}, State}
    end;


handle_call(loadbal, _, #{ldb:=LDB,table:=_T}=State) ->
    X=case ldb:read_key(LDB, <<"bals">>,
                   undefined
                  ) of 
          undefined ->
                   tables:init(#{index=>[address,cur]});
          Bin ->
              tables:import(Bin,
                            tables:init(#{index=>[address,cur]})
                           )
      end,

    {reply, X, State};


handle_call(last_block_height, _From, 
            #{mychain:=MC,lastblock:=#{header:=#{height:=H}}}=State) ->
    {reply, {MC,H}, State};

handle_call(last, _From, #{lastblock:=L}=State) ->
    {reply, maps:with([child,header,hash],L), State};

handle_call(last_block, _From, #{lastblock:=LB}=State) ->
    {reply, LB, State};

handle_call({get_block,BlockHash}, _From, #{ldb:=LDB,lastblock:=#{hash:=LBH}=LB}=State) ->
    %lager:debug("Get block ~p",[BlockHash]),
    Block=if BlockHash==last -> LB;
             BlockHash==LBH -> LB;
             true ->
                 ldb:read_key(LDB,
                              <<"block:",BlockHash/binary>>,
                              undefined)
          end,
    {reply, Block, State};


handle_call({mysettings, chain}, _From, State) ->
    #{mychain:=MyChain}=S1=mychain(State),
    {reply, MyChain, S1};

handle_call({mysettings, Attr}, _From, #{settings:=S}=State) ->
    #{mychain:=MyChain}=S1=mychain(State),
    Chains=maps:get(chain,S,#{}),
    Chain=maps:get(MyChain,Chains,#{}),
    {reply, maps:get(Attr,Chain,undefined), S1};

handle_call(settings, _From, #{settings:=S}=State) ->
    {reply, S, State};

handle_call({settings,Path}, _From, #{settings:=Settings}=State) ->
    Res=settings:get(Path,Settings),
    {reply, Res, State};

handle_call({settings,chain,ChainID}, _From, #{settings:=Settings}=State) ->
    Res=settings:get([chain,ChainID],Settings),
    {reply, Res, State};

handle_call({settings,signature}, _From, #{settings:=Settings}=State) ->
    Res=settings:get([keys],Settings),
    {reply, Res, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({new_block, _BlockPayload,  PID}, 
            #{ sync:=SyncPid }=State) when SyncPid=/=PID ->
    lager:info("Ignore block from ~p during sync with ~p",[PID,SyncPid]),
    {noreply, State};

handle_cast({tpic, Origin, #{null := <<"sync_block">>,
                             <<"block">> := BinBlock}},
            #{sync:=SyncOrigin }=State) when Origin==SyncOrigin ->
    Blk=block:unpack(BinBlock),
    handle_cast({new_block, Blk, Origin}, State);


handle_cast({new_block, #{hash:=BlockHash}=Blk, _PID}, 
            #{ldb:=LDB,
              lastblock:=#{hash:=PBlockHash}=PBlk
             }=State) when BlockHash==PBlockHash ->
    lager:info("Arrived block from ~p Verify block with ~p",
               [_PID,maps:keys(Blk)]),
    {true,{Success,_}}=block:verify(Blk),
    lager:info("Extra confirmation of prev. block ~s ~w",
               [blkid(BlockHash),length(Success)]),
    NewPBlk=case length(Success)>0 of
                true ->
                    OldSigs=maps:get(sign,PBlk),
                    NewSigs=lists:usort(OldSigs++Success),
                    if(OldSigs=/=NewSigs) ->
                          lager:info("Extra confirm Sig changed ~p",
                                    [length(NewSigs)]),
                          PBlk1=PBlk#{sign=>NewSigs},
                          save_block(LDB,PBlk1,false),
                          PBlk1;
                      true -> 
                          lager:info("Extra confirm not changed ~w/~w",
                                    [length(OldSigs),length(NewSigs)]),
                          PBlk
                    end;
                _ -> PBlk
            end,
    {noreply, State#{lastblock=>NewPBlk}};

handle_cast({new_block, #{hash:=BlockHash}=Blk, PID}=_Message, 
            #{candidates:=Candidates,ldb:=LDB0,
              lastblock:=#{header:=#{parent:=Parent},hash:=LBlockHash}=LastBlock,
              settings:=Sets,
              mychain:=MyChain,
              table:=Tbl}=State) ->
    FromNode=if is_pid(PID) -> node(PID);
                is_tuple(PID) -> PID;
                true -> emulator
             end,


    lager:info("Arrived block from ~p Verify block with ~p",
               [FromNode,maps:keys(Blk)]),

    lager:info("New block (~p/~p) hash ~s (~s/~s)", 
               [
                maps:get(height,maps:get(header,Blk)),
                maps:get(height,maps:get(header,LastBlock)),
                blkid(BlockHash),
                blkid(Parent),
                blkid(LBlockHash)
               ]),
    Chains=maps:get(chain,Sets,#{}),
    Chain=maps:get(MyChain,Chains,#{}),
    MinSig=maps:get(minsig,Chain,2),

    try
        LDB=if is_pid(PID) -> LDB0;
               is_tuple(PID) -> LDB0;
               true -> ignore
            end,

        T0=erlang:system_time(),
        case block:verify(Blk) of 
            false ->
                T1=erlang:system_time(),
                file:write_file("bad_block_"++integer_to_list(maps:get(height,maps:get(header,Blk)))++".txt", io_lib:format("~p.~n", [Blk])),
                lager:info("Got bad block from ~p New block ~w arrived ~s, verify (~.3f ms)", 
                   [FromNode,maps:get(height,maps:get(header,Blk)),
                    blkid(BlockHash),(T1-T0)/1000000]),
                throw(ignore);
            {true,{Success,_}} ->
                T1=erlang:system_time(),
                Txs=maps:get(txs,Blk,[]),
                lager:info("from ~p New block ~w arrived ~s, txs ~b, verify (~.3f ms)", 
                           [FromNode,maps:get(height,maps:get(header,Blk)),
                            blkid(BlockHash),length(Txs),(T1-T0)/1000000]),
                if length(Success)>0 ->
                       ok;
                   true ->
                       throw(ingore)
                end,
                MBlk=case maps:get(BlockHash,Candidates,undefined) of
                         undefined ->
                             Blk;
                         #{sign:=BSig}=ExBlk ->
                             NewSigs=lists:usort(BSig++Success),
                             ExBlk#{
                               sign=>NewSigs
                              }
                     end,
                SigLen=length(maps:get(sign,MBlk)),
                %lager:info("Signs ~b",[SigLen]),
                if SigLen>=MinSig %andalso BlockHash==LBlockHash 
                   ->
                       %enough signs. Make block.
                       NewTable=apply_bals(MBlk, Tbl),
                       Sets1=apply_block_conf(MBlk, Sets),

                       if Txs==[] -> ok;
                          true -> 
                              lager:info("Txs ~p", [ Txs ])
                       end,
                       NewPHash=maps:get(parent,maps:get(header,Blk)),


                       if LBlockHash=/=NewPHash ->
                              lager:info("Need resynchronize, height ~p/~p new block parent ~s, but my ~s",
                                         [
                                          maps:get(height,maps:get(header,Blk)),
                                          maps:get(height,maps:get(header,LastBlock)),
                                          blkid(NewPHash),
                                          blkid(LBlockHash)
                                         ]),
                              {noreply, (State#{ %run_sync
                                                   candidates=>#{}
                                                  })
                              };
                          true ->
                              %normal block installation

                              NewLastBlock=LastBlock#{
                                             child=>BlockHash
                                            },
                              T2=erlang:system_time(),

                              save_block(LDB,NewLastBlock,false),
                              save_block(LDB,MBlk,true),
                              case maps:is_key(sync,State) of
                                  true ->
                                      ok;
                                  false ->
                                      gen_server:cast(txpool,{done,proplists:get_keys(Txs)}),
                                      case maps:is_key(inbound_blocks,MBlk) of
                                          true ->
                                              lager:info("IB"),
                                              gen_server:cast(txpool,{done,proplists:get_keys(maps:get(inbound_blocks,MBlk))});
                                          false -> 
                                              lager:info("NO IB"),
                                              ok
                                      end,

                                      if(NewTable =/= Tbl) ->
                                            save_bals(LDB, NewTable);
                                        true -> ok
                                      end,
                                      if(Sets1 =/= Sets) ->
                                            notify_settings(),
                                            save_sets(LDB, Sets1);
                                        true -> ok
                                      end
                              end,
                              Settings=maps:get(settings,MBlk,[]),
                              gen_server:cast(txpool,{done,proplists:get_keys(Settings)}),

                              T3=erlang:system_time(),
                              lager:info("enough confirmations. Installing new block ~s h= ~b (~.3f ms)/(~.3f ms)",
                                         [blkid(BlockHash),
                                          maps:get(height,maps:get(header,Blk)),
                                          (T3-T2)/1000000,
                                          (T3-T0)/1000000
                                         ]),

                              gen_server:cast(tpnode_ws_dispatcher,{new_block, MBlk}),

                              Outbound=maps:get(outbound,MBlk,[]),
                              if length(Outbound)>0 ->
                                     maps:fold(
                                       fun(ChainId,OutBlock,_) ->
                                               %Dst=pg2:get_members({txpool,ChainId}),
                                               Dst=[],
                                               lager:info("Out to ~b(~p) ~p",
                                                          [ChainId,Dst,OutBlock]),
                                               lists:foreach(
                                                 fun(Pool) ->
                                                         gen_server:cast(Pool,
                                                                         {inbound_block,OutBlock})
                                                 end, Dst)
                                       end,0, block:outward_mk(Outbound,MBlk));
                                 true -> ok
                              end,

                              {noreply, State#{
                                          prevblock=> NewLastBlock,
                                          lastblock=> MBlk,
                                          table=>NewTable,
                                          settings=>Sets1,
                                          candidates=>#{}
                                         }
                              }

                       end;
                   true ->
                       %not enough
                       {noreply, State#{
                                   candidates=>
                                   maps:put(BlockHash,
                                            MBlk,
                                            Candidates)
                                  }
                       }
                end
        end
    catch throw:ignore ->
              {noreply, State};
          Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:error("BC new_block error ~p:~p",[Ec,Ee]),
              lists:foreach(
                fun(Se) ->
                        lager:error("at ~p",[Se])
                end, S),
              {noreply, State}
    end;

handle_cast({tpic,Peer,#{null := <<"sync_done">>}},
            #{ldb:=LDB, settings:=Set, table:=Tbl,
              sync:=SyncPeer}=State) when Peer==SyncPeer ->
    save_bals(LDB, Tbl),
    save_sets(LDB, Set),
    gen_server:cast(blockvote, blockchain_sync),
    notify_settings(),
    {noreply, maps:remove(sync,State)};

handle_cast({tpic,Peer,#{null := <<"continue_sync">>,
                         <<"block">> := BlkId,
                         <<"cnt">> := NextB}}, #{ldb:=LDB}=State) ->
    lager:info("SYNCout from ~s to ~p",[blkid(BlkId),Peer]),
    case ldb:read_key(LDB, <<"block:",BlkId/binary>>, undefined) of
        undefined ->
            lager:info("SYNC done at ~s",[blkid(BlkId)]),
            tpic:cast(tpic,Peer,msgpack:pack(#{null=><<"sync_done">>}));
        #{header:=#{},child:=Child}=_Block ->
            lager:info("SYNC next block ~s to ~p",[blkid(Child),Peer]),
            handle_cast({continue_syncc, Child, Peer, NextB}, State);
        #{header:=#{}}=Block ->
            lager:info("SYNC last block ~p to ~p",[Block,Peer]),
            tpic:cast(tpic,Peer,msgpack:pack(#{null=><<"sync_block">>,
                                              block=>block:pack(Block)})),
            tpic:cast(tpic,Peer,msgpack:pack(#{null=><<"sync_done">>}))
    end,
    {noreply, State};


handle_cast({continue_syncc, BlkId, Peer, NextB}, #{ldb:=LDB,
                                                   lastblock:=#{hash:=LastHash}=LastBlock
                                                  }=State) ->
    case ldb:read_key(LDB, <<"block:",BlkId/binary>>, undefined) of
        _ when BlkId == LastHash ->
            lager:info("SYNCC last block ~s from state",[blkid(BlkId)]),
            tpic:cast(tpic,Peer,msgpack:pack(
                                  #{null=><<"sync_block">>,
                                    block=>block:pack(LastBlock)})),
            tpic:cast(tpic,Peer,msgpack:pack(
                                  #{null=><<"sync_done">>}));
        undefined ->
            lager:info("SYNCC done at ~s",[blkid(BlkId)]),
            tpic:cast(tpic,Peer,msgpack:pack(
                                  #{null=><<"sync_done">>}));
        #{header:=#{height:=H},child:=Child}=Block ->
            P=msgpack:pack(
                #{null=><<"sync_block">>,
                  block=>block:pack(Block)}),
            lager:info("SYNCC send block ~w ~s ~w bytes to ~p",
                       [H,blkid(BlkId),size(P),Peer]),
            tpic:cast(tpic,Peer,P),

            if NextB > 1 ->
                   gen_server:cast(self(),{continue_syncc,Child,Peer, NextB-1});
               true ->
                   lager:info("SYNCC pause ~p",[BlkId]),
                   tpic:cast(tpic,Peer,msgpack:pack(
                                         #{null=><<"sync_suspend">>,
                                           <<"block">>=>BlkId}))
            end;
        #{header:=#{}}=Block ->
            lager:info("SYNCC last block at ~s",[blkid(BlkId)]),
            tpic:cast(tpic,Peer,msgpack:pack(
                                  #{null=><<"sync_block">>,
                                    block=>block:pack(Block)})),
            if (BlkId==LastHash) ->
                   lager:info("SYNC Real last");
               true ->
                   lager:info("SYNC Not really last")
            end,
            tpic:cast(tpic,Peer,msgpack:pack(#{null=><<"sync_done">>}))
    end,
    {noreply, State};

handle_cast({tpic,Peer,#{null := <<"sync_suspend">>,
                         <<"block">> := BlkId}}, 
            #{ sync:=SyncPeer,
               lastblock:=#{hash:=LastHash}=LastBlock
             }=State) when SyncPeer==Peer ->
    lager:info("Sync suspend ~s, my ~s",[blkid(BlkId),blkid(LastHash)]),
    lager:info("MyLastBlock ~p",[maps:get(header,LastBlock)]),
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

handle_cast({tpic,Peer,#{null := <<"sync_suspend">>,
                         <<"block">> := _BlkId}}, State) ->
    lager:info("sync_suspend from bad peer ~p",[Peer]),
    {noreply, State};


handle_cast(savebal,#{ldb:=LDB,table:=T}=State) ->
    save_bals(LDB,T),
    {noreply, State};

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin,[]) of
        {ok, Struct} ->
            lager:info("Inbound TPIC ~p",[maps:get(null,Struct)]),
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            lager:info("Can't decode  TPIC ~p",[_Any]),
            lager:info("TPIC ~p",[Bin]),
            {noreply, State}
    end;

handle_cast({tpic, From, #{
                     null:=<<"tail">>
                    }}, 
            #{mychain:=MC,lastblock:=#{header:=#{height:=H},
                                      hash:=Hash }}=State) ->
    tpic:cast(tpic, From, msgpack:pack(#{null=><<"response">>,
                                                         mychain=>MC,
                                                         height=>H,
                                                         hash=>Hash
                                                        })),
    {noreply, State};


handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p",[_Msg]),
    file:write_file("unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
    file:write_file("unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
    {noreply, State}.

handle_info(runsync, State) ->
    State1=run_sync(State),
    {noreply, State1};

handle_info(_Info, State) ->
    lager:info("BC unhandled info ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("Terminate blockchain ~p",[_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

save_bals(ignore, _Table) -> ok;
save_bals(LDB, Table) ->
    TD=tables:export(Table),
    ldb:put_key(LDB,<<"bals">>,TD).

save_sets(ignore, _Settings) -> ok;
save_sets(LDB, Settings) ->
    ldb:put_key(LDB,<<"settings">>,erlang:term_to_binary(Settings)).

save_block(ignore,_Block,_IsLast) -> ok;
save_block(LDB,Block,IsLast) ->
    BlockHash=maps:get(hash,Block),
    ldb:put_key(LDB,<<"block:",BlockHash/binary>>,Block),
    if IsLast ->
           ldb:put_key(LDB,<<"lastblock">>,BlockHash);
       true ->
           ok
    end.

load_bals(LDB) ->
    case ldb:read_key(LDB, <<"bals">>, undefined) of 
        undefined ->
            tables:init(#{index=>[address,cur]});
        Bin ->
            tables:import(Bin,
                          tables:init(#{index=>[address,cur]})
                         )
    end.

load_sets(LDB,LastBlock) ->
    case ldb:read_key(LDB, <<"settings">>, undefined) of 
        undefined ->
            apply_block_conf(LastBlock, settings:new());
        Bin ->
            binary_to_term(Bin)
    end.

apply_bals(#{bals:=S, hash:=BlockHash}, Bals0) ->
    maps:fold(
      fun(Addr,#{chain:=_NewChain},Acc) ->

              case tables:lookup(address,Addr,Acc) of
                  {ok,E} ->
                      lists:foldl(
                        fun(#{'_id':=RecID},A) -> 
                                {ok,A1}=tables:delete('_id',RecID,A),
                                A1
                        end, 
                        Acc,
                        E);
                  _ ->
                      Acc
              end;
         ({Addr,Cur},Val,Acc) ->
              updatebal(Addr,Cur,Val,Acc,BlockHash)
      end, Bals0, S).

apply_block_conf(Block, Conf0) ->
    S=maps:get(settings,Block,[]),
    lists:foldl(
      fun({_TxID,#{patch:=Body}},Acc) when is_binary(Body) ->
              lager:notice("TODO: Must check sigs"),
              %Hash=crypto:hash(sha256,Body),
              settings:patch(Body,Acc)
      end, Conf0, S).


addrbal(Addr, RCur, Table) ->
    case tables:lookup(address,Addr,Table) of
        {ok,E} ->
            lists:foldl(
              fun(#{cur:=Cur}=E1,_A) when Cur==RCur -> 
                      E1;
                 (_,A) ->
                      A
              end, 
              none,
              E);
        _ ->
            none
    end.

updatebal(Addr, RCur, NewVal, Table, BlockHash) ->
    case addrbal(Addr, RCur, Table) of
        none -> 
            {ok,_,T2}=tables:insert(
                        maps:put(
                          lastblk,
                          BlockHash,
                          maps:merge(
                            #{
                            address=>Addr,
                            cur=>RCur,
                            amount=>0,
                            t=>0,
                            seq=>0
                           },NewVal)
                         ), Table),
            T2;
        #{'_id':=EID}=Exists -> 
            {ok, T2}=tables:update('_id',EID,
                                   maps:put(
                                     lastblk,
                                     BlockHash,
                                     maps:merge(Exists,NewVal)
                                  ),Table),
            T2
    end.

blkid(<<X:8/binary,_/binary>>) ->
    bin2hex:dbin2hex(X).

first_block(LDB, Next, Child) ->
    case ldb:read_key(LDB,
                      <<"block:",Next/binary>>,
                      undefined
                     ) of
        undefined ->
            lager:info("no_block before ~p",[Next]),
            noblock; 
        #{header:=#{parent:=Parent}}=B ->
            BC=maps:get(child,B,undefined),
            lager:info("Block ~s child ~s",
                       [blkid(Next),BC]),
            if BC=/=Child ->
                   lager:info("Block ~s child ~p mismatch child ~s",
                              [blkid(Next),BC,blkid(Child)]),
                   save_block(LDB,B#{
                                    child=>Child
                                    },false);
               true -> ok
            end,
            %if Parent == <<0,0,0,0,0,0,0,0>> ->
            %       First=ldb:read_key(LDB,
            %                          <<"block:",0,0,0,0,0,0,0,0>>,
            %                          undefined
            %                         ),
            %       save_block(LDB,First#{
            %                        child=>Next
            %                       },false),
            %       lager:info("First ~p",[ Next ]),
            %       {fix,Next};
            %   true ->
            %       first_block(LDB, Parent, Next)
            %end
            {ok,Parent}
                   ;
        Block ->
            lager:info("Unknown block ~p",[Block])
    end.

get_first_block(LDB, Next) ->
    case ldb:read_key(LDB,
                      <<"block:",Next/binary>>,
                      undefined
                     ) of
        undefined ->
            lager:info("no_block before ~p",[Next]),
            noblock; 
        #{header:=#{parent:=Parent}} ->
            if Parent == <<0,0,0,0,0,0,0,0>> ->
                   lager:info("First ~s",[ bin2hex:dbin2hex(Next) ]),
                   Next;
               true ->
                   lager:info("Block ~s parent ~s",
                              [blkid(Next),blkid(Parent)]),
                   get_first_block(LDB, Parent)
            end;
        Block ->
            lager:info("Unknown block ~p",[Block])
    end.

sync_candidate(#{mychain:=MyChain,lastblock:=#{header:=#{height:=H}}}=_State) ->
    CAs=tpic:call(tpic,<<"blockchain">>,msgpack:pack(#{null=>tail})),
    CA=lists:filtermap(
         fun({Origin,Bin}) ->
                 case msgpack:unpack(Bin) of
                     {ok, Payload} -> {true, {Origin,Payload}};
                     _ -> false
                 end
         end, CAs),
    lists:foldl(
      fun({Handler,#{null:=<<"response">>,
                     %<<"hash">> := Hash,
                     <<"height">> := Height,
                     <<"mychain">> := Chain
                    }=_A},{_LPid,LH}) when Chain==MyChain andalso Height>LH ->
              {Handler, Height};
         (_A,Acc) ->
              lager:info("Non candidate ~p",[_A]),
              Acc
      end, {undefined, H}, CA).


run_sync(#{mychain:=MyChain,lastblock:=#{hash:=LastBlockId}}=State) ->
    #{mychain:=MyChain}=S1=mychain(State),
    Candidate=sync_candidate(State),
    case Candidate of
        {undefined, _} ->
            notify_settings(),
            lager:info("Nobody here, nothing to sync",[]),
            S1;
        {Peer,MaxH} ->
            lager:info("Sync with ~p height ~p from block ~s",
                       [Peer,MaxH,blkid(LastBlockId)]),
            tpic:cast(tpic, Peer, msgpack:pack(#{
                                    null=><<"continue_sync">>, 
                                    <<"block">>=>LastBlockId,  
                                    <<"cnt">>=>2})),
            S1#{
              sync=>Peer
             }
    end.

foldl(Fun, Acc0, LDB, BlkId) ->
    case ldb:read_key(LDB,
                      <<"block:",BlkId/binary>>,
                      undefined
                     ) of
        undefined ->
            Acc0;
       #{child:=Child}=Block -> 
            try 
                Acc1=Fun(Block, Acc0),
                foldl(Fun,Acc1,LDB,Child)
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

get_settings() ->
    gen_server:call(blockchain,settings).

get_settings(P) ->
    gen_server:call(blockchain,{settings,P}).


get_settings(blocktime,Default) ->
    case gen_server:call(blockchain,{mysettings,blocktime}) of 
        undefined -> Default;
        Any when is_integer(Any) -> Any;
        _ -> Default
    end;

get_settings(Param, Default) ->
    case gen_server:call(blockchain,{mysettings,Param}) of 
        undefined -> Default;
        Any -> Any
    end.

notify_settings() ->
    gen_server:cast(txpool,settings),
    gen_server:cast(mkblock,settings),
    gen_server:cast(blockvote,settings),
    gen_server:cast(synchronizer,settings).

mychain(#{settings:=S}=State) ->
    KeyDB=maps:get(keys,S,#{}),
    NodeChain=maps:get(nodechain,S,#{}),
    {ok,K1}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(K1),
    PubKey=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
    lager:info("My key ~s",[bin2hex:dbin2hex(PubKey)]),
    MyName=maps:fold(
             fun(K,V,undefined) ->
                     lager:info("Compare ~p with ~p",
                                [V,PubKey]),
                     if V==PubKey ->
                            K;
                        true ->
                            undefined
                     end;
                (_,_,Found) ->
                     Found
             end, undefined, KeyDB),
    MyChain=maps:get(MyName,NodeChain,0),
    lager:info("My name ~p chain ~p",[MyName,MyChain]),
    maps:merge(State,
               #{myname=>MyName,
                 mychain=>MyChain
                }).



