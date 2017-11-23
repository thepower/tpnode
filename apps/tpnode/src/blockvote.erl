-module(blockvote).

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
    pg2:create(blockvote),
    pg2:join(blockvote,self()),
    LastBlock=gen_server:call(blockchain,last_block),
    lager:info("My last block hash ~s",
               [bin2hex:dbin2hex(maps:get(hash,LastBlock))]),
    Res=#{
      candidates=>#{},
      lastblock=>LastBlock
     },
    {ok, Res}.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({signature, BlockHash, Sigs}, State) ->
    Candidatesig=maps:get(candidatesig,State,#{}),
    CSig0=maps:get(BlockHash,Candidatesig,#{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    State2=State#{ candidatesig=>maps:put(BlockHash,CSig,Candidatesig) },
    {noreply, is_block_ready(BlockHash,State2)};

handle_cast({new_block, #{hash:=BlockHash, sign:=Sigs}=Blk, _PID}, 
            #{ candidates:=Candidates,
               lastblock:=#{hash:=LBlockHash}=LastBlock
             }=State) ->

    lager:info("New block (~p/~p) arrived (~s/~s)", 
               [
                maps:get(height,maps:get(header,Blk)),
                maps:get(height,maps:get(header,LastBlock)),
                blkid(BlockHash),
                blkid(LBlockHash)
               ]),
    Candidatesig=maps:get(candidatesig,State,#{}),
    CSig0=maps:get(BlockHash,Candidatesig,#{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    State2=State#{ candidatesig=>maps:put(BlockHash,CSig,Candidatesig), 
                   candidates => maps:put(BlockHash,Blk,Candidates)
                 },
    {noreply, is_block_ready(BlockHash,State2)};
        
handle_cast(_Msg, State) ->
    lager:info("Cast ~p",[_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("Terminate blockvote ~p",[_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

blkid(<<X:8/binary,_/binary>>) ->
    bin2hex:dbin2hex(X).

checksig(BlockHash, Sigs, Acc0) ->
    lists:foldl(
      fun(Signature,Acc) ->
              case block:checksig(BlockHash,Signature) of
                  {true, #{extra:=Xtra}=US} ->
                      lager:info("~s Check sig ~p",[blkid(BlockHash),Xtra]),
                      Pub=proplists:get_value(pubkey,Xtra),
                      maps:put(Pub,US,Acc);
                  false ->
                      Acc
              end
      end,Acc0, Sigs).

is_block_ready(BlockHash,
               #{
                  lastblock:=#{hash:=LBlockHash}=LastBlock
                }= State) ->
    try
        MinSig=2,
        T0=erlang:system_time(),
        Blk0=try
                 maps:get(BlockHash,maps:get(candidates,State))
             catch _:_ ->
                       throw(notready)
             end,
        Sigs=try
                 maps:get(BlockHash,maps:get(candidatesig,State))
             catch _:_ ->
                       throw(notready)
             end,
        Blk1=Blk0#{sign=>maps:values(Sigs)},
        {true,{Success,_}}=block:verify(Blk1),
        T1=erlang:system_time(),
        Txs=maps:get(txs,Blk0,[]),
        lager:info("~s New block ~w arrived ~s, txs ~b, verify (~.3f ms)", 
                   [node(),maps:get(height,maps:get(header,Blk0)),
                    blkid(BlockHash),length(Txs),(T1-T0)/1000000]),
        if length(Success)>MinSig ->
               Blk=Blk0#{sign=>Success},
               %enough signs. use block
               NewPHash=maps:get(parent,maps:get(header,Blk0)),


               if LBlockHash=/=NewPHash ->
                      lager:info("Need resynchronize, height ~p/~p new block parent ~s, but my ~s",
                                 [
                                  maps:get(height,maps:get(header,Blk)),
                                  maps:get(height,maps:get(header,LastBlock)),
                                  blkid(NewPHash),
                                  blkid(LBlockHash)
                                 ]),
                      gen_server:cast(blockchain,synchronize),
                      {noreply, State#{
                                  candidates=>#{}
                                 }
                      };
                  true ->
                      %normal block installation

                      NewLastBlock=LastBlock#{
                                     child=>BlockHash
                                    },

                      T3=erlang:system_time(),
                      lager:info("enough confirmations. Installing new block ~s h= ~b (~.3f ms)",
                                 [blkid(BlockHash),
                                  maps:get(height,maps:get(header,Blk)),
                                  (T3-T0)/1000000
                                 ]),

                      gen_server:cast(blockchain,{new_block,Blk}),

                      State#{
                        prevblock=> NewLastBlock,
                        lastblock=> Blk,
                        candidates=>#{}
                       }

               end;
           true ->
               %not enough
               State
        end
    catch throw:notready ->
              State;
          Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:error("BV New_block error ~p:~p",[Ec,Ee]),
              lists:foreach(
                fun(Se) ->
                     lager:error("at ~p",[Se])
                end, S),
              State
    end.

