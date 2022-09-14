-module(ledger_sync).
-include("include/tplog.hrl").

-export([run_source/4,
         run_target/4,
         target/5,
         synchronizer/5]).

call(_TPIC, Handler, Object, Atoms) ->
    Res=tpic2:call(Handler, msgpack:pack(Object)),
    lists:filtermap(
      fun({Peer, Bin}) ->
              case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
                  {ok, Decode} ->
                      {true, {Peer, Decode}};
                  _ -> false
              end
      end, Res).

%%% sync destination
run_target(TPIC, PeerID, Ledger, BlockChainRDB) ->
    erlang:spawn(?MODULE, target,
                 [ TPIC, PeerID, Ledger, BlockChainRDB, self()]).

target(TPIC, PeerID, LedgerPID, _RDB, Parent) ->
    R=call(TPIC, PeerID,
           #{null=><<"instant_sync_run">>},
           []
          ),
    ?LOG_DEBUG("Sync tgt ~p", [R]),

    gen_server:call(LedgerPID, '_flush'),
    ?LOG_DEBUG("TgtSync start", []),
    Result0 = continue(TPIC, LedgerPID, R, Parent, [], []),
    {Result, Settings0}=lists:foldl(
                        fun({settings, List}, {RAcc, SAcc}) ->
                                {RAcc, [List|SAcc]};
                           (Res, {RAcc, SAcc}) ->
                                {[Res|RAcc], SAcc}
                        end, {[], []}, Result0),
    Settings=lists:flatten(Settings0),
    ?LOG_DEBUG("TgtSync done ~p", [Result]),
    Parent ! {inst_sync, settings, Settings},
    Parent ! {inst_sync, done, Result}.


continue(TPIC, LedgerPID, [{Handler, Res}], Parent, Acc, BlockAcc) ->
    ?LOG_DEBUG("sync continue ~p", [Res]),
    case Res of
        #{<<"done">> := _Done, <<"block">> := BlockPart} ->
            %#{hash:=Hash, header:=#{ledger_hash:=LH, height:=Height}}=Block=block:unpack(BinBlock),
            %?LOG_INFO("Got block ~p ~s~n", [Height, bin2hex:dbin2hex(Hash)]),
            %?LOG_INFO("Block's Ledger ~s~n", [bin2hex:dbin2hex(LH)]),
            <<Number:32, Length:32, _/binary>> = BlockPart,
            NewBlockAcc = [BlockPart|BlockAcc],
            if (length(NewBlockAcc) == Length) ->
                    BinBlock = block:glue_packet(NewBlockAcc),
                    %?LOG_DEBUG("The block is ~p", [BinBlock]),
                    %?LOG_DEBUG("unpacked block is ~p", [block:unpack(BinBlock)]),
                    Parent ! {inst_sync, block, BinBlock};
                true ->
                    ?LOG_DEBUG("Received part number ~p out of ~p", [Number, Length])
            end,
            R = call(TPIC, Handler, #{null => <<"continue">>}, []),
            continue(TPIC, LedgerPID, R, Parent, Acc, NewBlockAcc);
        #{<<"done">>:=_Done, <<"settings">>:=L} ->
            Parent ! {inst_sync, settings},
            R=call(TPIC, Handler, #{null=><<"continue">>}, []),
            continue(TPIC, LedgerPID, R, Parent, [{settings, L}|Acc], BlockAcc);
        #{<<"done">>:=Done, <<"ledger">>:=L} ->
            gen_server:call(LedgerPID,
                            {put, maps:fold(
                                    fun(K, V, A) ->
                                        CL=mbal:unpack(V),
                                            [{K, CL}|A]
                                    end, [], L), ublk}),
            ?LOG_INFO("L ~w~n", [maps:size(L)]),
            Parent ! {inst_sync, ledger},
            case Done of
                false  ->
                    R=call(TPIC, Handler, #{null=><<"continue">>}, []),
                    continue(TPIC, LedgerPID, R, Parent, Acc, BlockAcc);
                true ->
                    %{ok, C}=gen_server:call(LedgerPID, {check, []}),
                    %?LOG_INFO("My Ledger hash ~s", [bin2hex:dbin2hex(C)]),
                    [done|Acc]
            end;
        _Any ->
            ?LOG_INFO("Unknown res ~p", [_Any]),
            [{error, unknown}|[Acc|BlockAcc]]
    end.



%%% sync source

run_source(TPIC, PeerID, LastBlock, Settings) ->
    {_, _}=Snap=gen_server:call(ledger, snapshot),
    erlang:spawn(?MODULE, synchronizer,
                 [ TPIC, PeerID, LastBlock, Snap, Settings]).

synchronizer(TPIC, PeerID,
             #{hash:=Hash, header:=#{height:=Height}}=Block,
             {DBH, Snapshot},
             Settings) ->
    {ok, Itr} = rocksdb:iterator(DBH, [{snapshot, Snapshot}]),
    Total=try rocksdb:count(DBH) catch _:_ -> unknown end,
    ?LOG_INFO("TPIC ~p Peer ~p bh ~p, db ~p total ~p",
               [TPIC, PeerID, {Height, Hash}, {DBH, Snapshot}, Total]),
    Patches=settings:get_patches(Settings),
    ?LOG_INFO("Patches ~p", [Patches]),
    %file:write_file("tmp/syncblock.txt",
    %                io_lib:format("~p.~n", [Block])),
    BlockParts = block:split_packet(block:pack(Block)),
    [BlockHead|BlockTail] = BlockParts,
    tpic2:cast(PeerID, msgpack:pack(#{done => false, block => BlockHead})),
    BlockSent = send_block(TPIC, PeerID, BlockTail),
    if BlockSent == done ->
        SP1 = send_settings(TPIC, PeerID, Patches),
        if SP1 == done ->
                SP2 = send_ledger({DBH, Snapshot}, TPIC, PeerID, first, Itr),
                ?LOG_INFO("Sync finished: ~p / ~p", [SP1, SP2]);
            true ->
                ?LOG_INFO("Sync interrupted while sending settings ~p", [SP1])
        end;
        true ->
            ?LOG_INFO("Sync interrupted while sending block ~p", [BlockSent])
    end,
    rocksdb:release_snapshot(Snapshot).

pick_settings(Settings, N) ->
    LS=length(Settings),
    if(N>=LS) ->
          {Settings, []};
      true ->
          lists:split(N, Settings)
    end.

send_block(_, _, []) ->
    done;
send_block(TPIC, PeerID, Block) ->
    ?LOG_INFO("send_block"),
    receive
        {'$gen_cast', {tpic, PeerID, Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null := <<"stop">>}} ->
                    tpic2:cast(PeerID, msgpack:pack(#{null => <<"stopped">>})),
                    interrupted;
                {ok, #{null := <<"continue">>}} ->
                    [ToSend|Rest] = Block,
                    ?LOG_INFO("Sending block ~p", [ToSend]),
                    if (Rest == []) -> %last portion
                            Blob =# {done => false, block => ToSend},
                            tpic2:cast(PeerID, msgpack:pack(Blob)),
                            done;
                        true -> %Have more
                            Blob =# {done => false, block => ToSend},
                            tpic2:cast(PeerID, msgpack:pack(Blob)),
                            send_block(TPIC, PeerID, Rest)
                    end;
                {error, _} ->
                    error
            end;
        {'$gen_cast', Any} ->
            ?LOG_INFO("Unexpected message ~p", [Any])
    after 30000 ->
        tpic2:cast(PeerID, msgpack:pack(#{null => <<"stopped">>})),
        timeout
    end.

send_settings(TPIC, PeerID, Settings) ->
    ?LOG_INFO("send_settings"),
    receive
        {'$gen_cast', {tpic, PeerID, Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null:=<<"stop">>}} ->
                    tpic2:cast(PeerID, msgpack:pack(#{null=><<"stopped">>})),
                    interrupted;
                {ok, #{null:=<<"continue">>}} ->
                    {ToSend, Rest} = pick_settings(Settings, 5),
                    ?LOG_INFO("Sending patches ~p", [ToSend]),
                    if(Rest == []) -> %last portion
                          Blob=#{done=>false, settings=>ToSend},
                          tpic2:cast(PeerID, msgpack:pack(Blob)),
                          done;
                      true -> %Have more
                          Blob=#{done=>false, settings=>ToSend},
                          tpic2:cast(PeerID, msgpack:pack(Blob)),
                          send_settings(TPIC, PeerID, Rest)
                    end;
                {error, _} ->
                    error
            end;
        {'$gen_cast', Any} ->
            ?LOG_INFO("Unexpected message ~p", [Any])
    after 30000 ->
              tpic2:cast(PeerID, msgpack:pack(#{null=><<"stopped">>})),
              timeout
    end.

send_ledger(DB, TPIC, PeerID, Act, Itr) ->
    receive
        {'$gen_cast', {tpic, PeerID, Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null:=<<"stop">>}} ->
                    tpic2:cast(PeerID, msgpack:pack(#{null=><<"stopped">>})),
                    interrupted;
                {ok, #{null:=<<"continue">>}} ->
                    case pickx(DB, Act, Itr, 1000, []) of
                        {ok, L} ->
                            Blob=#{done=>false, ledger=>maps:from_list(L)},
                            tpic2:cast(PeerID, msgpack:pack(Blob)),
                            send_ledger(DB, TPIC, PeerID, next, Itr);
                        {error, L} ->
                            Blob=#{done=>true, ledger=>maps:from_list(L)},
                            tpic2:cast(PeerID, msgpack:pack(Blob)),
                            done
                    end;
                {error, _} ->
                    error
            end;
        {'$gen_cast', Any} ->
            ?LOG_INFO("Unexpected message ~p", [Any])
    after 30000 ->
              tpic2:cast(PeerID, msgpack:pack(#{null=><<"stopped">>})),
              timeout
    end.


pickx(_, _, _, 0, A) -> {ok, A};
pickx({DBH, Snapshot}=DB, Act, Itr, N, A) ->
  case rocksdb:iterator_move(Itr, Act) of
    {ok, <<"lb:", _/binary>>, _} ->
      pickx(DB, next, Itr, N, A);
    {ok, <<"lastblk">>, _} ->
      pickx(DB, next, Itr, N, A);
    {ok, K, V} ->
      V0=binary_to_term(V),
      ?LOG_NOTICE("FX ME here"),
      V1=case rocksdb:get(DBH, <<"lb:", K/binary>>, [{snapshot, Snapshot}]) of
           {ok, LBH} ->
             ?LOG_NOTICE("LB ~p",[LBH]),
             V0#{ ublk=>LBH };
           _ ->
             ?LOG_NOTICE("LB none"),
             V0
         end,
      pickx(DB, next, Itr, N-1, [{K, mbal:pack(V1,true)}|A]);
    {error, _} ->
      {error, A}
  end.

