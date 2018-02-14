-module(ledger_sync).

-export([run/4,
         synchronizer/5]).


run(TPIC, PeerID, LastBlock, Settings) ->
    {_,_}=Snap=gen_server:call(ledger, snapshot),
    erlang:spawn(?MODULE, synchronizer, 
                 [ TPIC, PeerID, LastBlock, Snap, Settings]).

synchronizer(TPIC, PeerID, 
             #{hash:=Hash,header:=#{height:=Height}}=Block, 
             {DBH,Snapshot},
             _Settings) ->
    lager:info("Settings ~p",[_Settings]),
    {ok, Itr} = rocksdb:iterator(DBH, [{snapshot, Snapshot}]),
    Total=rocksdb:count(DBH),
    lager:info("TPIC ~p Peer ~p bh ~p, db ~p total ~p",
               [TPIC, PeerID, {Height, Hash}, {DBH,Snapshot},
               Total]),
    %file:write_file("syncblock.txt",
    %                io_lib:format("~p.~n",[Block])),
    tpic:cast(TPIC, PeerID, msgpack:pack(#{block=>block:pack(Block)})),
    SP=send_part(TPIC,PeerID,first,Itr),

    lager:info("Sync finished: ~p",[SP]),
    rocksdb:release_snapshot(Snapshot).

send_part(TPIC,PeerID,Act,Itr) ->
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
                            send_part(TPIC,PeerID,next,Itr);
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
        {ok, K, V} ->
            pickx(next, Itr,N-1, 
                  [{K,bal:pack(binary_to_term(V))}|A]);
        {error, _} ->
            {error,A}
    end.

