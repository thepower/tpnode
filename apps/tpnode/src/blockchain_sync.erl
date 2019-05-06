-module(blockchain_sync).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,chainstate/0,bbyb_sync/3,receive_block/2,tpiccall/3]).

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

chainstate() ->
  Candidates=lists:reverse(
               tpiccall(<<"blockchain">>,
                        #{null=><<"sync_request">>},
                        [last_hash, last_height, chain, prev_hash, last_temp]
                       ))++[{self,gen_server:call(blockchain_reader,sync_req)}],
  io:format("Cand ~p~n",[Candidates]),
  ChainState=lists:foldl( %first suitable will be the quickest
               fun({_, #{chain:=_HisChain,
                         %null:=<<"sync_available">>,
                         last_hash:=Hash,
                         last_temp:=Tmp,
                         %prev_hash:=PHash,
                         last_height:=Heig
                        }=A
                   }, Acc) ->
                   PHash=maps:get(prev_hash,A,<<0,0,0,0,0,0,0,0>>),
                   maps:put({Heig, Hash, PHash, Tmp},
                            maps:get({Heig, Hash, PHash, Tmp}, Acc, 0)+1, Acc);
                  ({_, _}, Acc) ->
                   Acc
               end, #{}, Candidates),
  erlang:display(maps:fold(
                   fun({Heig,Has,PHas,Tmp},V,Acc) ->
                       maps:put(
                         iolist_to_binary(
                           [
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
  filelib:ensure_dir("db/"),
  {ok, LDB}=ldb:open("db/db_" ++ atom_to_list(node())),
  {ok, get_last(#{
         ldb=>LDB
        })}.

handle_call({runsync, NewChain}, _From, State) ->
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, call} ]),
  self() ! runsync,
  {reply, sync, State#{mychain:=NewChain}};

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  lager:info("Unhandled ~p",[_Request]),
  {reply, unhandled_call, State}.

handle_cast(update, State) ->
  {noreply, get_last(State)};

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

handle_info({inst_sync, done, Log}, State) ->
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, inst} ]),
  lager:info("BC Sync done ~p", [Log]),
  lager:notice("Check block's keys"),
  {ok, C}=gen_server:call(ledger, {check, []}),
  lager:info("My Ledger hash ~s", [bin2hex:dbin2hex(C)]),
  #{header:=#{ledger_hash:=LH}}=Block=maps:get(syncblock, State),
  if LH==C ->
       lager:info("Sync done"),
       lager:notice("Verify settings"),
       CleanState=maps:without([sync, syncblock, sync_peer, syncsettings], State#{unksig=>0}),
       SS=maps:get(syncsettings, State),
       %self() ! runsync,
       lager:error("FIX ME"),
%       save_block(LDB, Block, true),
%       save_sets(LDB, SS),
%       lastblock2ets(BTable, Block),
       synchronizer ! imready,
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
               sync_peer:=Handler,
               sync_candidates:=Candidates} = State) ->
  flush_bbsync(),
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, bbsync} ]),
  lager:debug("*** run bbyb sync from hash: ~p", [blkid(Hash)]),
  lager:debug("run bbyb sync cands: ~p", [proplists:get_keys(Candidates)]),
  BBRes=bbyb_sync(Hash, Handler, Candidates),
  lager:debug("run bbyb sync res ~p",[BBRes]),
  case BBRes of
    sync_cont ->
      {noreply, State};
    done ->
      synchronizer ! imready,
      {noreply,
       maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid], State)
      };
    {broken_block, C1} ->
      {noreply,
       maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid],
                    State#{
                      sync_candidates => C1
                     })
      };
    {broken_sync, C1} ->
      {noreply,
       maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid],
                    State#{
                      sync_candidates => C1
                     })
      };
    {noresponse, C1} ->
      {noreply,
       maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid],
                    State#{
                      sync_candidates => C1
                     })
      }
  end;

handle_info({bbyb_sync, Hash}, State) ->
  lager:info("*** bbyb sync ~s, but no state ~p",
               [
                blkid(Hash),
                maps:with([sync, sync_peer, sync_candidates],State)
               ]),
  {noreply, State};


handle_info(checksync, State) ->
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, checksync} ]),
  flush_checksync(),
  %%  self() ! runsync,
  {noreply, State};

handle_info({sync,PID,broken_sync,C1}, #{bbsync_pid:=BBSPid}=State) when PID==BBSPid ->
  synchronizer ! imready,
  {noreply,
   maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid],
                State#{
                  sync_candidates => C1
                 })
  };

handle_info({sync,PID,sync_done, _Reason}, #{bbsync_pid:=BBSPid}=State) when PID==BBSPid ->
  synchronizer ! imready,
  {noreply,
   maps:without([sync, syncblock, sync_peer, sync_candidates, bbsync_pid], State)
  };

handle_info({'DOWN',_,process,PID, _Reason}, #{bbsync_pid:=BBSPid}=State) when PID==BBSPid ->
  lager:error("bbsync went down unexpected"),
  {noreply, 
   maps:without([bbsync_pid], State)
  };

handle_info(runsync, State) ->
  #{header:=#{height:=MyHeight}, hash:=MyLastHash}=blockchain:last_meta(),
  stout:log(runsync, [ {node, nodekey:node_name()}, {where, got_info} ]),
  lager:debug("got runsync, myHeight: ~p, myLastHash: ~p", [MyHeight, blkid(MyLastHash)]),

  Candidates = case maps:get(sync_candidates, State, []) of
                 [] ->
                   lager:debug("use default list of candidates"),
                   lists:reverse(
                     tpiccall(<<"blockchain">>,
                              #{null=><<"sync_request">>},
                              [last_hash, last_height, chain, last_temp]
                             ));
                 SavedCandidates ->
                   lager:debug("use saved list of candidates"),
                   SavedCandidates
               end,
  handle_info({runsync, Candidates}, State);

handle_info({runsync, Candidates}, State) ->
  flush_checksync(),
  flush_runsync(),
  #{header:=#{height:=MyHeight}, hash:=MyLastHash}=MyLast=blockchain:last_meta(),

  B=tpiccall(<<"blockchain">>,
           #{null=><<"sync_request">>},
           [last_hash, last_height, chain, last_temp]
          ),
  Hack_Candidates=lists:foldl(
                    fun({{A1,B1,_},_}=Elem, Acc) ->
                        maps:put({A1,B1},Elem,Acc)
                    end, #{}, B),

  Candidate=lists:foldl( %first suitable will be the quickest
              fun
                ({{A2,B2,_}, undefined}, undefined) ->
                  case maps:find({A2,B2},Hack_Candidates) of
                    error ->
                      undefined;
                    {ok, {CHandler1, #{chain:=_HisChain,
                                       last_hash:=_,
                                       last_height:=_,
                                       null:=<<"sync_available">>} = CInfo}} ->
                      lager:notice("Hacked version of candidate selection was used"),
                      {CHandler1, CInfo};
                    _ ->
                      undefined
                  end;
                ({CHandler, undefined}, undefined) ->
                  T1=erlang:system_time(),
                  Inf=tpiccall(CHandler,
                               #{null=><<"sync_request">>},
                               [last_hash, last_height, chain, last_temp]
                              ),
                  T2=erlang:system_time(),
                  lager:debug("sync from ~p ~p",[Inf,T2-T1]),
                  case Inf of
                    [{CHandler1, #{chain:=_HisChain,
                                   last_hash:=_,
                                   last_height:=_,
                                   null:=<<"sync_available">>} = CInfo}] ->
                      {CHandler1, CInfo};
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
  lager:debug("runsync candidates: ~p", [Candidates]),
  lager:debug("runsync candidate: ~p", [Candidate]),
  case Candidate of
    undefined ->
      lager:notice("No candidates for sync."),
      synchronizer ! imready,
      {noreply, maps:without([sync, syncblock, sync_peer, sync_candidates], State#{unksig=>0})};

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
      MyTmp=case maps:find(temporary, MyLast) of
              error -> false;
              {ok, TmpNo} -> TmpNo
            end,
      lager:info("Found candidate h=~w my ~w, bb ~s inst ~s/~s",
                 [Height, MyHeight, ByBlock, Inst0, Inst]),
      if (Height == MyHeight andalso Tmp == MyTmp) ->
           lager:info("Sync done, finish."),
           synchronizer ! imready,
           flush_bbsync(),
           flush_checksync(),
           {noreply,
            maps:without([sync, syncblock, sync_peer, sync_candidates], State#{unksig=>0})
           };
         Inst == true ->
           % try instant sync;
           gen_server:call(ledger, '_flush'),
           ledger_sync:run_target(tpic, Handler, ledger, undefined),
           flush_bbsync(),
           flush_checksync(),
           {noreply, State#{
                       sync=>inst,
                       sync_peer=>Handler,
                       sync_candidates => Candidates
                      }};
         true ->
           %try block by block
           case maps:is_key(temporary, State) of
             true ->
               #{header:=#{parent:=Parent}}=maps:get(temporary, State),
               lager:info("RUN bbyb sync since parent ~s", [blkid(Parent)]),
               handle_info({bbyb_sync, Parent},
                           State#{
                             sync=>bbyb,
                             sync_peer=>Handler,
                             sync_candidates => Candidates
                            });
             false ->
               lager:info("RUN bbyb sync since ~s", [blkid(MyLastHash)]),
               handle_info({bbyb_sync, MyLastHash},
                           State#{
                             sync=>bbyb,
                             sync_peer=>Handler,
                             sync_candidates => Candidates
                            })
           end
      end
  end;

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

bbyb_sync(Hash, Handler, Candidates) ->
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
      {broken_sync, skip_candidate(Candidates)};
    [{_, #{block:=BlockPart}=R}] ->
      lager:info("block found in received bbyb sync data ~p",[R]),
      try
        BinBlock = receive_block(Handler, BlockPart),
        #{hash:=NewH, header:=#{height:=NewHei}} = Block = block:unpack(BinBlock),
        %TODO Check parent of received block
        case block:verify(Block) of
          {true, _} ->
            %gen_server:cast(blockchain_updater, {new_block, Block, self()}),
            lager:info("Got block ~w ~s",[NewHei,blkid(NewH)]),
            CRes=gen_server:call(blockchain_updater, {new_block, Block, self()}),
            lager:info("CRes ~p",[CRes]),
            case maps:find(child, Block) of
              {ok, Child} ->
                lager:info("block ~s have child ~s", [blkid(NewH), blkid(Child)]),
                bbyb_sync(NewH, Handler, Candidates);
%                self() ! {bbyb_sync, NewH},
%                sync_cont;

              error ->
                %%                    erlang:send_after(1000, self(), runsync), % chainkeeper do that
                lager:info("block ~s no child, sync done?", [blkid(NewH)]),
                stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_no_child} ]),
                done
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

            {broken_block, skip_candidate(Candidates)}
        end
      catch throw:broken_sync ->
              lager:notice("Broken sync"),
              stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_throw_broken_sync} ]),

              {broken_sync, skip_candidate(Candidates)}
      end;
    _R ->
      lager:error("bbyb no response ~p",[_R]),
      %%      erlang:send_after(10000, self(), runsync),
      stout:log(runsync, [ {node, nodekey:node_name()}, {where, syncdone_no_response} ]),
      {noresponse, skip_candidate(Candidates)}
  end.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
get_last(#{ldb:=LDB}=State) ->
  LastBlockHash=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),
  LastBlock=ldb:read_key(LDB, <<"block:", LastBlockHash/binary>>, undefined),
  mychain(
    State#{lastblock=>LastBlock}
   ).

flush_runsync() ->
  receive
    runsync  ->
      flush_runsync();
    {runsync,_}  ->
      flush_runsync()
  after 0 ->
          done
  end.

flush_bbsync() ->
  receive
    {bbyb_sync, _} ->
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

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).

mychain(State) ->
  {MyChain, MyName, ChainNodes}=blockchain_reader:mychain(),
  lager:info("My name ~p chain ~p ournodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
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

% removes one sync candidate from the list of sync candidates
skip_candidate([])->
  [];

skip_candidate(default)->
  [];

skip_candidate(Candidates) when is_list(Candidates) ->
  tl(Candidates).

%% ------------------------------------------------------------------
