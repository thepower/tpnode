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
    Patch1=#{patch =>
             [#{p => [chain, 0, blocktime], t => set, v => 1},
              #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
            },
    Patch2=#{patch =>
             [#{p => [chain, 0, blocktime], t => set, v => 2},
              #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
            },
    TwoSig= settings:sign(
              settings:sign(Patch1, TestPriv1),
              TestPriv2),
    RePack=tx:unpack(tx:pack(TwoSig)),
    BadSig=maps:merge(TwoSig, Patch2),
    ReSig=settings:sign(
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
    Patched=settings:patch(settings:verify(RePack), Genesis),


    [

     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=0,
                       valid:=[_, _]
                      }}
                  }, settings:verify(TwoSig)), %simple check
     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=0,
                       valid:=[_, _]
                      }}
                  }, settings:verify(RePack)), %check after packing and unpacking
     ?assertEqual(bad_sig, settings:verify(BadSig)), %broken patch
     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=2,
                       valid:=[_]
                      }}
                  }, settings:verify(ReSig)), %resig broken patch
     ?assertMatch([_|_], TstGenesis),
     ?assertMatch(#{}, Genesis),
     ?assertMatch(5, settings:get([chain, 0, blocktime], Genesis)),
     ?assertMatch(1, settings:get([chain, 0, blocktime], Patched)),
     ?assertMatch(#{}, settings:get([chain, 0, <<"allowempty">>], Genesis)),
     ?assertMatch(0, settings:get([chain, 0, <<"allowempty">>], Patched))
    ].

