-module(genesis).
-export([genesis/0,new/1,settings/0]).

genesis() ->
    {ok,[Genesis]}=file:consult("genesis.txt"),
    Genesis.

new(HPrivKey) ->
    PrivKey=hex:parse(HPrivKey),
    Patch=settings:sign(settings(),PrivKey),
    Genesis=block:sign(
              block:mkblock(
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
              [{timestamp, os:system_time(millisecond)}],
              PrivKey
             ),
    file:write_file("genesis.txt", io_lib:format("~p.~n", [Genesis])),
    {ok,Genesis}.

settings() ->
      [
       #{t=>set,p=>[globals,patchsigs], v=>2},
       #{t=>set,p=>[chains], v=>[0]},
       #{t=>set,p=>[chain,0,minsig], v=>2},
       #{t=>set,p=>[chain,0,blocktime], v=>5},
%       #{t=>set,p=>[chain,0,nodes], v=>[<<"node1">>,<<"node2">>,<<"node3">>]},
       #{t=>set,p=>[keys,node1], v=>hex:parse("035AE7DF4FCB5B97A86FCEBB107D440858DDFB28C708E70E06C625AA210E8A6F16") },
       #{t=>set,p=>[keys,node2], v=>hex:parse("020783EF674851FCE9BED45B494D838C6B5F394F175B37DD26A511F29E1F21394B") },
       #{t=>set,p=>[keys,node3], v=>hex:parse("0260CC110AF0A34E7CD51C287320612F017B52AABBEA8EBFA619CF94FDE823C36C") }
       #{t=>set,p=>[nodechain], v=>#{node1=>0, node2=>0, node3=>0 } }
      ].

