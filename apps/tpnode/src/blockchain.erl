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

handle_call({synchronize, BlkId, PID}, _From, #{ldb:=LDB}=State) ->
    case ldb:read_key(LDB,
                 <<"block:",BlkId/binary>>,
                 undefined
                ) of
        undefined ->
            {reply, noblock, State};
        #{child:=Child}=Block ->
            gen_server:cast(self(),{continue_sync,Child,PID}),
            {reply, {one, Block}, State};
        Block ->
            {reply, {ok, Block}, State}
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

handle_cast({new_block, #{hash:=BlockHash}=Blk, PID}, 
            #{candidates:=Candidates,ldb:=LDB,
              lastblock:=#{hash:=LBlockHash}=LastBlock,
              table:=Tbl}=State) ->

    lager:info("New block ~s arrived ~s", 
               [
                blkid(BlockHash),
                blkid(LBlockHash)
               ]),
    MinSig=2,
    try
        {true,{Success,_}}=mkblock:verify(Blk),
        lager:info("~s from ~s New block ~w arrived ~s", 
                   [node(),node(PID),maps:get(height,maps:get(header,Blk)), blkid(BlockHash)]),
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
                     lager:info("enough confirmations. Installing new block ~s",[blkid(BlockHash)]),
                     NewTable=maps:fold(
                                fun({Addr,Cur},Val,Acc) ->
                                        updatebal(Addr,Cur,Val,Acc,BlockHash)
                                end, 
                                Tbl,
                                maps:get(bals,MBlk,#{})
                               ),
                     NewPHash=maps:get(parent,maps:get(header,Blk)),

                     if LBlockHash=/=NewPHash ->
                            lager:info("Need resynchronize, height ~p/~p new block parent ~s, but my ~s",
                                       [
                                        maps:get(height,maps:get(header,Blk)),
                                        maps:get(height,maps:get(header,LastBlock)),
                                        blkid(NewPHash),
                                        blkid(LBlockHash)
                                       ]);
                        true ->
                            ok
                     end,

                     save_block(LDB,LastBlock,false),
                     save_block(LDB,MBlk,true),
                     save_bals(LDB, NewTable),

                     {noreply, State#{
                                 prevblock=> LastBlock,
                                 lastblock=> MBlk,
                                 table=>NewTable,
                                 candidates=>#{}
                                }
                     };
%                  SigLen>=MinSig ->
%                      lager:info("Need resynchronize, new block parent ~p, but my ~p",
%                                [LBlockHash, BlockHash]),
%%                      gen_server:cast(self(),synchronize),
%                      {noreply, State};
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
        #{child:=Child}=Block ->
            gen_server:cast(PID,{new_block,Block}),
            gen_server:cast(self(),{continue_sync,Child,PID});
        Block ->
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
                                       [{gen_server:call(Pid,last_block_height),Pid}|Acc]
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
            {noreply, State};
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
