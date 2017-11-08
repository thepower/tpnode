-module(blockchain).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

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
    {ok,LDB}=ldb:open("db_"++binary_to_list(tpnode_tools:node_id())),
    T2=load_bals(LDB),
    LastBlockHash=ldb:read_key(LDB,<<"lastblock">>,<<0,0,0,0,0,0,0,0>>),
    LastBlock=ldb:read_key(LDB,
                           <<"block:",LastBlockHash/binary>>,
                           #{ hash=><<0,0,0,0,0,0,0,0>>,
                              header=>#{
                                height=>0
                               }
                            }),
    gen_server:cast(self(),synchronize),
    Res=#{
      table=>T2,
      nodeid=>NodeID,
      ldb=>LDB,
      candidates=>#{},
      lastblock=>LastBlock
     },
    {ok, Res}.

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


handle_call({synchronize, BlkId, PID}, _From, #{ldb:=LDB}=State) ->
    lager:info("SYNC: request from ~p block ~s",[node(PID),blkid(BlkId)]),
    case ldb:read_key(LDB,
                 <<"block:",BlkId/binary>>,
                 undefined
                ) of
        undefined ->
            lager:info("no_block ~p",[BlkId]),
            {reply, noblock, State};
        #{header:=#{},child:=Child}=Block ->
            lager:info("send block ~p to ~p",[BlkId,node(PID)]),
            gen_server:cast(self(),{continue_sync,Child,PID}),
            {reply, {start, Block}, State};
        #{header:=#{}}=Block ->
            lager:info("last block ~p",[maps:get(header,Block)]),
            {reply, {last, Block}, State}
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


handle_call(last_block_height, _From, #{lastblock:=#{header:=#{height:=H}}}=State) ->
    {reply, H, State};

handle_call(last_block, _From, #{lastblock:=LB}=State) ->
    {reply, LB, State};

handle_call({get_block,BlockHash}, _From, #{ldb:=LDB,lastblock:=LB}=State) ->
    Block=if BlockHash==last -> LB;
             true ->
                 ldb:read_key(LDB,
                              <<"block:",BlockHash/binary>>,
                              undefined)
          end,
    {reply, Block, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({new_block, #{hash:=BlockHash}=Blk, _PID}, 
            #{ldb:=LDB,
              lastblock:=#{hash:=PBlockHash}=PBlk
             }=State) when BlockHash==PBlockHash ->
    {true,{Success,_}}=mkblock:verify(Blk),
    lager:info("Extra confirmation of prev. block ~s ~w",
               [blkid(BlockHash),length(Success)]),
    NewPBlk=case length(Success)>0 of
                true ->
                    OldSigs=maps:get(sign,PBlk),
                    NewSigs=lists:usort(OldSigs++Success),
                    MapFun=fun({H1,_}) -> erlang:crc32(H1) end,
                    lager:info("from ~s Extra len ~p, ~p ~p",
                               [node(),length(NewSigs),
                               lists:map(MapFun,OldSigs),
                               lists:map(MapFun,Success)
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
    handle_cast({new_block, Blk, self()}, State);

handle_cast({sync, done}, #{ldb:=LDB, table:=Tbl}=State) ->
    save_bals(LDB, Tbl),
    {noreply, maps:remove(sync,State)};

handle_cast({new_block, #{hash:=BlockHash}=Blk, PID}, 
            #{candidates:=Candidates,ldb:=LDB,
              lastblock:=#{hash:=LBlockHash}=LastBlock,
              table:=Tbl}=State) ->

    lager:info("New block (~p/~p) arrived (~s/~s)", 
               [
                maps:get(height,maps:get(header,Blk)),
                maps:get(height,maps:get(header,LastBlock)),
                blkid(BlockHash),
                blkid(LBlockHash)
               ]),
    MinSig=2,
    try
        T0=erlang:system_time(),
        {true,{Success,_}}=mkblock:verify(Blk),
        T1=erlang:system_time(),
        Txs=maps:get(txs,Blk,[]),
        lager:info("~s from ~s New block ~w arrived ~s, txs ~b, verify (~.3f ms)", 
                   [node(),node(PID),maps:get(height,maps:get(header,Blk)),
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
                      NewTable=maps:fold(
                                fun({Addr,Cur},Val,Acc) ->
                                        updatebal(Addr,Cur,Val,Acc,BlockHash)
                                end, 
                                Tbl,
                                maps:get(bals,MBlk,#{})
                               ),
                      if Txs==[] -> ok;
                         true -> 
                             lager:info("Txs ~p",
                                        [
                                         lists:map(
                                           fun({_,#{amount:=TA,
                                                    from:=TF,
                                                    to:=TT}}) ->
                                                   {TF,TA,TT}
                                           end,
                                           Txs)
                                        ]
                                       )
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
                            gen_server:cast(self(),synchronize),
                            {noreply, State#{
                                        candidates=>#{}
                                       }
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
                                    save_bals(LDB, NewTable)
                            end,

                            T3=erlang:system_time(),
                            lager:info("enough confirmations. Installing new block ~s h= ~b (~.3f ms)/(~.3f ms)",
                                       [blkid(BlockHash),
                                        maps:get(height,maps:get(header,Blk)),
                                        (T3-T2)/1000000,
                                        (T3-T0)/1000000
                                       ]),

                            gen_server:cast(tpnode_ws_dispatcher,{new_block, MBlk}),


                            {noreply, State#{
                                        prevblock=> NewLastBlock,
                                        lastblock=> MBlk,
                                        table=>NewTable,
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
              lager:error("New_block error ~p:~p at ~p",[Ec,Ee,hd(S)]),
              {noreply, State}
    end;

handle_cast({continue_sync, BlkId, PID}, #{ldb:=LDB}=State) ->
    case ldb:read_key(LDB,
                 <<"block:",BlkId/binary>>,
                 undefined
                ) of
        undefined ->
            gen_server:cast(PID,{sync,done});
        #{header:=#{},child:=Child}=Block ->
            lager:info("SYNC: next block ~p to ~p",[Block,node(PID)]),
            gen_server:cast(PID,{new_block,Block}),
            gen_server:cast(self(),{continue_sync,Child,PID});
        #{header:=#{}}=Block ->
            lager:info("SYNC: last block ~p to ~p",[Block,node(PID)]),
            gen_server:cast(PID,{new_block,Block}),
            gen_server:cast(PID,{sync,done})
    end,
    {noreply, State};

handle_cast(synchronize, #{lastblock:=#{hash:=LastBlockId}}=State) ->
    Peers=pg2:get_members(blockchain)--[self()],
    case lists:reverse(
           lists:keysort(1,
                         lists:foldl(
                           fun(Pid,Acc) ->
                                   try
                                       H=gen_server:call(Pid,last_block_height),
                                       lager:info("Node ~s height ~p",[node(Pid),H]),
                                       [{H,Pid}|Acc]
                                   catch _:_ -> Acc
                                   end
                           end,[], Peers
                          )
                        )
          ) of
        [{MaxH,MaxPID}|_] ->
            lager:info("Peers ~p",[{MaxH,MaxPID}]),
            lager:info("RunSync ~p",
                       [gen_server:call(MaxPID,{synchronize, LastBlockId, self()})]),
            {noreply, State#{
                        sync=>MaxPID
                       }
            };
        [] ->
            lager:info("Nobody here, nothing to sync",[]),
            {noreply, State}
    end;

handle_cast(savebal,#{ldb:=LDB,table:=T}=State) ->
    save_bals(LDB,T),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

save_bals(LDB, Table) ->
    TD=tables:export(Table),
    ldb:put_key(LDB,<<"bals">>,TD).

load_bals(LDB) ->
    case ldb:read_key(LDB, <<"bals">>,
                      undefined
                     ) of 
        undefined ->
            tables:init(#{index=>[address,cur]});
        Bin ->
            tables:import(Bin,
                          tables:init(#{index=>[address,cur]})
                         )
    end.


save_block(LDB,Block,IsLast) ->
    BlockHash=maps:get(hash,Block),
    ldb:put_key(LDB,<<"block:",BlockHash/binary>>,Block),
    if IsLast ->
           ldb:put_key(LDB,<<"lastblock">>,BlockHash);
       true ->
           ok
    end.

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

