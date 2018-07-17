-module(tx_tests).

-include_lib("eunit/include/eunit.hrl").

old_register_test() ->
  Priv= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216,
          123, 142, 115, 120, 124, 240, 248, 115, 150, 54, 239,
          58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  PubKey=tpecdsa:calc_pub(Priv, true),
  T=1522252760000,
  Res=
  tx:unpack(
    tx:pack(
      tx:unpack(
        msgpack:pack(
          #{
          "type"=>"register",
          timestamp=>T,
          pow=>crypto:hash(sha256, <<T:64/big, PubKey/binary>>),
          register=>PubKey
         }
         )
       )
     )
   ),
  #{register:=PubKey, timestamp:=T, pow:=<<223, 92, 191, _/binary>>}=Res.

old_tx_jsondata_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  %Pub1Min=tpecdsa:calc_pub(Pvt1, true),
  From=(naddress:construct_public(0, 0, 1)),
  BinTx1=tx:sign(#{
           from => From,
           to => From,
           cur => <<"TEST">>,
           timestamp => 1512450000,
           seq => 1,
           amount => 10,
           extradata=>jsx:encode(#{
                        fee=>30,
                        feecur=><<"TEST">>,
                        message=><<"preved123456789012345678901234567891234567890">>
                       })
          }, Pvt1),
  BinTx2=tx:sign(#{
           from => From,
           to => From,
           cur => <<"TEST">>,
           timestamp => 1512450000,
           seq => 1,
           amount => 10,
           extradata=>jsx:encode(#{
                        fee=>10,
                        feecur=><<"TEST">>,
                        message=><<"preved123456789012345678901234567891234567890">>
                       })
          }, Pvt1),
  GetRateFun=fun(_Currency) ->
                 #{ <<"base">> => 1,
                    <<"baseextra">> => 64,
                    <<"kb">> => 1000
                  }
             end,
  UTx1=tx:unpack(BinTx1),
  UTx2=tx:unpack(BinTx2),
  [
   ?assertEqual(UTx1, tx:unpack( tx:pack(UTx1))),
   ?assertMatch({true, #{cost:=20, tip:=10}}, tx:rate(UTx1, GetRateFun)),
   ?assertMatch({false, #{cost:=20, tip:=0}}, tx:rate(UTx2, GetRateFun))
  ].


old_digaddr_tx_test() ->
  Priv= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216,
          123, 142, 115, 120, 124, 240, 248, 115, 150, 54, 239,
          58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  PubKey=tpecdsa:calc_pub(Priv, true),
  From=(naddress:construct_public(0, 0, 1)),
  Test=fun(LedgerPID) ->
           To=(naddress:construct_public(0, 0, 2)),
           TestTx2=#{ from=>From,
                      to=>To,
                      cur=><<"tkn1">>,
                      amount=>1244327463428479872,
                      timestamp => os:system_time(millisecond),
                      seq=>1
                    },
           BinTx2=tx:sign(TestTx2, Priv),
           BinTx2r=tx:pack(tx:unpack(BinTx2)),
           {ok, CheckTx2}=tx:verify(BinTx2,[{ledger, LedgerPID}]),
           {ok, CheckTx2r}=tx:verify(BinTx2r,[{ledger, LedgerPID}]),
           CheckTx2=CheckTx2r
       end,
  Ledger=[ {From, bal:put(pubkey, PubKey, bal:new()) } ],
  ledger:deploy4test(Ledger, Test).

old_patch_test() ->
  Priv= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216,
          123, 142, 115, 120, 124, 240, 248, 115, 150, 54, 239,
          58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Patch=settings:sign(
          settings:dmp(
            settings:mp(
              [
               #{t=>set, p=>[current, fee, params, <<"feeaddr">>],
                 v=><<160, 0, 0, 0, 0, 0, 0, 1>>},
               #{t=>set, p=>[current, fee, params, <<"tipaddr">>],
                 v=><<160, 0, 0, 0, 0, 0, 0, 2>>},
               #{t=>set, p=>[current, fee, params, <<"notip">>], v=>0},
               #{t=>set, p=>[current, fee, <<"FTT">>, <<"base">>], v=>trunc(1.0e7)},
               #{t=>set, p=>[current, fee, <<"FTT">>, <<"baseextra">>], v=>64},
               #{t=>set, p=>[current, fee, <<"FTT">>, <<"kb">>], v=>trunc(1.0e9)}
              ])),
          Priv),
  %io:format("PK ~p~n", [settings:verify(Patch)]),
  tx:verify(Patch).

deploy_test() ->
  Priv= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216,
          123, 142, 115, 120, 124, 240, 248, 115, 150, 54, 239,
          58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  PubKey=tpecdsa:calc_pub(Priv, true),
  From=(naddress:construct_public(0, 0, 1)),
  Test=fun(LedgerPID) ->
           TestTx2=#{ from=>From,
                      deploy=><<"chainfee">>,
                      code=><<"code">>,
                      state=><<"state">>,
                      timestamp => os:system_time(millisecond),
                      seq=>1
                    },
           BinTx2=tx:sign(TestTx2, Priv),
           BinTx2r=tx:pack(tx:unpack(BinTx2)),
           {ok, CheckTx2}=tx:verify(BinTx2,[{ledger, LedgerPID}]),
           {ok, CheckTx2r}=tx:verify(BinTx2r,[{ledger, LedgerPID}]),
           [
            ?assertEqual(CheckTx2, CheckTx2r),
            ?assertEqual(maps:without([sigverify], CheckTx2r), tx:unpack(BinTx2))
           ]
       end,
  Ledger=[ {From, bal:put(pubkey, PubKey, bal:new()) } ],
  ledger:deploy4test(Ledger, Test).

old_txs_sig_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:construct_public(1, 2, 3),
  BinTx1=tx:sign(#{
           from => Addr,
           to => Addr,
           cur => <<"test">>,
           timestamp => 1512450000,
           seq => 1,
           amount => 10
          }, Pvt1),
  BinTx2=tx:sign(#{
           from => Addr,
           to => Addr,
           cur => <<"test2">>,
           timestamp => 1512450011,
           seq => 2,
           amount => 20
          }, Pvt1),
  Txs=[{<<"txid1">>, BinTx1}, {<<"txid2">>, BinTx2}],
  H1=tx:txlist_hash(Txs),

  Txs2=[ {<<"txid2">>, tx:unpack(BinTx2)}, {<<"txid1">>, tx:unpack(BinTx1)} ],
  H2=tx:txlist_hash(Txs2),

  Txs3=[ {<<"txid1">>, tx:unpack(BinTx2)}, {<<"txid2">>, tx:unpack(BinTx1)} ],
  H3=tx:txlist_hash(Txs3),

  [
   ?assertEqual(H1, H2),
   ?assertNotEqual(H1, H3)
  ].

tx2_reg_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Pvt2= <<194, 222, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Pub1=tpecdsa:calc_pub(Pvt1,true),
  Pub2=tpecdsa:calc_pub(Pvt2,true),
  T1=#{
    kind => register,
    t => 1530106238744,
    ver => 2,
    inv => <<"preved">>,
    keys => [Pub1,Pub2]
   },
  TXConstructed=tx:sign(tx:sign(tx:construct_tx(T1,[{pow_diff,16}]),Pvt1),Pvt2),
  Packed=tx:pack(TXConstructed),
  [
  ?assertMatch(<<0,0,_/binary>>, crypto:hash(sha512,maps:get(body,tx:unpack(Packed)))),
  ?assertMatch(#{ ver:=2, kind:=register, keysh:=_}, TXConstructed),
  ?assertMatch(#{ ver:=2, kind:=register, keysh:=_}, tx:unpack(Packed)),
  ?assertMatch({ok,_}, tx:verify(Packed, [])),
  ?assertMatch({ok,#{sigverify:=#{pow_diff:=PD,valid:=2,invalid:=0}}}
                 when PD>=16, tx:verify(Packed, [])),
  ?assertMatch({ok,#{sig:=#{Pub1:=_,Pub2:=_}} }, tx:verify(Packed))
  ].

tx2_generic_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  PubKey=tpecdsa:calc_pub(Pvt1, true),
  T1=#{
    kind => generic,
    from => <<128,0,32,0,2,0,0,3>>,
    payload =>
    [#{amount => 10,cur => <<"XXX">>,purpose => transfer},
     #{amount => 20,cur => <<"FEE">>,purpose => srcfee}],
    seq => 5,sig => #{},t => 1530106238743,
    to => <<128,0,32,0,2,0,0,5>>,
    ver => 2
   },
  TXConstructed=tx:construct_tx(T1),
  Packed=tx:pack(tx:sign(TXConstructed,Pvt1)),
  Test=fun(LedgerPID) ->
           [
            ?assertMatch(#{ ver:=2, kind:=generic}, tx:unpack(Packed)),
            ?assertMatch({ok,#{
                            ver:=2,
                            kind:=generic,
                            sigverify:=#{valid:=1,invalid:=0},
                            seq:=5,
                            from:= <<128,0,32,0,2,0,0,3>>,
                            to:= <<128,0,32,0,2,0,0,5>>,
                            payload:= [_,_]
                           }}, tx:verify(Packed, [{ledger, LedgerPID}]))
           ]
       end,
  Ledger=[ {<<128,0,32,0,2,0,0,3>>, bal:put(pubkey, PubKey, bal:new()) } ],
  ledger:deploy4test(Ledger, Test).

tx2_rate_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  %Pub1Min=tpecdsa:calc_pub(Pvt1, true),
  From=(naddress:construct_public(0, 0, 1)),
  T1=#{
    kind => generic,
    from => From,
    payload =>
    [#{amount => 10,cur => <<"TEST">>,purpose => transfer},
     #{amount => 30,cur => <<"TEST">>,purpose => srcfee}],
    seq => 1,
    t => 1512450000,
    to => From,
    txext => #{
      message=><<"preved12345678901234567890123456789123456789">>
     },
    ver => 2
   },
  TX1Constructed=tx:construct_tx(T1),
  BinTx1=tx:pack(tx:sign(TX1Constructed,Pvt1)),

  T2=#{
    kind => generic,
    from => From,
    payload =>
    [#{amount => 10,cur => <<"TEST">>,purpose => transfer},
     #{amount => 10,cur => <<"TEST">>,purpose => srcfee}],
    seq => 1,
    t => 1512450000,
    to => From,
    txext => #{
      message=><<"preved12345678901234567890123456789123456789">>
     },
    ver => 2
   },
  TX2Constructed=tx:construct_tx(T2),
  BinTx2=tx:pack(tx:sign(TX2Constructed,Pvt1)),
  io:format("tx2 ~p~n",[msgpack:unpack(maps:get(body,TX2Constructed))]),

  GetRateFun=fun(_Currency) ->
                 #{ <<"base">> => 1,
                    <<"baseextra">> => 64,
                    <<"kb">> => 1000
                  }
             end,
  UTx1=tx:unpack(BinTx1),
  UTx2=tx:unpack(BinTx2),
  [
   ?assertEqual(UTx1, tx:unpack( tx:pack(UTx1))),
   ?assertMatch({true, #{cost:=20, tip:=10}}, tx:rate(UTx1, GetRateFun)),
   ?assertMatch({false, #{cost:=20, tip:=0}}, tx:rate(UTx2, GetRateFun))
  ].

