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

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin) of
        {ok, Struct} ->
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            lager:info("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, _From, #{
                     null:=<<"blockvote">>,
                     <<"chain">>:=MsgChain,
                     <<"hash">> := BlockHash,
                     %<<"n">> := _OriginNode,
                     <<"sign">> := Sigs
                    }},
            #{mychain:=MyChain}=State) when MyChain==MsgChain ->
    handle_cast({signature, BlockHash, Sigs}, State);

handle_cast({tpic, _From, #{
                     null:=<<"blockvote">>,
                     <<"chain">>:=MsgChain,
                     <<"hash">> := _BlockHash,
                     %<<"n">> := _OriginNode,
                     <<"sign">> := _Sigs
                    }},
            #{mychain:=MyChain}=State) when MyChain=/=MsgChain ->
    lager:info("BV sig from other chain"),
    {noreply, State};

handle_cast({signature, BlockHash, _Sigs}=WholeSig,
            #{lastblock:=#{hash:=LBH}}=State) when LBH==BlockHash->
    lager:info("BV Got extra sig for ~s ~p", [blkid(BlockHash), WholeSig]),
    gen_server:cast(blockchain, WholeSig),
    {noreply, State};


handle_cast({signature, BlockHash, Sigs}, #{candidatesig:=Candidatesig}=State) ->
    lager:info("BV Got sig for ~s", [blkid(BlockHash)]),
    CSig0=maps:get(BlockHash, Candidatesig, #{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    %lager:debug("BV S CS2 ~p", [maps:keys(CSig)]),
    State2=State#{ candidatesig=>maps:put(BlockHash, CSig, Candidatesig) },
    {noreply, is_block_ready(BlockHash, State2)};

handle_cast({new_block, #{hash:=BlockHash, sign:=Sigs}=Blk, _PID},
            #{ candidates:=Candidates,
               candidatesig:=Candidatesig,
               lastblock:=#{hash:=LBlockHash}=LastBlock
             }=State) ->

    lager:info("BV New block (~p/~p) arrived (~s/~s)",
               [
                maps:get(height, maps:get(header, Blk)),
                maps:get(height, maps:get(header, LastBlock)),
                blkid(BlockHash),
                blkid(LBlockHash)
               ]),
    CSig0=maps:get(BlockHash, Candidatesig, #{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    %lager:debug("BV N CS2 ~p", [maps:keys(CSig)]),
    State2=State#{ candidatesig=>maps:put(BlockHash, CSig, Candidatesig),
                   candidates => maps:put(BlockHash, Blk, Candidates)
                 },
    {noreply, is_block_ready(BlockHash, State2)};

handle_cast(blockchain_sync, State) ->
    LastBlock=gen_server:call(blockchain, last_block),
    Res=State#{
      lastblock=>LastBlock
     },
    {noreply, Res};

handle_cast(_Msg, State) ->
    lager:info("BV Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(init, undefined) ->
    LastBlock=gen_server:call(blockchain, last_block),
    lager:info("BV My last block hash ~s",
               [bin2hex:dbin2hex(maps:get(hash, LastBlock))]),
    Res=#{
      candidatesig=>#{},
      candidates=>#{},
      lastblock=>LastBlock
     },
    {noreply, load_settings(Res)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:error("Terminate blockvote ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

blkid(<<X:8/binary, _/binary>>) ->
    bin2hex:dbin2hex(X).

checksig(BlockHash, Sigs, Acc0) ->
    lists:foldl(
      fun(Signature, Acc) ->
              case bsig:checksig1(BlockHash, Signature) of
                  {true, #{extra:=Xtra}=US} ->
                      Pub=proplists:get_value(pubkey, Xtra),
                      lager:debug("BV ~s Check sig ~s", [
                                      blkid(BlockHash),
                                      bin2hex:dbin2hex(Pub)
                                     ]),
					  case maps:is_key(Pub, Acc) of
						  true -> Acc;
						  false ->
							  maps:put(Pub, US, Acc)
					  end;
                  false ->
                      Acc
              end
      end, Acc0, Sigs).

is_block_ready(BlockHash, State) ->
	try
		MinSig=maps:get(minsig, State, 2),
		T0=erlang:system_time(),
		Sigs=try
				 maps:get(BlockHash, maps:get(candidatesig, State))
			 catch _:_ ->
					   throw({notready, nosig})
			 end,
		case maps:is_key(BlockHash, maps:get(candidates, State)) of
			false ->
				case maps:size(Sigs) >= MinSig of
					true ->
						%throw({notready, nocand1}),
						lager:info("Probably they went ahead"),
						blockchain ! checksync,
						State;
					false ->
						throw({notready, {nocand, maps:size(Sigs), MinSig}})
				end;
			true ->
				Blk0=maps:get(BlockHash, maps:get(candidates, State)),
				Blk1=Blk0#{sign=>maps:values(Sigs)},
				{true, {Success, _}}=block:verify(Blk1),
				T1=erlang:system_time(),
				Txs=maps:get(txs, Blk0, []),
				lager:notice("TODO: Check keys ~p of ~p",
							 [length(Success), MinSig]),
				if length(Success)<MinSig ->
					   lager:info("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)",
								  [maps:get(height, maps:get(header, Blk0)),
								   blkid(BlockHash),
								   length(Txs),
								   length(Success),
								   (T1-T0)/1000000]),
					   throw({notready, minsig});
				   true ->
					   lager:info("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)",
								  [maps:get(height, maps:get(header, Blk0)),
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
							maps:get(height, maps:get(header, Blk)),
							(T3-T0)/1000000
						   ]),

				gen_server:cast(blockchain, {new_block, Blk, self()}),
				State#{
				  lastblock=> Blk,
				  candidates=>#{},
				  candidatesig=>#{}
				 }
		end
	catch throw:{notready, Where} ->
			  lager:info("Not ready ~s ~p", [blkid(BlockHash), Where]),
			  State;
		  Ec:Ee ->
			  S=erlang:get_stacktrace(),
			  lager:error("BV New_block error ~p:~p", [Ec, Ee]),
			  lists:foreach(
				fun(Se) ->
						lager:error("at ~p", [Se])
				end, S),
			  State
	end.

load_settings(State) ->
    MyChain=blockchain:get_mysettings(chain),
    MinSig=blockchain:get_mysettings(minsig),
	LastBlock=gen_server:call(blockchain, last_block),
    lager:info("BV My last block hash ~s",
               [bin2hex:dbin2hex(maps:get(hash, LastBlock))]),
    State#{
      mychain=>MyChain,
      minsig=>MinSig,
      lastblock=>LastBlock
     }.


