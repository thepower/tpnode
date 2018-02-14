-module(test_sync).
-export([run/0]).

run() ->
    [{Handler,_}|_]=tpic:call(tpic, <<"blockchain">>, 
                              msgpack:pack(#{null=><<"sync_request">>})
                             ),
    R=tpic:call(tpic, Handler,
              msgpack:pack(#{null=><<"sync_run">>})
             ),

    Name=test_sync_ledger,
    {ok,Pid}=ledger:start_link(
               [{filename, "db/ledger_test_sync"},
                {name, Name}
               ]
              ),
    gen_server:call(Pid, '_flush'),
    Result=cont(R),
    {ok,C}=gen_server:call(test_sync_ledger, {check, []}),
    gen_server:cast(Pid, terminate),
    io:format("My Ledger ~s~n",[bin2hex:dbin2hex(C)]),
    Result.


cont([{Handler,Res}]) ->
    case msgpack:unpack(Res) of
        {ok, #{<<"block">>:=BinBlock}} ->
            #{hash:=Hash,header:=#{ledger_hash:=LH,height:=Height}}=block:unpack(BinBlock),
            io:format("Got block ~p ~s~n",[Height,bin2hex:dbin2hex(Hash)]),
            io:format("Block's Ledger ~s~n",[bin2hex:dbin2hex(LH)]),
            R=tpic:call(tpic, Handler, <<"continue">>),
            cont(R);
        {ok, #{<<"done">>:=false, <<"ledger">>:=L}} ->
            l_apply(L), 
            io:format("L ~w/~w~n",[size(Res),maps:size(L)]),
            R=tpic:call(tpic, Handler, <<"continue">>),
            cont(R);
        {ok, #{<<"done">>:=true, <<"ledger">>:=L}} ->
            l_apply(L), 
            io:format("L ~w/~w~n",[size(Res),maps:size(L)]),
            io:format("Done~n"),
            tpic:cast(tpic, Handler, <<"stop">>),
            done
    end.


l_apply(L) ->
    gen_server:call(test_sync_ledger, 
                    {put, maps:fold(
                            fun(K,V,A) ->
                                    [{K,bal:unpack(V)}|A]
                            end, [], L)}).

