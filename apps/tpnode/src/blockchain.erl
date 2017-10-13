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
    T0=tables:init(#{index=>[address,cur]}),
    {ok,_,T1}=tables:insert(#{
                address=><<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>,
                cur=><<"FTT">>,
                amount=>21.12,
                t=>1507586415,
                seq=>5
               }, T0),
    {ok,_,T2}=tables:insert(#{
                address=><<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>,
                cur=><<"KAKA">>,
                amount=>1,
                t=>1507586915,
                seq=>1
               }, T1),

       NodeID=tpnode_tools:node_id(),
       {ok,LDB}=ldb:open("db_"++binary_to_list(tpnode_tools:node_id())),
       LastBlockHash=ldb:read_key(LDB,<<"lastblock">>,<<0,0,0,0,0>>),
       LastBlock=ldb:read_key(LDB,
                              <<"block:",LastBlockHash/binary>>,
                              #{ hash=><<0,0,0,0,0>>,
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

handle_call({get_addr, Addr}, _From, #{table:=Table}=State) ->
    case tables:lookup(address,Addr,Table) of
        {ok,E} ->
            {reply,
             lists:foldl(
               fun(#{cur:=Cur}=E1,A) -> 
                       maps:put(Cur,
                                maps:without(['address','_id'],E1),
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

handle_call(last_block_height, _From, #{lastblock:=#{header:=#{height:=H}}}=State) ->
    {reply, H, State};

handle_call(last_block, _From, #{lastblock:=LB}=State) ->
    {reply, LB, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({new_block, Blk}, #{candidates:=Candidates,ldb:=LDB}=State) ->
    MinSig=2,
    try
        #{hash:=BlockHash}=Blk,
        {true,{Success,_}}=mkblock:verify(Blk),
        lager:info("New block arrived ~p", [BlockHash]),
        lager:info("deails ~p", [maps:with([header],Blk)]),
        if length(Success)>0 ->
               MBlk=case maps:get(BlockHash,Candidates,undefined) of
                        undefined ->
                            lager:info("Not found"),
                            Blk;
                        #{sign:=BSig}=ExBlk ->
                            NewSigs=lists:usort(BSig++Success),
                            ExBlk#{
                              sign=>NewSigs
                             }
                    end,
               SigLen=length(maps:get(sign,MBlk)),
               lager:info("Signs ~b",[SigLen]),
               if(SigLen>=MinSig) ->
                     %enough signs. Make block.
                     lager:info("enough confirmations. Installing new block ~p",[BlockHash]),
                     LastBlock=maps:put(
                                 child,
                                 BlockHash,
                                 maps:get(lastblock,State)
                                ),

                     save_block(LDB,LastBlock,false),
                     save_block(LDB,MBlk,true),

                     {noreply, State#{
                                 prevblock=> LastBlock,
                                 lastblock=> MBlk,
                                 candidates=>#{}
                                }
                     };
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
    {MaxH,MaxPID}=hd(
                    lists:reverse(
                      lists:keysort(1,
                                    lists:foldl(
                                      fun(Pid,Acc) ->
                                              [{gen_server:call(Pid,last_block_height),Pid}|Acc]
                                      end,[], Peers
                                     )
                                   )
                     )
                   ),
    lager:info("Peers ~p",[{MaxH,MaxPID}]),
    lager:info("RunSync ~p",
               [gen_server:call(MaxPID,{synchronize, LastBlockId, self()})]),
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

save_block(LDB,Block,IsLast) ->
    BlockHash=maps:get(hash,Block),
    ldb:put_key(LDB,<<"block:",BlockHash/binary>>,Block),
    if IsLast ->
           ldb:put_key(LDB,<<"lastblock">>,BlockHash);
       true ->
           ok
    end.

