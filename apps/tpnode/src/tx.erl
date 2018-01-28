-module(tx).

-export([get_ext/2,set_ext/3,sign/2,verify/1,pack/1,unpack/1]).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

get_ext(K,Tx) ->
    Ed=maps:get(extdata,Tx,#{}),
    case maps:is_key(K,Ed) of
        true ->
            {ok, maps:get(K,Ed)};
        false ->
            undefined
    end.

set_ext(K,V,Tx) ->
    Ed=maps:get(extdata,Tx,#{}),
    Tx#{
      extdata=>maps:put(K,V,Ed)
     }.

mkmsg(#{ from:=From, amount:=Amount,
         cur:=Currency, to:=To,
         seq:=Seq, timestamp:=Timestamp
       }=Tx) ->
    {ToValid,_}=address:check(To),
    if not ToValid -> 
           throw({invalid_address,to});
       true -> ok
    end,

    case maps:is_key(outbound,Tx) of 
        true ->
            lager:notice("FIXME: save outbound flag in tx");
        false -> ok
    end,
    Append=maps:get(extradata,Tx,<<"">>),

    msgpack:pack([
                  <<"tx">>,
                  From,To,trunc(Amount),
                  Currency,Timestamp,Seq,Append
                 ]);

mkmsg(Unknown) ->
    throw({unknown_tx_type,Unknown}).


sign(#{
  from:=From
 }=Tx,PrivKey) ->
    Pub=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
    {FromValid,Fat}=address:check(From),
    if not FromValid -> 
           throw({invalid_address,from});
       true -> ok
    end,
    NewFrom=address:pub2addr(Fat,Pub),
    if NewFrom =/= From -> 
           throw({invalid_key,mismatch_from_address});
       true -> ok
    end,

    TxBin=mkmsg(Tx),
    {ok, [MType|LTx]} = msgpack:unpack(TxBin),

    Sig = tpecdsa:secp256k1_ecdsa_sign(TxBin, PrivKey, default, <<>>),

    msgpack:pack(
      maps:merge(
        #{
        type => MType,
        tx => LTx,
        sig => maps:put(Pub, Sig, maps:get(signature, Tx, #{}) )
       },
        maps:with([extdata],Tx))
     ).

verify(#{
  from := From,
  sig := HSigs
 }=Tx) ->
    {FromValid,Fat}=address:check(From),
    if not FromValid -> 
           throw({invalid_address,from});
       true -> ok
    end,
    Message=mkmsg(Tx),
    lager:info("Verify ~p",[HSigs]),
    {Valid,Invalid}=maps:fold(
                fun(Pub, Sig, {AValid,AInvalid}) ->
                        NewFrom=address:pub2addr(Fat,Pub),
                        if NewFrom =/= From -> 
                               {AValid, AInvalid+1};
                           true -> 
                               case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
                                   correct ->
                                       {AValid+1, AInvalid};
                                   _ ->
                                       {AValid, AInvalid+1}
                               end
                        end
                end,
                {0,0}, HSigs),

    case Valid of
        0 ->
            bad_sig;
        N when N>0 ->
            {ok, Tx#{
                   sigverify=>#{
                     valid=>Valid,
                     invalid=>Invalid
                    }
                  }
            }
    end;

verify(Bin) when is_binary(Bin) ->
    Tx=unpack(Bin),
    verify(Tx).

pack(#{
  patch:=LPatch,
  sig:=Sigs
 }=Tx) ->
    %BinPatch=settings:mp(LPatch),
    msgpack:pack(
      maps:merge(
        #{
        type => <<"patch">>,
        patch => LPatch,
        sig => Sigs
       },
        maps:with([extdata],Tx))
     );

pack(#{
  sig:=Sigs
 }=Tx) ->
    TxBin=mkmsg(Tx),
    {ok, [MType|LTx]} = msgpack:unpack(TxBin),

    msgpack:pack(
      maps:merge(
        #{
        type => MType,
        tx => LTx,
        sig => Sigs
       },
        maps:with([extdata],Tx))
     );

pack(Unknown) ->
    throw({unknown_tx_to_pack,Unknown}).

unpack(Tx) when is_map(Tx) ->
    Tx;

unpack(BinTx) when is_binary(BinTx) ->
    unpack_mp(BinTx).

unpack_mp(BinTx) when is_binary(BinTx) ->
    {ok, #{
       type:=Type,
       sig:=Sig
      }=Tx
    } = msgpack:unpack(BinTx, [{known_atoms, [type,sig,tx,patch] }] ),
    R=case Type of
        tx -> %generic finance tx
            lager:info("tx ~p",[Tx]),
            [From,To,Amount, Cur, Timestamp, Seq, ExtraJSON] = maps:get(tx,Tx),
            #{ type => Type,
                  from => From,
                  to => To,
                  amount => Amount,
                  cur => Cur,
                  timestamp => Timestamp,
                  seq => Seq,
                  extradata => ExtraJSON,
                  sig => Sig
                };
        patch -> %settings patch
              #{ patch => maps:get(patch,Tx),
                 sig => Sig};
        _ ->
            lager:error("Bad tx ~p",[Tx]),
            throw({"bad tx type",Type})
    end,
    case maps:is_key(<<"extdata">>,Tx) of
        true ->
            R#{extdata=>maps:get(<<"extdata">>,Tx)};
        false ->
            R
    end.

-ifdef(TEST).
new_tx_test() ->
    Priv=tpecdsa:generate_priv(),
    From=address:pub2addr(255,tpecdsa:calc_pub(Priv,true)),
    To=address:pub2addr(255,tpecdsa:calc_pub(tpecdsa:generate_priv(),true)),
    TestTx1=#{signature=>#{a=>123},
              extdata=>#{<<"aaa">>=>111,222=><<"bbb">>},
              from=>From,
              to=>To, 
              cur=>0,
              amount=>1, timestamp => os:system_time(millisecond), seq=>1},
    BinTx1=tx:sign(TestTx1, Priv),
    {ok, CheckTx1}=tx:verify(BinTx1),

    TestTx2=#{ from=>From,
             to=>To, 
             cur=>1231631273374273843,
             amount=>12344327463428479872, 
             timestamp => os:system_time(millisecond), 
             seq=>1
             },
    BinTx2=tx:sign(TestTx2, Priv),
    BinTx2r=tx:pack(tx:unpack(BinTx2)),
    {ok, CheckTx2}=tx:verify(BinTx2),
    {ok, CheckTx2r}=tx:verify(BinTx2r),
    ?assertEqual(#{invalid => 1,valid => 1},maps:get(sigverify,CheckTx1)),
    ?assertEqual(#{invalid => 0,valid => 1},maps:get(sigverify,CheckTx2)),
    ?assertEqual(#{invalid => 0,valid => 1},maps:get(sigverify,CheckTx2r)),
    BinTx2r.

tx_test() ->
    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pvt2= <<200,200,100,11,222,33,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pub1Min=tpecdsa:secp256k1_ec_pubkey_create(Pvt1, true),
    Pub2Min=tpecdsa:secp256k1_ec_pubkey_create(Pvt2, true),
    Dst=address:pub2addr({ver,1},Pub2Min),
    BinTx1=try
               sign(#{
                 from => <<"src">>,
                 to => Dst,
                 cur => <<"test">>,
                 timestamp => 1512450000,
                 seq => 1,
                 amount => 10
                },Pvt1)
           catch throw:Ee1 ->
                     {throw,Ee1}
           end,
    ?assertEqual({throw,{invalid_address,from}},BinTx1),
    From=address:pub2addr({ver,1},Pub1Min),
    BinTx2=sign(#{
             from => From,
             to => Dst,
             cur => <<"test">>,
             timestamp => 1512450000,
             seq => 1,
             amount => 10
            },Pvt1),
    {ok,ExTx}=verify(BinTx2),
    {ok,ExTx1}=verify(tx:pack(tx:unpack(BinTx2))),
    [
     ?assertMatch([{Pub1Min,_}],maps:to_list(maps:get(sig,ExTx))),
     ?assertMatch([{Pub1Min,_}],maps:to_list(maps:get(sig,ExTx))),
     ?assertEqual(ExTx,ExTx1)
    ].

-endif.


