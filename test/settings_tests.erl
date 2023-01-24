-module(settings_tests).

-include_lib("eunit/include/eunit.hrl").

exists_test() ->
  TestPatch=settings:dmp(
              settings:mp(
                [
                 #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
                 #{t=>set, p=>[current, allocblock, group], v=>10},
                 #{t=>set, p=>[current, allocblock, block], v=>2},
                 #{t=>set, p=>[current, allocblock, last], v=>3}
                ])),
  ExTest=settings:patch(TestPatch, #{}),
  [
   ?assertException(throw,
                    {exist, [<<"current">>, <<"allocblock">>, <<"last">>]},
                    settings:patch(TestPatch, ExTest))
  ].

patch_sign_test() ->
  TestPriv1= <<8, 3, 173, 195, 34, 179, 247, 43, 170, 25, 72, 141, 197, 33, 16, 27, 243, 255,
               62, 9, 86, 147, 15, 193, 9, 244, 229, 208, 76, 222, 83, 208>>,
  TestPriv2= <<183, 31, 13, 74, 198, 72, 211, 62, 196, 207, 92, 98, 28, 31, 136, 0, 127, 128,
               189, 172, 129, 122, 6, 39, 221, 242, 157, 21, 164, 81, 236, 181>>,
  Patch1=tx:construct_tx(#{ver=>2, kind=>patch,
                           patches =>
                           [#{p => [chain, 0, blocktime], t => set, v => 1},
                            #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
                          }),
  Patch2=tx:construct_tx(#{ver=>2, kind=>patch,
                           patches =>
                           [#{p => [chain, 0, blocktime], t => set, v => 2},
                            #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
                          }),
  TwoSig= tx:sign(
            tx:sign(Patch1, TestPriv1),
            TestPriv2),
  RePack=tx:unpack(tx:pack(TwoSig)),
  ?assertEqual(TwoSig#{txext=>#{}}, RePack),
  BadSig=maps:merge(TwoSig, Patch2),
  ReSig=tx:sign(
          BadSig,
          TestPriv2),
  TstGenesis=settings:dmp(settings:mp([
                                       #{t=>set, p=>[globals, patchsigs], v=>2},
                                       #{t=>set, p=>[chains], v=>[0]},
                                       #{t=>set, p=>[chain, 0, minsig], v=>2},
                                       #{t=>set, p=>[chain, 0, blocktime], v=>5},
                                       #{t=>set, p=>[keys, node1], v=>
                                         hex:parse("035AE7DF4FCB5B97A86FCEBB107D440858DDFB28C708E70E06C625AA210E8A6F16") },
                                       #{t=>set, p=>[keys, node2], v=>
                                         hex:parse("020783EF674851FCE9BED45B494D838C6B5F394F175B37DD26A511F29E1F21394B") },
                                       #{t=>set, p=>[keys, node3], v=>
                                         hex:parse("0260CC110AF0A34E7CD51C287320612F017B52AABBEA8EBFA619CF94FDE823C36C") }
                                       #{t=>set, p=>[nodechain], v=>#{node1=>0, node2=>0, node3=>0 } }
                                      ])),

  Genesis=settings:patch(TstGenesis, #{}),
  Patched=settings:patch(tx:verify(RePack,[nocheck_keys]), Genesis),
  [
   ?assertMatch({ok, #{
                   sigverify:=#{
                     invalid:=0,
                     pubkeys:=[_, _]
                    }}
                }, tx:verify(TwoSig,[nocheck_keys])), %simple check
   ?assertMatch({ok, #{
                   sigverify:=#{
                     invalid:=0,
                     pubkeys:=[_, _]
                    }}
                }, tx:verify(RePack,[nocheck_keys])), %check after packing and unpacking
   ?assertEqual(bad_sig, tx:verify(BadSig,[nocheck_keys])), %broken patch
   ?assertMatch({ok, #{
                   sigverify:=#{
                     invalid:=_,
                     pubkeys:=[_]
                    }}
                }, tx:verify(ReSig,[nocheck_keys])), %resig broken patch
   ?assertMatch([_|_], TstGenesis),
   ?assertMatch(#{}, Genesis),
   ?assertMatch(5, settings:get([chain, 0, blocktime], Genesis)),
   ?assertMatch(1, settings:get([chain, 0, blocktime], Patched)),
   ?assertMatch(#{}, settings:get([chain, 0, <<"allowempty">>], Genesis)),
   ?assertMatch(0, settings:get([chain, 0, <<"allowempty">>], Patched))
  ].

second_test() ->
  State0=settings:new(),
  P1=[
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>], 
        <<"v">>=>trunc(1.0e3)},
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>], 
        <<"v">>=>trunc(1.0e9)},
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"rewards">>, <<"c1n1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>},
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"rewards">>, <<"c1n2">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 2>>},
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"rewards">>, <<"c1n3">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 3>>},
      #{<<"t">>=><<"list_add">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 3>>},
      #{<<"t">>=><<"list_add">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>}
     ],
  State1=settings:patch(P1,State0),
  P2a=[
       #{<<"t">>=><<"delete">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>],
         <<"v">>=>1
        }
      ],
  P2b=[
       #{<<"t">>=><<"delete">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>],
         <<"v">>=>null
        }
      ],
  P2=[
      #{<<"t">>=><<"delete">>, 
        <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>],
        <<"v">>=>1000
       }
     ],
  P2c=[
       #{<<"t">>=><<"delete">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>,<<"xxX">>],
         <<"v">>=>1000
        }
      ],
  P2d=[
       #{<<"t">>=><<"delete">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"base">>,<<"xxX">>],
         <<"v">>=>null
        }
      ],

  State2=settings:patch(P2,State1),
  State2b=settings:patch(P2b,State1),

  P3a=[
       #{<<"t">>=><<"compare">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>],
         <<"v">>=>100000
        },
       #{<<"t">>=><<"set">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>],
         <<"v">>=>200000
        }
      ],
  P3b=[
       #{<<"t">>=><<"member">>, 
         <<"p">>=>[<<"list1">>],
         <<"v">>=><<160, 0, 0, 0, 0, 0, 9, 1>>
        },
       #{<<"t">>=><<"set">>, 
         <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>],
         <<"v">>=>200000
        }
      ],
  P3=[
      #{<<"t">>=><<"exist">>, <<"p">>=>[<<"list1">>], <<"v">>=><<>> },
      #{<<"t">>=><<"nonexist">>, <<"p">>=>[<<"list2">>], <<"v">>=><<>> },
      #{<<"t">>=><<"member">>, 
        <<"p">>=>[<<"list1">>],
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>
       },
      #{<<"t">>=><<"nonmember">>, 
        <<"p">>=>[<<"list1">>],
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 9>>
       },
      #{<<"t">>=><<"compare">>, 
        <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>],
        <<"v">>=>1000000000
       },
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[keys,<<"k1">>],
        <<"v">>=><<1,2,3,4>>
       },
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>],
        <<"v">>=>2000000
       },
      #{<<"t">>=><<"list_del">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>},
      #{<<"t">>=><<"list_add">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 9>>},
      #{<<"t">>=><<"delete">>,
        <<"p">>=>[<<"current">>,<<"rewards">>],
        <<"v">>=>null}
     ],
  State3=settings:patch(P3,State2),
  Res1=[
        #{<<"p">> => [<<"keys">>,<<"k1">>],
          <<"t">> => <<"set">>,
          <<"v">> => <<1,2,3,4>>},
        #{<<"p">> => [<<"current">>,<<"fee">>,<<"FTT">>,<<"kb">>],
          <<"t">> => <<"set">>,<<"v">> => 2000000},
        #{<<"p">> => [<<"list1">>],
          <<"t">> => <<"list_add">>,
          <<"v">> => <<160,0,0,0,0,0,1,3>>},
        #{<<"p">> => [<<"list1">>],
          <<"t">> => <<"list_add">>,
          <<"v">> => <<160,0,0,0,0,0,1,9>>}],
  Res2=[
        #{<<"p">> => [keys,<<"k1">>],
          <<"t">> => <<"set">>,
          <<"v">> => <<1,2,3,4>>},
        #{<<"p">> => [<<"current">>,<<"fee">>,<<"FTT">>,<<"kb">>],
          <<"t">> => <<"set">>,<<"v">> => 2000000},
        #{<<"p">> => [<<"list1">>],
          <<"t">> => <<"list_add">>,
          <<"v">> => <<160,0,0,0,0,0,1,3>>},
        #{<<"p">> => [<<"list1">>],
          <<"t">> => <<"list_add">>,
          <<"v">> => <<160,0,0,0,0,0,1,9>>}],

  [
   ?assertMatch(1000,
                settings:get(
                  [<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>],State1)),
   ?assertMatch(<<160,0,0,0,0,0,1,3>>,
                settings:get(
                  [<<"current">>,<<"rewards">>,<<"c1n3">>],State1)),
   ?assertMatch(#{},
                settings:get(
                  [<<"current">>,<<"rewards">>,<<"c1n5">>],State1)),
   ?assertThrow({delete_val,[<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>],1},
                settings:patch(P2a,State1)),
   ?assertThrow({non_map,[<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>,<<"xxX">>]},
                settings:patch(P2c,State1)),
   ?assertThrow({non_map,[<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>,<<"xxX">>]},
                settings:patch(P2d,State1)),
   ?assertMatch(#{},settings:get([<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>],State2)),
   ?assertMatch(#{},settings:get([<<"current">>,<<"fee">>,<<"FTT">>,<<"base">>],State2b)),
   ?assertMatch(<<160,0,0,0,0,0,1,3>>,settings:get([<<"current">>,<<"rewards">>,<<"c1n3">>],State2)),

   ?assertThrow({compare,_}, settings:patch(P3a,State2)),
   ?assertThrow({member,_}, settings:patch(P3b,State2)),
   ?assertThrow({non_value,_}, settings:patch(
                                 [
                                  #{<<"t">>=><<"set">>, 
                                    <<"p">>=>[<<"current">>, <<"fee">>],
                                    <<"v">>=>2000000
                                   } ],State2)),
   ?assertThrow({non_list,_}, settings:patch(
                                [
                                 #{<<"t">>=><<"list_add">>, 
                                   <<"p">>=>[<<"current">>],
                                   <<"v">>=>2000000
                                  } ],State2)),
   ?assertThrow({non_list,_}, settings:patch(
                                [
                                 #{<<"t">>=><<"list_del">>, 
                                   <<"p">>=>[<<"current">>],
                                   <<"v">>=>2000000
                                  } ],State2)),
   ?assertThrow({non_list,_}, settings:patch(
                                [
                                 #{<<"t">>=><<"member">>, 
                                   <<"p">>=>[<<"current">>],
                                   <<"v">>=>2000000
                                  } ],State2)),
   ?assertThrow({non_map,_}, settings:patch(
                               [
                                #{<<"t">>=><<"set">>, 
                                  <<"p">>=>[<<"current">>, <<"fee">>, <<"FTT">>, <<"kb">>, <<"abc">>],
                                  <<"v">>=>2000000
                                 } ],State2)),
   ?assertThrow({member,_}, settings:patch(
                              [
                               #{<<"t">>=><<"member">>, 
                                 <<"p">>=>[<<"list1">>], 
                                 <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>}
                              ],State3)),
   ?assertThrow({exist,_}, settings:patch(
                             [
                              #{<<"t">>=><<"nonexist">>, 
                                <<"p">>=>[<<"list1">>], 
                                <<"v">>=><<>>}
                             ],State3)),
   ?assertThrow({exist,_}, settings:patch(
                             [
                              #{<<"t">>=><<"exist">>, 
                                <<"p">>=>[<<"list2">>], 
                                <<"v">>=><<>>}
                             ],State3)),
   ?assertThrow({member,_}, settings:patch(
                              [
                               #{<<"t">>=><<"nonmember">>, 
                                 <<"p">>=>[<<"list1">>], 
                                 <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 9>>}
                              ],State3)),
   ?assertThrow({action,_}, settings:patch(
                              [
                               #{<<"t">>=><<"zhopa">>, 
                                 <<"p">>=>[<<"list1">>], 
                                 <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 9>>}
                              ],State3)),
   ?assertMatch(Res1,settings:get_patches(State3)),
   ?assertMatch(Res2,settings:get_patches(State3,ets))
  ].

meta_test() ->
  S1=settings:new(),
  P1=[
      #{<<"t">>=><<"set">>, 
        <<"p">>=>[<<"current">>, <<"1k">>], 
        <<"v">>=>trunc(1.0e3)},
      #{<<"t">>=><<"list_add">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 3>>},
      #{<<"t">>=><<"list_add">>, 
        <<"p">>=>[<<"list1">>], 
        <<"v">>=><<160, 0, 0, 0, 0, 0, 1, 1>>}
     ],
  P2=settings:make_meta(P1,#{ublk=><<1,2,3,4,5,6,7,8>>}),
  S2=settings:patch(P1++P2,S1),
  Res=lists:sort(settings:get_patches(S2)),
  [
   ?assertEqual(<<1,2,3,4,5,6,7,8>>,
                settings:get([<<"current">>,<<".">>,<<"1k">>,<<"ublk">>],S2)),
   ?assertEqual(<<1,2,3,4,5,6,7,8>>,
                settings:get([<<".">>,<<"list1">>,<<"ublk">>],S2)),
   ?assertEqual(lists:sort(P1++P2),Res)
  ].

