-module(genesis).
-export([genesis/0, new/1, settings/0]).

genesis() ->
    {ok, [Genesis]}=file:consult(application:get_env(tpnode,genesis,"genesis.txt")),
    Genesis.

new(HPrivKey) ->
    PrivKey=hex:parse(HPrivKey),
    Patch=settings:sign(settings(), PrivKey),
    Genesis=block:sign(
              block:mkblock(
                #{ parent=><<0, 0, 0, 0, 0, 0, 0, 0>>,
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
              [{timestamp, os:system_time(millisecond)}],
              PrivKey
             ),
    file:write_file("genesis.txt", io_lib:format("~p.~n", [Genesis])),
    {ok, Genesis}.

settings() ->
      settings:mp(
        [
         #{t=>set, p=>[globals, patchsigs], v=>2},
         #{t=>set, p=>[chains], v=>[0]},
         #{t=>set, p=>[chain, 0, minsig], v=>2},
         #{t=>set, p=>[chain, 0, blocktime], v=>7},
         #{t=>set, p=>[nodechain], v=>#{node1=>0, node2=>0, node3=>0 } }
        ]).

