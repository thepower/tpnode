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
    self() ! init,
    {ok, undefined}.

handle_call(_, _From, undefined) ->
    {reply, notready, undefined};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_, undefined) ->
    {noreply, undefined};

handle_cast({signature, BlockHash, Sigs}, State) ->
    lager:info("Signature"),
    Candidatesig=maps:get(candidatesig,State,#{}),
    CSig0=maps:get(BlockHash,Candidatesig,#{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    State2=State#{ candidatesig=>maps:put(BlockHash,CSig,Candidatesig) },
    {noreply, is_block_ready(BlockHash,State2)};

handle_cast({new_block, #{hash:=BlockHash, sign:=Sigs}=Blk, _PID}, 
            #{ candidates:=Candidates,
               lastblock:=#{hash:=LBlockHash}=LastBlock
             }=State) ->

    lager:debug("BV New block (~p/~p) arrived (~s/~s)", 
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

handle_cast(blockchain_sync, State) ->
    LastBlock=gen_server:call(blockchain,last_block),
    Res=State#{
      lastblock=>LastBlock
     },
    {noreply, Res};
        
handle_cast(_Msg, State) ->
    lager:info("Cast ~p",[_Msg]),
    {noreply, State}.

handle_info(init, undefined) ->
    LastBlock=gen_server:call(blockchain,last_block),
    lager:info("BV My last block hash ~s",
               [bin2hex:dbin2hex(maps:get(hash,LastBlock))]),
    pg2:create(blockvote),
    pg2:join(blockvote,self()),
    Res=#{
      candidates=>#{},
      lastblock=>LastBlock
     },
    {noreply, load_settings(Res)};

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
                      Pub=proplists:get_value(pubkey,Xtra),
                      lager:debug("BV ~s Check sig ~s",[
                                      blkid(BlockHash),
                                      bin2hex:dbin2hex(Pub)
                                     ]),
                      maps:put(Pub,US,Acc);
                  false ->
                      Acc
              end
      end,Acc0, Sigs).

is_block_ready(BlockHash, State) ->
    try
        MinSig=maps:get(minsig,State,2),
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
        lager:notice("TODO: Check keys"),
        T1=erlang:system_time(),
        Txs=maps:get(txs,Blk0,[]),
        if length(Success)<MinSig ->
               lager:info("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)", 
                           [maps:get(height,maps:get(header,Blk0)),
                            blkid(BlockHash),
                            length(Txs),
                            length(Success),
                            (T1-T0)/1000000]),
               throw(notready);
           true -> 
               lager:info("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)", 
                          [maps:get(height,maps:get(header,Blk0)),
                           blkid(BlockHash),
                           length(Txs),
                           length(Success),
                           (T1-T0)/1000000])
        end,
        Blk=Blk0#{sign=>Success},
        %enough signs. use block

        T3=erlang:system_time(),
        lager:info("BV enough confirmations. Installing new block ~s h= ~b (~.3f ms)",
                   [blkid(BlockHash),
                    maps:get(height,maps:get(header,Blk)),
                    (T3-T0)/1000000
                   ]),

        gen_server:cast(blockchain,{new_block,Blk, self()}),

        State#{
          lastblock=> Blk,
          candidates=>#{},
          candidatesig=>#{}
         }

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

load_settings(State) ->
    MyChain=blockchain:get_settings(chain,0),
    MinSig=blockchain:get_settings(minsig,2),
    case maps:get(mychain, State, undefined) of
        undefined -> %join new pg2
            pg2:create({?MODULE,MyChain}),
            pg2:join({?MODULE,MyChain},self());
        MyChain -> ok; %nothing changed
        OldChain -> %leave old, join new
            pg2:leave({?MODULE,OldChain},self()),
            pg2:create({?MODULE,MyChain}),
            pg2:join({?MODULE,MyChain},self())
    end,
    LastBlock=gen_server:call(blockchain,last_block),
    lager:info("BV My last block hash ~s",
               [bin2hex:dbin2hex(maps:get(hash,LastBlock))]),
    State#{
      mychain=>MyChain,
      minsig=>MinSig,
      lastblock=>LastBlock
     }.


