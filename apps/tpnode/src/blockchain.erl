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
    {ok, run_sync(Res)}.

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
    {reply, State1, State1};

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
    lager:info("Ignore block from ~p ~p during sync with ~p ~p",[node(PID),PID,node(SyncPid),SyncPid]),
    {noreply, State};

handle_cast({new_block, #{hash:=BlockHash}=Blk, _PID}, 
            #{ldb:=LDB,
              lastblock:=#{hash:=PBlockHash}=PBlk
             }=State) when BlockHash==PBlockHash ->
    lager:info("Arrived block from ~p Verify block with ~p",
               [node(_PID),maps:keys(Blk)]),
    {true,{Success,_}}=block:verify(Blk),
    lager:info("Extra confirmation of prev. block ~s ~w",
               [blkid(BlockHash),length(Success)]),
    NewPBlk=case length(Success)>0 of
                true ->
                    OldSigs=maps:get(sign,PBlk),
                    NewSigs=lists:usort(OldSigs++Success),
                    lager:info("from ~s Extra len ~p",
                               [node(),length(NewSigs)
                               ]),
                    if(OldSigs=/=NewSigs) ->
                          lager:info("~s Extra confirm Sig changed ~p",
                                    [node(),length(NewSigs)]),
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

handle_cast({new_block, Blk}, State) ->
    lager:info("Upgrade legacy block"),
    handle_cast({new_block, Blk, self()}, State);

handle_cast({new_block, #{hash:=BlockHash}=Blk, PID}=_Message, 
            #{candidates:=Candidates,ldb:=LDB0,
              lastblock:=#{header:=#{parent:=Parent},hash:=LBlockHash}=LastBlock,
              settings:=Sets,
              mychain:=MyChain,
              table:=Tbl}=State) ->
    FromNode=if is_pid(PID) -> node(PID);
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
               true -> ignore
            end,



%        file:write_file("new_block.txt",
%                        io_lib:format("~p.~n~p.~n",
%                                      [_Message,
%                                       State])),
        T0=erlang:system_time(),
        {true,{Success,_}}=block:verify(Blk),
        T1=erlang:system_time(),
        Txs=maps:get(txs,Blk,[]),
        lager:info("~s from ~s New block ~w arrived ~s, txs ~b, verify (~.3f ms)", 
                   [node(),FromNode,maps:get(height,maps:get(header,Blk)),
                    blkid(BlockHash),length(Txs),(T1-T0)/1000000]),
        if length(Success)>0 ->
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
                            {noreply, run_sync(State#{
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
                                             Dst=pg2:get_members({txpool,ChainId}),
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
               end;
           true ->
               {noreply, State}
        end
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:error("BC new_block error ~p:~p",[Ec,Ee]),
              lists:foreach(
                fun(Se) ->
                     lager:error("at ~p",[Se])
                end, S),
              {noreply, State}
    end;

handle_cast({sync, done, _Pid}, #{ldb:=LDB, settings:=Set, table:=Tbl}=State) ->
    save_bals(LDB, Tbl),
    save_sets(LDB, Set),
    gen_server:cast(blockvote, blockchain_sync),
    notify_settings(),
    {noreply, maps:remove(sync,State)};

handle_cast({continue_sync, BlkId, PID, NextB}, #{ldb:=LDB}=State) ->
    lager:info("SYNCout from ~s to ~p",[blkid(BlkId),node(PID)]),
    case ldb:read_key(LDB, <<"block:",BlkId/binary>>, undefined) of
        undefined ->
            lager:info("SYNC done at ~s",[blkid(BlkId)]),
            gen_server:cast(PID,{sync, done, self()});
        #{header:=#{},child:=Child}=_Block ->
            lager:info("SYNC next block ~s to ~p",[blkid(Child),node(PID)]),
            handle_cast({continue_syncc, Child, PID, NextB}, State);
        #{header:=#{}}=Block ->
            lager:info("SYNC last block ~p to ~p",[Block,node(PID)]),
            gen_server:cast(PID,{new_block,Block, self()}),
            gen_server:cast(PID,{sync, done, self()})
    end,
    {noreply, State};


handle_cast({continue_syncc, BlkId, PID, NextB}, #{ldb:=LDB,
                                                   lastblock:=#{hash:=LastHash}=LastBlock
                                                  }=State) ->
    case ldb:read_key(LDB, <<"block:",BlkId/binary>>, undefined) of
        _ when BlkId == LastHash ->
            lager:info("SYNCC last block ~s from state",[blkid(BlkId)]),
            gen_server:cast(PID,{new_block, LastBlock, self()}),
            gen_server:cast(PID,{sync, done, self()});
        undefined ->
            lager:info("SYNCC done at ~s",[blkid(BlkId)]),
            gen_server:cast(PID,{sync, done, self()});
        #{header:=#{},child:=Child}=Block ->
            lager:info("SYNCC next block ~p to ~p",[Block,node(PID)]),
            gen_server:cast(PID,{new_block,Block, self()}),
            if NextB > 0 ->
                   gen_server:cast(self(),{continue_syncc,Child,PID, NextB-1});
               true ->
                   lager:info("SYNCC pause ~p",[BlkId]),
                   gen_server:cast(PID,{sync,suspend,BlkId, self()})
            end;
        #{header:=#{}}=Block ->
            lager:info("SYNCC last block at ~s",[blkid(BlkId)]),
            gen_server:cast(PID,{new_block,Block, self()}),
            if (BlkId==LastHash) ->
                   lager:info("SYNC Real last");
               true ->
                   lager:info("SYNC Not really last")
            end,
            gen_server:cast(PID,{sync, done, self()})
    end,
    {noreply, State};

handle_cast({sync,suspend, BlkId, Pid}, #{
                                    sync:=SyncPid,
                                    lastblock:=#{hash:=LastHash}=LastBlock
                                   }=State) when SyncPid==Pid ->
    lager:info("Sync suspend ~s, my ~s",[blkid(BlkId),blkid(LastHash)]),
    lager:info("MyLastBlock ~p",[maps:get(header,LastBlock)]),
    if(BlkId == LastHash) ->
          lager:info("Last block matched, continue sync"),
          gen_server:cast(SyncPid,{continue_sync, LastHash, self(), 2}),
          {noreply, State};
      true ->
          lager:info("SYNC ERROR"),
%          {noreply, run_sync(State)}
          {noreply, State}
    end;

handle_cast(savebal,#{ldb:=LDB,table:=T}=State) ->
    save_bals(LDB,T),
    {noreply, State};

handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p",[_Msg]),
    file:write_file("unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
    file:write_file("unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
    {noreply, State}.

handle_info(_Info, State) ->
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

run_sync(#{mychain:=MyChain,lastblock:=#{hash:=LastBlockId}}=State) ->
    #{mychain:=MyChain}=S1=mychain(State),
    Peers=pg2:get_members(blockchain)--[self()],
    case lists:reverse(
           lists:keysort(1,
                         lists:foldl(
                           fun(Pid,Acc) ->
                                   try
                                       {HC,H}=gen_server:call(Pid,last_block_height),
                                       lager:info("Node ~s chain ~p (my ~p) height ~p",
                                                  [node(Pid),HC,MyChain,H]),
                                       if(HC==MyChain) ->
                                             [{H,Pid}|Acc];
                                         true ->
                                             Acc
                                       end
                                   catch _:_ -> Acc
                                   end
                           end,[], Peers
                          )
                        )
          ) of
        [{MaxH,MaxPID}|_] ->
            lager:info("Sync with ~p height ~p from block ~s",
                       [node(MaxPID),MaxH,blkid(LastBlockId)]),
            gen_server:cast(MaxPID,{continue_sync, LastBlockId, self(), 2}),
            S1#{
              sync=>MaxPID
             };
        [] ->
            notify_settings(),
            lager:info("Nobody here, nothing to sync",[]),
            S1
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



