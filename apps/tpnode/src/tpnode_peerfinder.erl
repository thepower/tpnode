-module(tpnode_peerfinder).

-export([propose_seed/2,propose_tpic/2,check_peers/2,check_peer/1]).

propose_seed(Chain,_Opts) ->
  Peers=maps:fold(
          fun(_Name,V=#{<<"pubkey">>:=PK},A) ->
              LL=maps:get(<<"host">>,V,[]),
              Hosts=lists:foldl(
                      fun(P,Acc) ->
                          Parsed=uri_string:parse(P),
                          PreQ=maps:get(query,Parsed,<<>>),
                          Q1=case PreQ of
                               <<>> ->
                                 ["pubkey=0x",hex:encode(PK)];
                               _ ->
                                 ["&pubkey=0x",hex:encode(PK)]
                             end,
                          %Q2=["genesis=",base64url:encode(crypto:strong_rand_bytes(32)),"&"|Q1],
                          [uri_string:recompose(Parsed#{query=>Q1})
                           |Acc]
                      end,[],LL),
              [lists:usort(Hosts)|A]
          end,
          [],
          tpapi2_discovery:get_nodes(undefined,Chain)
         ),
  tpapi2:sort_peers(Peers).

check_peer([]) ->
  [];
check_peer([E|Rest]) ->
  case tpapi2:nodestatus(E) of
    {ok, Status} ->
      [{E,Status}];
    {error, Err} ->
      logger:notice("checkpeer ~p error ~p",[E,Err]),
      check_peer(Rest)
  end.

check_peers(List,N) ->
  check_peers(tpapi2:sort_peers(List),[],N).

check_peers(_,Acc,0) ->
  Acc;
check_peers([],Acc,_) ->
  Acc;
check_peers([Peer1|Rest],Acc,N) ->
  case check_peer(tpapi2:sort_peers(Peer1)) of
    [{E,_}] ->
      check_peers(Rest,[E|Acc],N-1);
    [] ->
      check_peers(Rest,Acc,N)
  end.



propose_tpic(Chain,Port) ->
  maps:fold(fun(_Name,V=#{<<"pubkey">>:=PK},A) ->
                LL=maps:get(<<"ip">>,V,[]),
                Hosts=lists:foldl(
                        fun(P,Acc) ->
                            #{host:=H}=uri_string:parse(P),
                            [{H,Port}|Acc]
                        end,[],LL),
                [{PK,lists:usort(Hosts)}|A]
            end,
            [],
            tpapi2_discovery:get_nodes(undefined,Chain)
           ).

