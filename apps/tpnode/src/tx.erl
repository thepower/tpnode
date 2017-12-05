-module(tx).

-export([sign/2,verify/1,pack/1,unpack/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

mkmsg(#{ from:=From, amount:=Amount,
         cur:=Currency, to:=To,
         seq:=Seq, timestamp:=Timestamp
       }=Tx) ->
    {ToValid,_}=address:check(To),
    if not ToValid -> 
           throw({invalid_address,to});
       true -> ok
    end,

    Append=maps:get(extradata,Tx,<<"">>),

    iolist_to_binary(
              io_lib:format("~s:~s:~b:~s:~b:~b:~s",
                            [From,To,trunc(1.0e9*Amount),Currency,Timestamp,Seq,Append])
             );
mkmsg(#{ from := From, portout := PortOut,
         timestamp := Timestamp, seq := Seq }) ->
    iolist_to_binary(
      io_lib:format("portout:~s:~b:~b:~b",
                    [From,PortOut,Timestamp,Seq])
     ).

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
           io:format("~s~n~s~n",[From,NewFrom]),
           throw({invalid_key,mismatch_from_address});
       true -> ok
    end,

    Message=mkmsg(Tx),

    Sig = tpecdsa:secp256k1_ecdsa_sign(Message, PrivKey, default, <<>>),
    %io:format("pub ~b sig ~b msg ~p~n",[
    %                                    size(Pub),
    %                                    size(Sig), 
    %                                    size(Message)
    %                                   ]),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>.

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
           %io:format("~s~n~s~n",[From,NewFrom]),
           throw({invalid_key,mismatch_from_address});
       true -> ok
    end,

    Message=mkmsg(Tx),

    %io:format("~s~n",[Message]),
    case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
        correct ->
            {ok, Tx};
        _ ->
            bad_sig
    end;

verify(<<_Pub:65/binary,_Sig:70/binary,_Message/binary>>=Bin) ->
    Tx=unpack(Bin),
    verify(Tx);

verify(_) ->
    bad_format.

pack(#{
  from := From,
  portout := PortOut,
  timestamp := Timestamp,
  seq := Seq,
  public_key:=HPub,
  signature:=HSig
 }) ->
    Pub=hex:parse(HPub),
    Sig=hex:parse(HSig),
    Message=iolist_to_binary(
              io_lib:format("portout:~s:~b:~b:~b",
                            [From,PortOut,Timestamp,Seq])
             ),
    %io:format("~s~n",[Message]),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>;


pack(#{
  public_key:=HPub,
  signature:=HSig
 }=Tx) ->
    Pub=hex:parse(HPub),
    Sig=hex:parse(HSig),
    Message=mkmsg(Tx),
    %io:format("~s~n",[Message]),
    <<(size(Pub)):8/integer,
      (size(Sig)):8/integer,
      Pub/binary,
      Sig/binary,
      Message/binary>>.

unpack(<<PubLen:8/integer,SigLen:8/integer,Tx/binary>>) ->
    <<Pub:PubLen/binary,Sig:SigLen/binary,Message/binary>>=Tx,
    case split6(Message,[]) of
        [From,To,SAmount,Cur,STimestamp,SSeq,ExtraJSON] ->
            Amount=binary_to_integer(SAmount),
            #{ from => From,
               to => To,
               amount => Amount/1.0e9,
               cur => Cur,
               timestamp => binary_to_integer(STimestamp),
               seq => binary_to_integer(SSeq),
               extradata => ExtraJSON,
               public_key=>bin2hex:dbin2hex(Pub),
               signature=>bin2hex:dbin2hex(Sig)
             };
        [<<"portout">>,From,PortOut,STimestamp,SSeq] ->
            #{ from => From,
               portout => binary_to_integer(PortOut),
               seq => binary_to_integer(SSeq),
               timestamp => binary_to_integer(STimestamp),
               public_key=>bin2hex:dbin2hex(Pub),
               signature=>bin2hex:dbin2hex(Sig)
             }
    end.

-ifdef(TEST).
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
    BinTx2=try
               sign(#{
                 from => From,
                 to => Dst,
                 cur => <<"test">>,
                 timestamp => 1512450000,
                 seq => 1,
                 amount => 10
                },Pvt1)
           catch throw:Ee2 ->
                     {throw,Ee2}
           end,
    io:format("Bin2 ~p~n",[BinTx2]),
    {ok,ExTx}=verify(BinTx2),
    ?assertEqual(bin2hex:dbin2hex(Pub1Min),maps:get(public_key,ExTx)).

-endif.


