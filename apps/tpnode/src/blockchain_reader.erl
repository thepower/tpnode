-module(blockchain_reader).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([blkid/1,
         mychain/0,
         send_block_real/4]).


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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  filelib:ensure_dir("db/"),
  {ok, LDB}=ldb:open("db/db_" ++ atom_to_list(node())),
  {ok, get_last(#{
         ldb=>LDB
        })}.

handle_call(last_block_height, _From,
            #{mychain:=MC, lastblock:=#{header:=#{height:=H}}}=State) ->
  {reply, {MC, H}, State};

handle_call(status, _From,
            #{mychain:=MC, lastblock:=#{header:=H, hash:=BH}}=State) ->
  {reply, { MC, BH, H }, State};

handle_call(lastsig, _From, #{myname:=MyName,
                              chainnodes:=CN,
                              lastblock:=#{hash:=H, sign:=Sig}
                             }=State) ->
  SS=try
       lists:foldl(
         fun(#{extra:=PL}, Acc) ->
             case proplists:get_value(pubkey, PL, undefined) of
               undefined -> Acc;
               BinKey ->
                 case maps:get(BinKey, CN, undefined) of
                   undefined -> Acc;
                   NodeID ->
                     [NodeID|Acc]
                 end
             end
         end,
         [],
         Sig
        )
     catch _:_ -> []
     end,
  {reply, #{hash=>H,
            origin=>MyName,
            signed=>SS}, State};

handle_call({last_block, N}, _From, #{ldb:=LDB}=State) when is_integer(N) ->
  {reply, rewind(LDB,N), State};

handle_call(last_block, _From, #{tmpblock:=LB}=State) ->
  {reply, LB, State};

handle_call(last_block, _From, #{lastblock:=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, last}, _From, #{tmpblock:=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, last}, _From, #{lastblock:=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, LBH}, _From, #{lastblock:=#{hash:=LBH}=LB}=State) ->
  {reply, LB, State};

handle_call({get_block, TBH}, _From, #{tmpblock:=#{hash:=TBH}=TB}=State) ->
  {reply, TB, State};

handle_call({get_block, BlockHash}, _From, #{ldb:=LDB, lastblock:=#{hash:=LBH}=LB}=State)
  when is_binary(BlockHash) ->
  %lager:debug("Get block ~p", [BlockHash]),
  Block=if BlockHash==LBH -> LB;
           true ->
             ldb:read_key(LDB,
                          <<"block:", BlockHash/binary>>,
                          undefined)
        end,
  {reply, Block, State};

handle_call({get_block, BlockHash, Rel}, _From, #{ldb:=LDB, lastblock:=#{hash:=LBH}}=State)
  when is_binary(BlockHash) andalso is_atom(Rel) ->
  %lager:debug("Get block ~p", [BlockHash]),
  H=if BlockHash==last ->
         LBH;
       true ->
         BlockHash
    end,
  Res=block_rel(LDB, H, Rel),
  {reply, Res, State};

handle_call({block_exists, BlockHash}, _From, #{ldb:=LDB} = State)
  when is_binary(BlockHash) ->
  %lager:debug("Get block ~p", [BlockHash]),
  Exists =
  case ldb:read_key(LDB, <<"block:", BlockHash/binary>>, undefined) of
    undefined ->
      false;
    _ ->
      true
  end,
  {reply, Exists, State};

handle_call(sync_req, _From, State) ->
  MaySync=sync_req(State),
  {reply, MaySync, State};

handle_call(_Request, _From, State) ->
  lager:info("Unhandled ~p",[_Request]),
  {reply, unhandled_call, State}.

handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                             <<"hash">>:=Hash,
                             <<"rel">>:=<<"child">>=Rel
                            }},
            #{ tmpblock:=#{ header:=#{ parent:=Hash } }=TmpBlock } = State) ->
  MyRel = child,
  lager:info("Pick temp block ~p ~p",[blkid(Hash),Rel]),
  BlockParts = block:split_packet(block:pack(TmpBlock)),
  Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => MyRel}},
  send_block(tpic, Origin, Map, BlockParts),
  {noreply, State};

handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                             <<"hash">>:=Hash,
                             <<"rel">>:=<<"child">>
                            }},
            #{tmpblock:=#{header:=#{parent:=Hash}}=TmpBlk} = State) ->
  BinBlock=block:pack(TmpBlk),
  lager:info("I was asked for ~s for blk ~s: ~p",[child,blkid(Hash),TmpBlk]),
  BlockParts = block:split_packet(BinBlock),
  Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => child}},
  send_block(tpic, Origin, Map, BlockParts),
  {noreply, State};


handle_cast({tpic, Origin, #{null:=<<"pick_block">>,
                             <<"hash">>:=Hash,
                             <<"rel">>:=Rel
                            }},
            #{ldb:=LDB} = State) ->
  lager:info("Pick block ~p ~p",[blkid(Hash),Rel]),
  MyRel = case Rel of
            <<"pre", _/binary>> -> prev;
            <<"child">> -> child;
            %<<"self">> -> self;
            _ -> self
          end,
  R=case block_rel(LDB, Hash, MyRel) of
      Error when is_atom(Error) ->
        #{error=> Error};
      Blk when is_map(Blk) ->
        #{block => block:pack(Blk)}
    end,
  lager:info("I was asked for ~s for blk ~s: ~p",[MyRel,blkid(Hash),R]),

  case maps:is_key(block, R) of
    false ->
      tpic2:cast(Origin,
                 msgpack:pack(
                   maps:merge(
                     #{
                     null=> <<"block">>,
                     req=> #{<<"hash">> => Hash,
                             <<"rel">> => MyRel}
                    }, R))),
      {noreply, State};

    true ->
      #{block := BinBlock} = R,
      BlockParts = block:split_packet(BinBlock),
      Map = #{null => <<"block">>, req => #{<<"hash">> => Hash, <<"rel">> => MyRel}},
      send_block(tpic, Origin, Map, BlockParts),
      {noreply, State}
  end;


handle_cast({tpic, Origin, #{null:=<<"instant_sync_run">>}},
            #{settings:=Settings, lastblock:=LastBlock}=State) ->
  lager:info("Starting instant sync source"),
  ledger_sync:run_source(tpic, Origin, LastBlock, Settings),
  {noreply, State};

handle_cast({tpic, Origin, #{null:=<<"sync_request">>}}, State) ->
  MaySync=sync_req(State),
  tpic2:cast(Origin, msgpack:pack(MaySync)),
  {noreply, State};

handle_cast({tpic, Origin, #{null := <<"sync_block">>,
                             <<"block">> := BinBlock}},
            #{sync:=SyncOrigin }=State) when Origin==SyncOrigin ->
  Blk=block:unpack(BinBlock),
  handle_cast({new_block, Blk, Origin}, State);


handle_cast({tpic, Peer, #{null := <<"continue_sync">>,
                           <<"block">> := BlkId,
                           <<"cnt">> := NextB}}, #{ldb:=LDB}=State) ->
  lager:info("SYNCout from ~s to ~p", [blkid(BlkId), Peer]),
  case ldb:read_key(LDB, <<"block:", BlkId/binary>>, undefined) of
    undefined ->
      lager:info("SYNC done at ~s", [blkid(BlkId)]),
      tpic2:cast(Peer, msgpack:pack(#{null=><<"sync_done">>}));
    #{header:=#{}, child:=Child}=_Block ->
      lager:info("SYNC next block ~s to ~p", [blkid(Child), Peer]),
      handle_cast({continue_syncc, Child, Peer, NextB}, State);
    #{header:=#{}}=Block ->
      lager:info("SYNC last block ~p to ~p", [Block, Peer]),
      tpic2:cast(Peer, msgpack:pack(#{null=><<"sync_block">>,
                                           block=>block:pack(Block)})),
      tpic2:cast(Peer, msgpack:pack(#{null=><<"sync_done">>}))
  end,
  {noreply, State};

handle_cast({continue_syncc, BlkId, Peer, NextB}, #{ldb:=LDB,
                                                    lastblock:=#{hash:=LastHash}=LastBlock
                                                   }=State) ->
  case ldb:read_key(LDB, <<"block:", BlkId/binary>>, undefined) of
    _ when BlkId == LastHash ->
      lager:info("SYNCC last block ~s from state", [blkid(BlkId)]),
      tpic2:cast(Peer, msgpack:pack(
                              #{null=><<"sync_block">>,
                                block=>block:pack(LastBlock)})),
      tpic2:cast(Peer, msgpack:pack(
                              #{null=><<"sync_done">>}));
    undefined ->
      lager:info("SYNCC done at ~s", [blkid(BlkId)]),
      tpic2:cast(Peer, msgpack:pack(
                              #{null=><<"sync_done">>}));
    #{header:=#{height:=H}, child:=Child}=Block ->
      P=msgpack:pack(
          #{null=><<"sync_block">>,
            block=>block:pack(Block)}),
      lager:info("SYNCC send block ~w ~s ~w bytes to ~p",
                 [H, blkid(BlkId), size(P), Peer]),
      tpic2:cast(Peer, P),

      if NextB > 1 ->
           gen_server:cast(self(), {continue_syncc, Child, Peer, NextB-1});
         true ->
           lager:info("SYNCC pause ~p", [BlkId]),
           tpic2:cast(Peer, msgpack:pack(
                                   #{null=><<"sync_suspend">>,
                                     <<"block">>=>BlkId}))
      end;
    #{header:=#{}}=Block ->
      lager:info("SYNCC last block at ~s", [blkid(BlkId)]),
      tpic2:cast(Peer, msgpack:pack(
                              #{null=><<"sync_block">>,
                                block=>block:pack(Block)})),
      if (BlkId==LastHash) ->
           lager:info("SYNC Real last");
         true ->
           lager:info("SYNC Not really last")
      end,
      tpic2:cast(Peer, msgpack:pack(#{null=><<"sync_done">>}))
  end,
  {noreply, State};

handle_cast({tpic, Peer, #{null := <<"sync_suspend">>,
                           <<"block">> := BlkId}},
            #{ sync:=SyncPeer,
               lastblock:=#{hash:=LastHash}=LastBlock
             }=State) when SyncPeer==Peer ->
  lager:info("Sync suspend ~s, my ~s", [blkid(BlkId), blkid(LastHash)]),
  lager:info("MyLastBlock ~p", [maps:get(header, LastBlock)]),
  if(BlkId == LastHash) ->
      lager:info("Last block matched, continue sync"),
      tpic2:cast(Peer, msgpack:pack(#{
                              null=><<"continue_sync">>,
                              <<"block">>=>LastHash,
                              <<"cnt">>=>2})),
      {noreply, State};
    true ->
      lager:info("SYNC ERROR"),
      %          {noreply, run_sync(State)}
      {noreply, State}
  end;

handle_cast({tpic, Peer, #{null := <<"sync_suspend">>,
                           <<"block">> := _BlkId}}, State) ->
  lager:info("sync_suspend from bad peer ~p", [Peer]),
  {noreply, State};

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
  case msgpack:unpack(Bin, []) of
    {ok, Struct} ->
      lager:debug("Inbound TPIC ~p", [maps:get(null, Struct)]),
      handle_cast({tpic, From, Struct}, State);
    _Any ->
      lager:info("Can't decode  TPIC ~p", [_Any]),
      lager:info("TPIC ~p", [Bin]),
      {noreply, State}
  end;

handle_cast({tpic, From, #{
                     null:=<<"tail">>
                    }},
            #{mychain:=MC, lastblock:=#{header:=#{height:=H},
                                        hash:=Hash }}=State) ->
  tpic2:cast(From, msgpack:pack(#{null=><<"response">>,
                                       mychain=>MC,
                                       height=>H,
                                       hash=>Hash
                                      })),
  {noreply, State};

handle_cast(update, State) ->
  {noreply, get_last(State)};

handle_cast(_Msg, State) ->
  lager:info("Unknown cast ~p", [_Msg]),
  file:write_file("tmp/unknown_cast_msg.txt", io_lib:format("~p.~n", [_Msg])),
  file:write_file("tmp/unknown_cast_state.txt", io_lib:format("~p.~n", [State])),
  {noreply, State}.

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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
send_block(TPIC, PeerID, Map, Arr) ->
  spawn(?MODULE,send_block_real,[TPIC, PeerID, Map, Arr]),
  ok.

send_block_real(_TPIC, PeerID, Map, [<<Hdr:8/binary,_/binary>>=BlockHead]) ->
  lager:debug("Send last block part to peer ~p: ~s",
             [PeerID, hex:encode(Hdr)]),
  tpic2:cast(PeerID, msgpack:pack(maps:merge(Map, #{block => BlockHead})));
send_block_real(_TPIC, PeerID, Map, [<<Hdr:8/binary,_/binary>>=BlockHead|BlockTail]) ->
  lager:debug("Send block part to peer ~p, ~w to go: ~s",
             [PeerID, length(BlockTail),hex:encode(Hdr)]),
  tpic2:cast(PeerID, msgpack:pack(maps:merge(Map, #{block => BlockHead}))),
  receive
    {'$gen_cast', {tpic, PeerID, Bin}} ->
      case msgpack:unpack(Bin) of
        {ok, #{null := <<"pick_next_part">>}} ->
          send_block_real(tpic, PeerID, Map, BlockTail);
        {error, _} ->
          error
      end;
    {'$gen_cast', Any} ->
      lager:info("Unexpected message ~p", [Any])
  after 30000 ->
          lager:info("Send block to ~p timeout, ~w parts throw away",
                     [PeerID, length(BlockTail)]),
          timeout
  end.

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).

rewind(LDB, BlkNo) ->
  CurBlk=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),
  rewind(LDB, BlkNo, CurBlk).

rewind(LDB, BlkNo, CurBlk) ->
  case ldb:read_key(LDB,
                    <<"block:", CurBlk/binary>>,
                    undefined
                   ) of
    undefined ->
      noblock;
    #{header:=#{}}=B when BlkNo == -1 ->
      B;
    #{header:=#{height:=H}}=B when BlkNo == H ->
      B;
    #{header:=#{parent:=Parent}} ->
      if BlkNo<0 ->
           rewind(LDB, BlkNo+1, Parent);
         BlkNo>=0 ->
           rewind(LDB, BlkNo, Parent)
      end
  end.

block_rel(LDB,Hash,Rel) when Rel==prev orelse Rel==child orelse Rel==self ->
  case ldb:read_key(LDB, <<"block:", Hash/binary>>, undefined) of
    undefined ->
      noblock;
    #{header:=#{}} = Block when Rel == self ->
      Block;
    #{header:=#{}, child:=Child} = _Block when Rel == child ->
      case ldb:read_key(LDB, <<"block:", Child/binary>>, undefined) of
        undefined ->
          havenochild;
        #{header:=#{}} = SBlock ->
          SBlock
      end;
    #{header:=#{}} = _Block when Rel == child ->
      nochild;
    #{header:=#{parent:=Parent}} = _Block when Rel == prev ->
      case ldb:read_key(LDB, <<"block:", Parent/binary>>, undefined) of
        undefined ->
          havenoprev;
        #{header:=#{}} = SBlock ->
          SBlock
      end;
    #{header:=#{}} = _Block when Rel == prev ->
      noprev;
    _ ->
      unknown
  end.

sync_req(#{lastblock:=#{hash:=Hash, header:=#{height:=Height, parent:=Parent}} = LastBlock,
           mychain:=MyChain
          } = State) ->
  BLB = block:pack(maps:with([hash, header, sign], LastBlock)),
  TmpBlock = maps:get(tmpblock, State, undefined),
  Ready=not maps:is_key(sync, State),
  Template =
  case TmpBlock of
    undefined ->
      #{last_height=>Height,
        last_hash=>Hash,
        last_temp=>false,
        tempblk=>false,
        lastblk=>BLB,
        prev_hash=>Parent,
        chain=>MyChain
       };
    #{hash:=TH,
      header:=#{height:=THei, parent:=TParent},
      temporary:=TmpNo} = Tmp ->
      #{last_height=>THei,
        last_hash=>TH,
        last_temp=>TmpNo,
        tempblk=>block:pack(Tmp),
        lastblk=>BLB,
        prev_hash=>TParent,
        chain=>MyChain
       }
  end,
  if not Ready -> %I am not ready
       Template#{
         null=><<"sync_unavailable">>,
         byblock=>false,
         instant=>false
        };
     true -> %I am working and could be source for sync
       Template#{
         null=><<"sync_available">>,
         byblock=>true,
         instant=>true
        }
  end.

get_last(#{ldb:=LDB}=State) ->
  M=blockchain:last_meta(),
  LastBlockHash=ldb:read_key(LDB, <<"lastblock">>, <<0, 0, 0, 0, 0, 0, 0, 0>>),
  LastBlock=ldb:read_key(LDB, <<"block:", LastBlockHash/binary>>, undefined),
  case M of
    #{temporary:=_Tmp} ->
      mychain(
        State#{
          tmpblock=>M,
          lastblock=>LastBlock
         }
       );
    _ ->
      mychain(
        maps:remove(
          tmpblock,
          State#{lastblock=>LastBlock}
         )
       )
  end.

mychain() ->
  KeyDB=chainsettings:by_path([keys]),
  NodeChain=chainsettings:by_path([nodechain]),
  PubKey=nodekey:get_pub(),
  %lager:info("My key ~s", [bin2hex:dbin2hex(PubKey)]),
  ChainNodes0=maps:fold(
                fun(Name, XPubKey, Acc) ->
                    maps:put(XPubKey, Name, Acc)
                end, #{}, KeyDB),
  MyName=maps:get(PubKey, ChainNodes0, undefined),
  MyChain=maps:get(MyName, NodeChain, 0),
  ChainNodes=maps:filter(
               fun(_PubKey, Name) ->
                   maps:get(Name, NodeChain, 0) == MyChain
               end, ChainNodes0),
  {MyChain, MyName, ChainNodes}.

mychain(State) ->
  {MyChain, MyName, ChainNodes}=mychain(),
  lager:info("My name ~p chain ~p ournodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
  maps:merge(State,
             #{myname=>MyName,
               chainnodes=>ChainNodes,
               mychain=>MyChain
              }).

