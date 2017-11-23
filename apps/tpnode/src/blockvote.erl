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

handle_cast({signature, BlockHash, Sigs}, 
            #{lastblock:=#{hash:=PBlockHash}
             }=State) when BlockHash==PBlockHash ->
    lager:info("Sigs for last block ~p",[Sigs]),
    {noreply, State};

handle_cast({signature, BlockHash, Sigs}, 
            #{ }=State) ->
    lager:info("Sigs for new block ~p ~p",[blkid(BlockHash),Sigs]),
    {noreply, State};

handle_cast({new_block, #{hash:=BlockHash}=Blk, _PID}, 
            #{lastblock:=#{hash:=PBlockHash}=PBlk
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
                    MapFun=fun({H1,_}) -> erlang:crc32(H1) end,
                    lager:info("from ~s Extra len ~p, ~p ~p",
                               [node(),length(NewSigs),
                               lists:map(MapFun,OldSigs),
                               lists:map(MapFun,Success)
                               ]),
                    if(OldSigs=/=NewSigs) ->
                          lager:info("~s Extra confirm Sig changed ~p",
                                    [node(),length(NewSigs)]),
                          Diff=[NewSigs--OldSigs],
                          lager:info("NewSigs ~p",[Diff]),
                          gen_server:cast(blockchain,{extrasig,PBlockHash,Diff}),
                          PBlk1=PBlk#{sign=>NewSigs},
                          PBlk1;
                      true -> 
                          %lager:info("Extra confirm not changed ~w/~w",
                          %          [length(OldSigs),length(NewSigs)]),
                          PBlk
                    end;
                _ -> PBlk
            end,
    {noreply, State#{lastblock=>NewPBlk}};

handle_cast({new_block, #{hash:=BlockHash}=Blk, PID}, 
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
    MinSig=2,
    try
        T0=erlang:system_time(),
        {true,{Success,_}}=block:verify(Blk),
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
               if SigLen>=MinSig ->
                      %enough signs. use block
                      NewPHash=maps:get(parent,maps:get(header,Blk)),


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

                             gen_server:cast(blockchain,{new_block,MBlk}),

                             {noreply, State#{
                                         prevblock=> NewLastBlock,
                                         lastblock=> MBlk,
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
              lager:error("BV New_block error ~p:~p at ~p",[Ec,Ee,hd(S)]),
              {noreply, State}
    end;

handle_cast(_Msg, State) ->
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


