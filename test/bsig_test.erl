-module(bsig_test).

-include_lib("eunit/include/eunit.hrl").

poa_test() ->
  Priv1=tpecdsa:generate_priv(ed25519),
  Priv2=tpecdsa:generate_priv(ed25519),
  Pub2=tpecdsa:calc_pub(Priv2),
  Priv3=tpecdsa:generate_priv(ed25519),
  Pub3=tpecdsa:calc_pub(Priv3),
  T1=os:system_time(millisecond),
  T2=T1+1000,
  T1v=T1+300000,
  T2v=T2+200000,
  PoA1=bsig:signhash(Pub2,[{timestamp,T1},
                           {expire,T1v},
                           {baldep,{<<129,0,0,0,0,0,0,1>>,128}},
                           {baldep,{<<129,0,0,0,0,0,0,2>>,129}}
                          ],Priv1),
  PoA2=bsig:signhash(Pub3,[{timestamp,T2},
                           {expire,T2v},
                           {baldep,{<<129,0,0,0,0,0,0,4>>,130}},
                           {baldep,{<<129,0,0,0,0,0,0,3>>,129}},
                           {poa, PoA1}
                          ],Priv2),
  Preved=bsig:signhash(<<"preved">>,
                       [
                        {timestamp,os:system_time(millisecond)},
                        {poa,PoA2}
                       ],Priv3
                      ),
  {true,Constraints}=bsig:checksig1(<<"preved">>,
                                    Preved,
                                    fun(Key,Time,_) ->
                                        ?assertEqual(Key,tpecdsa:calc_pub(Priv1)),
                                        {true,Time}
                                    end),
  #{baldep:=BD,tmax:=TMax,tmin:=TMin}=Constraints,
  [
   ?assertEqual(TMax,T2+200000),
   ?assertEqual(TMin,T2),
   ?assertEqual(lists:sort(BD),
                [{<<129,0,0,0,0,0,0,1>>,128},
                 {<<129,0,0,0,0,0,0,2>>,129},
                 {<<129,0,0,0,0,0,0,3>>,129},
                 {<<129,0,0,0,0,0,0,4>>,130}]
                )
  ].


