-module(tx).

-export([get_ext/2,set_ext/3,sign/2,verify/1,pack/1,unpack/1]).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

checkaddr(<<Ia:64/big>>) -> {new, {true, Ia}};
checkaddr(Address) -> {old, address:check(Address)}.

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
    %{ToValid,_}=checkaddr(To),
    %if not ToValid -> 
    %       throw({invalid_address,to});
    %   true -> ok
    %end,

    case maps:is_key(outbound,Tx) of 
        true ->
            lager:notice("FIXME: save outbound flag in tx");
        false -> ok
    end,
    Append=maps:get(extradata,Tx,<<"">>),
    lager:info("tx ~p",[Tx]),
    if is_binary(From) -> ok;
       true -> throw('non_bin_addr_from')
    end,
    if is_binary(To) -> ok;
       true -> throw('non_bin_addr_to')
    end,

    msgpack:pack([
                  "tx",
                  From,
                  To,
                  trunc(Amount),
                  if is_list(Currency) -> Currency;
                     is_binary(Currency) -> binary_to_list(Currency)
                  end,
                  Timestamp,
                  Seq,
                  if is_list(Append) -> Append;
                     is_binary(Append) -> binary_to_list(Append)
                  end
                 ]);

mkmsg(Unknown) ->
    throw({unknown_tx_type,Unknown}).


sign(#{
  from:=From
 }=Tx,PrivKey) ->
    Pub=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
    case checkaddr(From) of 
        {new,{true, _IAddr}} ->
            ok;
        {old,{true, Fat}} ->
            if Fat < 256 ->
                   NewFrom=address:pub2addr(Fat,Pub),
                   if NewFrom =/= From -> 
                          throw({invalid_key,mismatch_from_address});
                      true -> ok
                   end;
               true ->
                   lager:notice("Check sender's key in ledger")
            end;
        _ ->
            throw({invalid_address,from})
    end,

    TxBin=mkmsg(Tx),
    io:format("Bin ~p~n",[TxBin]),
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

verify(#{register:=_, type:=register}=Tx) -> 
    {ok,Tx};

verify(#{
  from := From,
  sig := HSigs,
  timestamp := T
 }=Tx) ->
    Message=mkmsg(Tx),
    lager:info("MsgVer ~p",[Message]),
    if is_integer(T) -> 
           ok;
       true ->
           throw({bad_timestamp,T})
    end,

    {Valid,Invalid}=case checkaddr(From) of 
                        {new, {true, _IAddr}} ->
                            case ledger:get(From) of
                                #{pubkey:=PK} when is_binary(PK) ->
                                    maps:fold(
                                      fun(Pub, Sig, {AValid,AInvalid}) when Pub==PK ->
                                              case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
                                                  correct when PK==Pub ->
                                                      {AValid+1, AInvalid};
                                                  _ ->
                                                      {AValid, AInvalid+1}
                                              end
                                      end,
                                      {0,0}, HSigs);
                                _ ->
                                    throw({ledger_err,From})
                            end;
                        {old, {true, Fat}} ->
                            maps:fold(
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
                              {0,0}, HSigs);
                        _ ->
                            throw({invalid_address,from})
                    end,

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
  register:=Reg
 }) ->
    msgpack:pack(
      #{
      type => <<"register">>,
      register => Reg
     }
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
    lager:info("mp ~p",[BinTx]),
    {ok, Tx0} = msgpack:unpack(BinTx, [{known_atoms, 
                                        [type,sig,tx,patch,register,
                                         register] },
                                       {unpack_str,as_binary}] ),
    lager:info("TX ~p",[Tx0]), 
    Tx=maps:fold(
         fun
             ("tx",Val,Acc) ->
                 maps:put(tx,
                          lists:map(
                            fun(LI) when is_list(LI) ->
                                    list_to_binary(LI);
                               (OI) -> OI
                            end, Val),Acc);
             ("type",Val,Acc) ->
                 maps:put(type,
                          try 
                              erlang:list_to_existing_atom(Val) 
                          catch error:badarg -> 
                                    Val
                          end,Acc);
             ("register",Val,Acc) ->
                 maps:put(register,
                          list_to_binary(Val),
                          Acc);
             ("sig",Val,Acc) ->
                 maps:put(sig,
                          if is_map(Val) ->
                                 maps:fold(
                                   fun(PubK,PrivK,KAcc) ->
                                           maps:put(
                                             iolist_to_binary(PubK),
                                             iolist_to_binary(PrivK),
                                             KAcc)
                                   end, #{}, Val);
                             is_list(Val) ->
                                 lists:foldl(
                                   fun([PubK,PrivK],KAcc) ->
                                           maps:put(PubK,PrivK,KAcc)
                                   end, #{}, Val)
                          end,
                          Acc);
             (sig,Val,Acc) ->
                 maps:put(sig,
                          if is_map(Val) ->
                                 maps:fold(
                                   fun(PubK,PrivK,KAcc) ->
                                           maps:put(
                                             iolist_to_binary(PubK),
                                             iolist_to_binary(PrivK),
                                             KAcc)
                                   end, #{}, Val);
                             is_list(Val) ->
                                 case Val of
                                     [X|_] when is_binary(X) ->
                                         Val;
                                     [[_,_]|_] ->
                                         lists:foldl(
                                           fun([PubK,PrivK],KAcc) ->
                                                   maps:put(PubK,PrivK,KAcc)
                                           end, #{}, Val)
                                 end
                          end,
                          Acc);
             (K,Val,Acc) ->
                 maps:put(K,Val,Acc)
         end, #{}, Tx0),
    #{type:=Type}=Tx,
    R=case Type of
          tx -> %generic finance tx
              #{sig:=Sig}=Tx,
              lager:debug("tx ~p",[Tx]),
              [From,To,Amount, Cur, Timestamp, Seq, ExtraJSON] = maps:get(tx,Tx),
              if is_integer(Timestamp) -> 
                     ok;
                 true ->
                     throw({bad_timestamp,Timestamp})
              end,
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
              #{sig:=Sig}=Tx,
              #{ patch => maps:get(patch,Tx),
                 sig => Sig};
          register ->
              PubKey=maps:get(register,Tx),
              case size(PubKey) of
                  33 -> ok;
                  true -> throw('bad_pubkey')
              end,
              #{ type => register,
                 register => PubKey
               };
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
register_test() ->
    Priv= <<194,124,65,109,233,236,108,24,50,151,189,216,
           123,142,115,120,124,240,248,115, 150,54,239,
           58,218,221,145,246,158,15,210,165>>,
    PubKey=tpecdsa:calc_pub(Priv,true),
    Res=
    tx:unpack(
      tx:pack(
        tx:unpack(
          msgpack:pack(
            #{
            "type"=>"register",
            register=>PubKey
           }
           )
         )
       )
     ),
    #{register:=PubKey}=Res.

digaddr_tx_test() ->
    Priv= <<194,124,65,109,233,236,108,24,50,151,189,216,
            123,142,115,120,124,240,248,115, 150,54,239,
            58,218,221,145,246,158,15,210,165>>,
    PubKey=tpecdsa:calc_pub(Priv,true),
    From=(naddress:construct_public(0,0,1)),
    To=(naddress:construct_public(0,0,2)),

    NeedStop=case whereis(rdb_dispatcher) of
                 P1 when is_pid(P1) -> false;
                 undefined -> 
                     {ok,P1}=rdb_dispatcher:start_link(),
                     P1
             end,
    Ledger=case whereis(ledger) of
               P when is_pid(P) -> false;
               undefined -> 
                   {ok,P}=ledger:start_link(
                              [{filename, "db/ledger_txtest"}]
                             ),
                   gen_server:call(P, '_flush'),
                   gen_server:call(P,
                                   {put, [
                                          {From,
                                           bal:put(pubkey,PubKey,bal:new())
                                          }
                                         ]}),

                   P
             end,
     
    TestTx2=#{ from=>From,
               to=>To, 
               cur=><<"tkn1">>,
               amount=>1244327463428479872, 
               timestamp => os:system_time(millisecond), 
               seq=>1
             },
    BinTx2=tx:sign(TestTx2, Priv),
    BinTx2r=tx:pack(tx:unpack(BinTx2)),
    {ok, CheckTx2}=tx:verify(BinTx2),
    {ok, CheckTx2r}=tx:verify(BinTx2r),
    if Ledger == false -> ok;
       true -> gen_server:stop(Ledger, normal, 3000)
    end,
    if NeedStop==false -> ok;
       true -> gen_server:stop(NeedStop, normal, 3000)
    end,
    CheckTx2=CheckTx2r.

new_tx_test() ->
    Priv=tpecdsa:generate_priv(),
    From=address:pub2addr(255,tpecdsa:calc_pub(Priv,true)),
    To=address:pub2addr(255,tpecdsa:calc_pub(tpecdsa:generate_priv(),true)),
    TestTx1=#{signature=>#{<<"a">>=><<"123">>},
              extdata=>#{<<"aaa">>=>111,222=><<"bbb">>},
              from=>From,
              to=>To, 
              cur=>"CUR1",
              amount=>1, timestamp => os:system_time(millisecond), seq=>1},
    BinTx1=tx:sign(TestTx1, Priv),
    {ok, CheckTx1}=tx:verify(BinTx1),

    TestTx2=#{ from=>From,
             to=>To, 
             cur=>"XCUR",
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


