-module(ledger_sync).

-export([run_source/4,
         run_target/4,
         target/5,
         synchronizer/5]).

call(TPIC, Handler, Object, Atoms) ->
    Res=tpic:call(TPIC, Handler, msgpack:pack(Object)),
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
    lager:debug("Sync tgt ~p",[R]),

    gen_server:call(LedgerPID, '_flush'),
    lager:debug("TgtSync start",[]),
    Result0=continue(TPIC,LedgerPID,R,Parent,[]),
    {Result,Settings0}=lists:foldl(
                        fun({settings, List}, {RAcc,SAcc}) ->
                                {RAcc,[List|SAcc]};
                           (Res, {RAcc,SAcc}) ->
                                {[Res|RAcc],SAcc}
                        end, {[],[]}, Result0),
    Settings=lists:flatten(Settings0),
    lager:debug("TgtSync done ~p",[Result]),
    Parent ! {inst_sync,settings,Settings},
    Parent ! {inst_sync,done,Result}.


continue(TPIC,LedgerPID,[{Handler,Res}],Parent,Acc) ->
    lager:debug("sync continue ~p",[Res]),
    case Res of
        #{<<"block">>:=BinBlock} ->
            %#{hash:=Hash,header:=#{ledger_hash:=LH,height:=Height}}=Block=block:unpack(BinBlock),
            %lager:info("Got block ~p ~s~n",[Height,bin2hex:dbin2hex(Hash)]),
            %lager:info("Block's Ledger ~s~n",[bin2hex:dbin2hex(LH)]),
            Parent ! {inst_sync, block, BinBlock},
            R=call(TPIC, Handler, #{null=><<"continue">>}, []),
            continue(TPIC,LedgerPID,R,Parent,Acc);
        #{<<"done">>:=_Done, <<"settings">>:=L} ->
            Parent ! {inst_sync, settings},
            R=call(TPIC,Handler, #{null=><<"continue">>}, []),
            continue(TPIC,LedgerPID,R,Parent,[{settings,L}|Acc]);
        #{<<"done">>:=Done, <<"ledger">>:=L} ->
            gen_server:call(LedgerPID,
                            {put, maps:fold(
                                    fun(K,V,A) ->
                                            [{K,bal:unpack(V)}|A]
                                    end, [], L)}),
            lager:info("L ~w~n",[maps:size(L)]),
            Parent ! {inst_sync, ledger},
            case Done of
                false  ->
                    R=call(TPIC,Handler, #{null=><<"continue">>}, []),
                    continue(TPIC,LedgerPID,R,Parent,Acc);
                true ->
                    %{ok,C}=gen_server:call(LedgerPID, {check, []}),
                    %lager:info("My Ledger hash ~s",[bin2hex:dbin2hex(C)]),
                    [done|Acc]
            end;
        _Any ->
            lager:info("Unknown res ~p",[_Any]),
            [{error, unknown}|Acc]
    end.



%%% sync source

run_source(TPIC, PeerID, LastBlock, Settings) ->
    {_,_}=Snap=gen_server:call(ledger, snapshot),
    erlang:spawn(?MODULE, synchronizer,
                 [ TPIC, PeerID, LastBlock, Snap, Settings]).

synchronizer(TPIC, PeerID,
             #{hash:=Hash,header:=#{height:=Height}}=Block,
             {DBH,Snapshot},
             Settings) ->
    {ok, Itr} = rocksdb:iterator(DBH, [{snapshot, Snapshot}]),
    Total=rocksdb:count(DBH),
    lager:info("TPIC ~p Peer ~p bh ~p, db ~p total ~p",
               [TPIC, PeerID, {Height, Hash}, {DBH,Snapshot}, Total]),
    Patches=settings:get_patches(Settings),
    lager:info("Patches ~p",[Patches]),
    %file:write_file("tmp/syncblock.txt",
    %                io_lib:format("~p.~n",[Block])),
    BlockParts = split_packet(1024, msgpack:pack(#{block=>block:pack(Block)})),
    tpic:cast(TPIC, PeerID, msgpack:pack(#{block=>block:pack(Block)})),
    SP1=send_settings(TPIC,PeerID,Patches),
    if SP1 == done ->
           SP2=send_ledger(TPIC,PeerID,first,Itr),
           lager:info("Sync finished: ~p / ~p",[SP1,SP2]);
       true ->
           lager:info("Sync interrupted ~p",[SP1])
    end,
    rocksdb:release_snapshot(Snapshot).

pick_settings(Settings, N) ->
    LS=length(Settings),
    if(N>=LS) ->
          {Settings,[]};
      true ->
          lists:split(N,Settings)
    end.

send_settings(TPIC,PeerID,Settings) ->
    lager:info("send_settings"),
    receive
        {'$gen_cast',{tpic,PeerID,Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null:=<<"stop">>}} ->
                    tpic:cast(TPIC, PeerID, msgpack:pack(#{null=><<"stopped">>})),
                    interrupted;
                {ok, #{null:=<<"continue">>}} ->
                    {ToSend,Rest} = pick_settings(Settings, 5),
                    lager:info("Sending patches ~p",[ToSend]),
                    if(Rest == []) -> %last portion
                          Blob=#{done=>false,settings=>ToSend},
                          tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
                          done;
                      true -> %Have more
                          Blob=#{done=>false,settings=>ToSend},
                          tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
                          send_settings(TPIC,PeerID,Rest)
                    end;
                {error, _} ->
                    error
            end;
        {'$gen_cast',Any} ->
            lager:info("Unexpected message ~p",[Any])
    after 30000 ->
              tpic:cast(TPIC, PeerID, msgpack:pack(#{null=><<"stopped">>})),
              timeout
    end.

send_ledger(TPIC,PeerID,Act,Itr) ->
    receive
        {'$gen_cast',{tpic,PeerID,Bin}} ->
            case msgpack:unpack(Bin) of
                {ok, #{null:=<<"stop">>}} ->
                    tpic:cast(TPIC, PeerID, msgpack:pack(#{null=><<"stopped">>})),
                    interrupted;
                {ok, #{null:=<<"continue">>}} ->
                    case pickx(Act, Itr, 1000, []) of
                        {ok, L} ->
                            Blob=#{done=>false,ledger=>maps:from_list(L)},
                            tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
                            send_ledger(TPIC,PeerID,next,Itr);
                        {error, L} ->
                            Blob=#{done=>true,ledger=>maps:from_list(L)},
                            tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
                            done
                    end;
                {error, _} ->
                    error
            end;
        {'$gen_cast',Any} ->
            lager:info("Unexpected message ~p",[Any])
    after 30000 ->
              tpic:cast(TPIC, PeerID, msgpack:pack(#{null=><<"stopped">>})),
              timeout
    end.


pickx(_, _, 0, A) -> {ok,A};
pickx(Act, Itr, N, A) ->
    case rocksdb:iterator_move(Itr, Act) of
        {ok, <<"lb:",_/binary>>, _} ->
            pickx(next, Itr,N, A);
        {ok, <<"lastblk">>, _} ->
            pickx(next, Itr,N, A);
        {ok, K, V} ->
            pickx(next, Itr,N-1,
                  [{K,bal:pack(binary_to_term(V))}|A]);
        {error, _} ->
            {error,A}
    end.

split_packet(Size, Data) ->
  split_packet(Size, Data, 0).
split_packet(Size, Data, Seq) when Size > 0 ->
  case Data of
    <<Packet:Size/binary, Rest/binary>> ->
      [{Seq, Packet} | split_packet(Size, Rest, Seq + 1)];
    <<>> ->
      [];
    _ ->
      [{Seq, Data}]
  end.

glue_packet(List) ->
  SortedList = lists:sort(fun({N1, _}, {N2, _}) -> N1 =< N2 end, List),
  list_to_binary(lists:map(fun({_, Val}) -> Val end, SortedList)).