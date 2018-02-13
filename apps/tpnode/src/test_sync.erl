-module(test_sync).
-export([run/0]).

run() ->
    [{Handler,_}|_]=tpic:call(tpic, <<"blockchain">>, 
                              msgpack:pack(#{null=><<"sync_ledger_req">>})
                             ),
    R=tpic:call(tpic, Handler,
              msgpack:pack(#{null=><<"sync_ledger_run">>})
             ),
    cont(R).

cont([{Handler,Res}]) ->
    case msgpack:unpack(Res) of
        {ok, #{<<"done">>:=false, <<"ledger">>:=L}} ->
            io:format("L ~w/~w~n",[size(Res),maps:size(L)]),
            R=tpic:call(tpic, Handler, <<"continue">>),
            cont(R);
        {ok, #{<<"done">>:=true, <<"ledger">>:=L}} ->
            io:format("L ~w/~w~n",[size(Res),maps:size(L)]),
            io:format("Done~n"),
            tpic:cast(tpic, Handler, <<"stop">>),
            ok
    end.



