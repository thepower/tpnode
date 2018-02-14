-module(test_sync).
-export([run/0,test1/0]).

call(Handler, Object, Atoms) ->
    Res=tpic:call(tpic, Handler, msgpack:pack(Object)),
    lists:filtermap(
      fun({Peer, Bin}) ->
              case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of 
                  {ok, Decode} -> 
                      {true, {Peer, Decode}};
                  _ -> false
              end
      end, Res).

test1() ->
    %block by block synchromization
    [{Handler,Candidate}|_]=call(<<"blockchain">>, 
                                 #{null=><<"sync_request">>},
                                 [last_hash,last_height,chain]
                                ),
    #{null:=Avail,
      chain:=Chain,
      last_hash:=Hash,
      last_height:=Height}=Candidate,
    io:format("~s chain ~w h= ~w hash= ~s ~n",
              [ Avail, Chain, Height, bin2hex:dbin2hex(Hash) ]),
    test1(Handler,Hash,20).


test1(_,_,0) ->
    done_limit;
test1(Handler,Hash,Rest) ->
    [{_,R}]=call(Handler,
                 #{null=><<"pick_block">>, <<"hash">>=>Hash, <<"rel">>=>prev},
                 [block]
                ),
    case maps:is_key(block, R) of
        false -> 
            done_no_block;
        true ->
            BinBlk=maps:get(block,R),
            Blk=block:unpack(BinBlk),
            #{header:=#{height:=Height}=Hdr,hash:=HH}=Blk,
            io:format("Res ~p~nBlock ~6w (~6w KB) ~s~n",
                      [ maps:without([<<"req">>,block],R), 
                        Height,
                        size(BinBlk) div 1024,
                        bin2hex:dbin2hex(HH)
                      ]),
            case maps:is_key(parent,Hdr) of
                true ->
                    test1(Handler,HH,Rest-1);
                false ->
                    done_no_parent
            end
    end.


run() ->
    %instant synchronization
    [{Handler,Candidate}|_]=call(<<"blockchain">>, 
                                 #{null=><<"sync_request">>},
                                 [last_hash,last_height,chain]
                                ),
    #{null:=Avail,
      chain:=Chain,
      last_hash:=Hash,
      last_height:=Height}=Candidate,
    io:format("~s chain ~w h= ~w hash= ~s ~n",
              [ Avail, Chain, Height, bin2hex:dbin2hex(Hash) ]),
    R=call(Handler,
           #{null=><<"instant_sync_run">>},
           []
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
    case Res of
        #{<<"block">>:=BinBlock} ->
            #{hash:=Hash,header:=#{ledger_hash:=LH,height:=Height}}=block:unpack(BinBlock),
            io:format("Got block ~p ~s~n",[Height,bin2hex:dbin2hex(Hash)]),
            io:format("Block's Ledger ~s~n",[bin2hex:dbin2hex(LH)]),
            R=call(Handler, #{null=><<"continue">>}, []),
            cont(R);
        #{<<"done">>:=false, <<"ledger">>:=L} ->
            l_apply(L), 
            io:format("L ~w~n",[maps:size(L)]),
            R=call(Handler, #{null=><<"continue">>}, []),
            cont(R);
        #{<<"done">>:=true, <<"ledger">>:=L} ->
            l_apply(L), 
            io:format("L ~w~n",[maps:size(L)]),
            io:format("Done~n"),
            done
    end.


l_apply(L) ->
    gen_server:call(test_sync_ledger, 
                    {put, maps:fold(
                            fun(K,V,A) ->
                                    [{K,bal:unpack(V)}|A]
                            end, [], L)}).

