-module(tx).

-export([sign/2,verify/1,pack/1,unpack/1]).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

mkmsg(#{ from:=From, amount:=Amount,
         cur:=Currency, to:=To,
         seq:=Seq, timestamp:=Timestamp,
         format:=1
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

    iolist_to_binary(
              io_lib:format("~s:~s:~b:~s:~b:~b:~s",
                            [From,To,trunc(Amount),Currency,Timestamp,Seq,Append])
             );

mkmsg(#{ from := From, portout := PortOut,
         timestamp := Timestamp, seq := Seq,
         format:=1
       }) ->
    iolist_to_binary(
      io_lib:format("portout:~s:~b:~b:~b",
                    [From,PortOut,Timestamp,Seq])
     );


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

mkmsg(#{ from := From, portout := PortOut,
         timestamp := Timestamp, seq := Seq,
         format:=1
       }) ->
    iolist_to_binary(
      io_lib:format("portout:~s:~b:~b:~b",
                    [From,PortOut,Timestamp,Seq])
     ).

sign(#{
  format:=1,
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

    Message=mkmsg(Tx),

    Sig = tpecdsa:secp256k1_ecdsa_sign(Message, PrivKey, default, <<>>),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>;

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

split6(Bin,Acc) ->
    if(length(Acc)==6) ->
            lists:reverse([Bin|Acc]);
      true ->
          case binary:split(Bin,<<":">>) of
              [A,Rest] -> split6(Rest,[A|Acc]);
              [_] -> 
                  lists:reverse([Bin|Acc])
          end
    end.  

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

verify(#{
  from := From,
  public_key:=HPub,
  signature:=HSig
 }=Tx) ->
    Pub=hex:parse(HPub),
    Sig=hex:parse(HSig),
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

    Message=mkmsg(Tx),

    case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
        correct ->
            {ok, Tx};
        _ ->
            bad_sig
    end;

verify(Bin) when is_binary(Bin) ->
    Tx=unpack(Bin),
    verify(Tx).

pack(#{
  patch := BinPatch,
  signatures:=HSig,
  format := 1
 }) ->
    BinSig=lists:foldl(
             fun(Bin,Acc) ->
                     <<Acc/binary,(size(Bin)):8/integer,Bin/binary>>
             end,<<>>,HSig),
    Message=iolist_to_binary(
              io_lib:format("patch:~s:~s",
                            [
                             base64:encode(BinPatch),
                             base64:encode(BinSig)
                            ])
             ),
    Pub= <<>>,
    Sig= <<>>,
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>;


pack(#{
  from := From,
  portout := PortOut,
  timestamp := Timestamp,
  seq := Seq,
  public_key:=HPub,
  signature:=HSig,
  format := 1
 }) ->
    Pub=hex:parse(HPub),
    Sig=hex:parse(HSig),
    Message=iolist_to_binary(
              io_lib:format("portout:~s:~b:~b:~b",
                            [From,PortOut,Timestamp,Seq])
             ),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>;

pack(#{
  public_key:=HPub,
  signature:=HSig,
  format:=1
 }=Tx) ->
    Pub=hex:parse(HPub),
    Sig=hex:parse(HSig),
    Message=mkmsg(Tx),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>;

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
     ).

unpack(Tx) when is_map(Tx) ->
    Tx;

unpack(<<PubLen:8/integer,SigLen:8/integer,Tx/binary>>=BinTx) when PubLen==65 
                                                                   orelse PubLen==33 ->
    try
    <<Pub:PubLen/binary,Sig:SigLen/binary,Message/binary>>=Tx,
    case split6(Message,[]) of
        [From,To,SAmount,Cur,STimestamp,SSeq,ExtraJSON] ->
            Amount=binary_to_integer(SAmount),
            #{ from => From,
               to => To,
               amount => Amount,
               cur => Cur,
               timestamp => binary_to_integer(STimestamp),
               seq => binary_to_integer(SSeq),
               extradata => ExtraJSON,
               public_key=>bin2hex:dbin2hex(Pub),
               signature=>bin2hex:dbin2hex(Sig),
               format=>1
             };
        [<<"patch">>,BinPatch,BinSig] ->
            #{ patch => base64:decode(BinPatch),
               signatures=>unpack_binlist(base64:decode(BinSig),[]),
               format=>1
             };
        [<<"portout">>,From,PortOut,STimestamp,SSeq] ->
            #{ from => From,
               portout => binary_to_integer(PortOut),
               seq => binary_to_integer(SSeq),
               timestamp => binary_to_integer(STimestamp),
               public_key=>bin2hex:dbin2hex(Pub),
               signature=>bin2hex:dbin2hex(Sig),
               format=>1
             }
    end
    catch _:_ ->
              unpack_mp(BinTx)
    end;

unpack(BinTx) when is_binary(BinTx) ->
    unpack_mp(BinTx).

unpack_mp(BinTx) when is_binary(BinTx) ->
    {ok, #{
       <<"type">>:=Type,
       <<"tx">>:=Payload,
       <<"sig">>:=Sig
      }=Tx
    } = msgpack:unpack(BinTx),
    case Type of
        <<"tx">> ->
            [From,To,Amount, Cur, Timestamp, Seq, ExtraJSON] = Payload,
            T1=#{ type => Type,
                  from => From,
                  to => To,
                  amount => Amount,
                  cur => Cur,
                  timestamp => Timestamp,
                  seq => Seq,
                  extradata => ExtraJSON
                },
            T2=case maps:size(Sig) of 
                   1 -> 
                       [{Pub1,Sig1}]=maps:to_list(Sig),
                       T1#{ public_key=>Pub1, 
                          signature=>Sig1,
                          sig => Sig
                        };
                   _ ->
                       T1#{
                     sig => Sig
                    }
               end,
            case maps:is_key(<<"extdata">>,Tx) of
                   true ->
                       T2#{extdata=>maps:get(<<"extdata">>,Tx)};
                   false ->
                       T2#{}
               end;
        _ ->
            throw({"bad tx type",Type})
    end.

unpack_binlist(<<>>,A) -> lists:reverse(A);
unpack_binlist(<<S:8/integer,R/binary>>,A) ->
    <<Body:S/binary,Rest/binary>> = R,
    unpack_binlist(Rest,[Body|A]).



-ifdef(TEST).
new_tx_test() ->
    Priv=tpecdsa:generate_priv(),
    From=address:pub2addr(255,tpecdsa:calc_pub(Priv,true)),
    To=address:pub2addr(255,tpecdsa:calc_pub(tpecdsa:generate_priv(),true)),
    TestTx1=#{signature=>#{a=>123},
              extdata=>#{<<"aaa">>=>111,222=><<"bbb">>},
              from=>From,
              to=>To, 
              cur=><<"TEST">>,
              amount=>1, timestamp => os:system_time(millisecond), seq=>1},
    BinTx1=tx:sign(TestTx1, Priv),
    {ok, CheckTx1}=tx:verify(BinTx1),

    TestTx2=#{ from=>From,
             to=>To, 
             cur=><<"TEST">>,
             amount=>1, 
             timestamp => os:system_time(millisecond), 
             seq=>1
             },
    BinTx2=tx:sign(TestTx2, Priv),
    BinTx2r=tx:pack(tx:unpack(BinTx2)),
    {ok, CheckTx2}=tx:verify(BinTx2),
    {ok, CheckTx2r}=tx:verify(BinTx2r),
    ?assertEqual(#{invalid => 1,valid => 1},maps:get(sigverify,CheckTx1)),
    ?assertEqual(#{invalid => 0,valid => 1},maps:get(sigverify,CheckTx2)),
    ?assertEqual(#{invalid => 0,valid => 1},maps:get(sigverify,CheckTx2r)).

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
             amount => 10,
             format => 1
            },Pvt1),
    {ok,ExTx}=verify(BinTx2),
    {ok,ExTx1}=verify(tx:pack(tx:unpack(BinTx2))),
    [
     ?assertEqual(bin2hex:dbin2hex(Pub1Min),maps:get(public_key,ExTx)),
     ?assertEqual(bin2hex:dbin2hex(Pub1Min),maps:get(public_key,ExTx1)),
     ?assertEqual(ExTx,ExTx1)
    ].

-endif.


