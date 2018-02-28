-module(cfgen).
-export([main/1,run/0,run/2,get_key/2,genesis/0,genesis/2]).

main(["conf"++_,Config,Dir]) ->
    run(Config,Dir);

main(["gen"++_,Config,Dir]) ->
    genesis(Config,Dir);

main(_) ->
    io:format("Usage: ~n"),
    io:format("\tconf[iguration] <config.filename> <output dir>~n"),
    io:format("\tgen[esis] <config.filename> <output dir>~n"),
    ok.
    

run() ->
    run("testnet.config","configs").
genesis() ->
    genesis("testnet.config","configs").


run(Config,Dir) ->
    {ok,Configuration}=file:consult(Config),
    Script=lists:foldl(
      fun({Chain,Global,Nodes},NK) ->
              lists:foldl(
                fun({Node, Settings}, ANK) ->
                        Filename=Dir++"/"++atom_to_list(Node)++".config",
                        Peers=lists:foldl(
                                fun({PNode,_PCfg},Acc) when PNode==Node ->
                                        Acc;
                                   ({_PNode,PCfg},Acc) ->
                                        Get=fun(Key,Default) ->
                                                    case proplists:get_value(Key,PCfg) of
                                                        undefined ->
                                                            proplists:get_value(Key,Global,Default);
                                                        Found -> Found
                                                    end
                                            end,
                                        Port=Get(tpic_port,43210),
                                        lists:foldl(
                                            fun(PAddr, AAcc) ->
                                                    [{PAddr,Port}|AAcc]
                                            end, Acc, 
                                            [hd(
                                            proplists:get_value(address,PCfg)
                                              )]
                                         )
                                end,[], Nodes),
                        CFG=ncfg(Node, Chain,Global,Settings,Peers, Dir),
                        file:write_file(Filename, 
                                        [
                                        io_lib:format("~p.~n",[Section]) ||
                                        Section <- CFG 
                                        ]
                                       ),
                        [
                        io_lib:format("scp configs/genesis.txt \"root@[~s]:thepower/genesis.txt\"~n",
                                  [hd(proplists:get_value(address,Settings))]),
                        io_lib:format("scp ~s \"root@[~s]:thepower/node.config\"~n",
                                  [Filename,hd(proplists:get_value(address,Settings))]) | ANK]
                end, NK, Nodes)
      end, [], Configuration),
    file:write_file("upload.sh",[<<"#!/bin/sh\n">>,Script]).
    %mkgenesis(NKeys).

genesis(Config,Dir) ->
    {ok,Configuration}=file:consult(Config),
    NKeys=lists:foldl(
      fun({Chain,_Global,Nodes},NK) ->
              lists:foldl(
                fun({Node, _Settings}, ANK) ->
                        [{Node,Chain,get_key(Node,Dir)}|ANK]
                end, NK, Nodes)
      end, [], Configuration),
    mkgenesis(NKeys,Dir).

get_key(Node,Dir) ->
    Filename=Dir++"/"++atom_to_list(Node)++".key",
    case file:read_file(Filename) of
        {error,enoent} ->
            PK=tpecdsa:generate_priv(),
            file:write_file(Filename,PK),
            PK;
        {ok,PK} ->
            PK
    end.

ncfg(Node, _Chain, Global, Local, Peers, Dir) ->
    Get=fun(Key,Default) ->
                case proplists:get_value(Key,Local) of
                    undefined ->
                        proplists:get_value(Key,Global,Default);
                    Found -> Found
                end
        end,
    [
     {tpic, #{
        port=>Get(tpic_port,43299),
        peers=>[hd(Peers)]
       }
     },
     {discovery, #{ 
        addresses => [  
                      #{
          address => hd(Get(address,["127.0.0.1"])),
          port => Get(tpic_port,43299),
          proto => tpic
         }
                     ]
       }
     },
     {privkey, 
      binary_to_list(bin2hex:dbin2hex(get_key(Node,Dir)))
     }
    ]++Global++proplists:get_value(raw,Local,[]).



mkgenesis(NodeKeys,Dir) ->
    NKeys=lists:foldl(
                 fun({NodeName,_,Key}, Acc) ->
                         [#{t=>set,p=>[keys,NodeName], v=>tpecdsa:calc_pub(Key,true) }|Acc]
                 end, [], NodeKeys),
    NChain=lists:foldl(
             fun({NodeName,Chain,_}, Acc) ->
                     maps:put(NodeName,Chain,Acc)
             end, #{}, NodeKeys),
    ChainList=lists:foldl(
        fun({_,Chain,_}, Acc) ->
                maps:put(Chain,maps:get(Chain,Acc,0)+1,Acc)
        end, #{}, NodeKeys),
    Chains=maps:fold(
             fun(ChainNo,Members,Acc) ->
                     [
                      #{t=>set,p=>[chain,ChainNo,minsig], v=>erlang:ceil(Members/2)},
                      #{t=>set,p=>[chain,ChainNo,blocktime], v=>2},
                      #{t=>set,p=>[chain,ChainNo,allowempty], v=>0}
                     | Acc ]
             end, [], ChainList),
    S=settings:mp(
      [
       #{t=>set,p=>[globals,patchsigs], v=>4},
       #{t=>set,p=>[chains], v=>maps:keys(ChainList)},
       %#{t=>set,p=>[keys,node3], v=>hex:parse("0260CC110AF0A34E7CD51C287320612F017B52AABBEA8EBFA619CF94FDE823C36C") }
       #{t=>set,p=>[nodechain], v=>NChain }
      ]++Chains++NKeys),
    Patch=lists:foldl(
      fun({_,_,Key}, Set) ->
              settings:sign(Set,Key)
      end, S, NodeKeys),
    Block=block:mkblock(
            #{ parent=><<0,0,0,0,0,0,0,0>>,
               height=>0,
               txs=>[],
               bals=>#{},
               settings=>[
                          {
                           bin2hex:dbin2hex(crypto:strong_rand_bytes(16)),
                           Patch
                          }
                         ],
               sign=>[]
             }),
    #{settings:=[{_,#{patch:=OutSet}}]}=Genesis=lists:foldl(
      fun({_,_,Key}, ABlock) ->
              block:sign(ABlock,
              [{timestamp, os:system_time(millisecond)}],
              Key
             )
      end, Block, NodeKeys),
    file:write_file(Dir++"/genesis.txt", io_lib:format("~p.~n", [Genesis])),
    %settings:patch( settings:dmp( maps:get(patch, element(2, hd()))),#{}).
    settings:patch(OutSet,#{}).

