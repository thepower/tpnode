-module(ledger_sync).

-export([run/3,
         synchronizer/4]).


run(TPIC, PeerID, {BlockHeight, BlockHash}) ->
    {_,_}=Snap=gen_server:call(ledger, snapshot),
    erlang:spawn(?MODULE, synchronizer, 
                 [ TPIC, PeerID, {BlockHeight, BlockHash}, Snap]).

synchronizer(TPIC, PeerID, {BlockHeigh, BlockHash}, {DBH,Snapshot}) ->
    {ok, Itr} = rocksdb:iterator(DBH, [{snapshot, Snapshot}]),
    Total=rocksdb:count(DBH),
    lager:info("TPIC ~p Peer ~p bh ~p, db ~p total ~p",
               [TPIC, PeerID, {BlockHeigh, BlockHash}, {DBH,Snapshot},
               Total]),

%    L1=pickx(first, Itr, 20, []),
%    lager:info("L = ~p",[L1]),
%    timer:sleep(100),
%    L2=pickx(next, Itr, 20, []),
%    lager:info("L = ~p",[L2]),
    SP=send_part(TPIC,PeerID,first,Itr),

    lager:info("Sync finished: ~p",[SP]),
    rocksdb:release_snapshot(Snapshot).

send_part(TPIC,PeerID,Act,Itr) ->
    case pickx(Act, Itr, 1000, []) of
        {ok, L} ->
            Blob=#{done=>false,ledger=>maps:from_list(L)},
            lager:info("oL = ~p",[Blob]),
            tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
            receive
                {'$gen_cast',{tpic,_,<<"stop">>}} ->
                    interrupted;
                {'$gen_cast',{tpic,_,<<"continue">>}} ->
                    send_part(TPIC,PeerID,next,Itr);
                {'$gen_cast',Any} ->
                    lager:info("Unexpected message ~p",[Any])
            after 30000 ->
                      timeout
            end;
        {error, L} ->
            lager:info("eL = ~p",[L]),
            Blob=#{done=>true,ledger=>maps:from_list(L)},
            lager:info("oL = ~p",[Blob]),
            tpic:cast(TPIC, PeerID, msgpack:pack(Blob)),
            done
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


    %io:format("R ~p~n",[Itr]),
    %Itr1=rocksdb:iterator_move(Itr, first),
    %io:format("R ~p~n",[Itr1]),
    %Itr2=rocksdb:iterator_move(Itr, next),
    %io:format("R ~p~n",[Itr2]),
    %rocksdb:iterator_close(Itr),



