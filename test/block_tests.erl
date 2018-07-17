-module(block_tests).

-include_lib("eunit/include/eunit.hrl").


block_test_() ->
  Priv1Key= <<200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100,
              200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100>>,
  Priv2Key= <<200, 300, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100,
              200, 300, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100>>,
  Pub1=tpecdsa:calc_pub(Priv1Key, true),
  Pub2=tpecdsa:calc_pub(Priv2Key, true),
  RPatch=[
          #{t=>set, p=>[globals, patchsigs], v=>2},
          #{t=>set, p=>[chains], v=>[0]},
          #{t=>set, p=>[chain, 0, minsig], v=>2},
          #{t=>set, p=>[keys, node1], v=>Pub1},
          #{t=>set, p=>[keys, node2], v=>Pub2},
          #{t=>set, p=>[nodechain], v=>#{node1=>0, node2=>0 } }
         ],
  SPatch1= settings:sign(RPatch, Priv1Key),
  SPatch2= settings:sign(SPatch1, Priv2Key),
  lager:info("SPatch ~p", [SPatch2]),
  NewB=block:mkblock(#{ parent=><<0, 0, 0, 0, 0, 0, 0, 0>>,
                  height=>0,
                  txs=>[],
                  bals=>#{},
                  mychain=>100500,
                  settings=>[
                             {
                              <<"patch123">>,
                              SPatch2
                             }
                            ],
                  sign=>[]
                }
              ),
  Block=block:sign(block:sign(NewB, Priv1Key), Priv2Key),
  Repacked=block:unpack(block:pack(Block)),
  [
   ?_assertMatch({true, {_, 0}}, block:verify(Block)),
   ?_assertEqual(block:packsig(Block), block:packsig(Repacked)),
   ?_assertEqual(block:unpacksig(Block), Repacked),
   ?_assertEqual(block:unpacksig(Block), block:unpacksig(Repacked)),
   ?_assertEqual(Block, block:packsig(Repacked)),
   ?_assertEqual(true, lists:all(
                         fun(#{extra:=E}) ->
                             P=proplists:get_value(pubkey, E),
                             P==Pub2 orelse P==Pub1
                         end,
                         element(1, element(2, block:verify(Block))))
                ),
   ?_assertEqual([
                  <<0, 0, 0, 1, 0, 0, 0, 3, 1, 2>>,
                  <<0, 0, 0, 2, 0, 0, 0, 3, 3, 4>>,
                  <<0, 0, 0, 3, 0, 0, 0, 3, 5>>],
                 block:split_packet(2, <<1, 2, 3, 4, 5>>)
                ),
   %TODO: fix this test
   %?_assertEqual(split_packet(2, <<1, 2, 3, 4>>),
   %[
   %<<0, 0, 0, 1, 0, 0, 0, 3, 1, 2>>,
   %<<0, 0, 0, 2, 0, 0, 0, 3, 3, 4>>
   %]),
   ?_assertEqual([
                  <<0, 0, 0, 1, 0, 0, 0, 2, 1, 2, 3>>,
                  <<0, 0, 0, 2, 0, 0, 0, 2, 4>>
                 ], block:split_packet(3, <<1, 2, 3, 4>>)),
   ?_assertEqual([], block:split_packet(2, <<>>)),
   ?_assertEqual(<<>>, block:glue_packet([])),
   ?_assertEqual(<<1, 2, 3, 4>>, 
                 block:glue_packet([
                                    <<0, 0, 0, 1, 0, 0, 0, 2, 1, 2>>,
                                    <<0, 0, 0, 2, 0, 0, 0, 2, 3, 4>>
                                   ])),
   ?_assertThrow(broken, 
                 block:glue_packet([
                                    <<0, 0, 0, 1, 0, 0, 0, 3, 1, 2>>,
                                    <<0, 0, 0, 2, 0, 0, 0, 3, 3, 4>>,
                                    <<0, 0, 0, 2, 0, 0, 0, 3, 5>>
                                   ])),
   ?_assertEqual(<<1, 2, 3, 4, 5>>, 
                 block:glue_packet([
                                    <<0, 0, 0, 1, 0, 0, 0, 3, 1, 2>>,
                                    <<0, 0, 0, 2, 0, 0, 0, 3, 3, 4>>,
                                    <<0, 0, 0, 3, 0, 0, 0, 3, 5>>
                                   ]))
  ].
