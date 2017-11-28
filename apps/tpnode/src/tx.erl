-module(tx).

-export([sign/2,verify/1,pack/1,unpack/1]).

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
    Pub=secp256k1:secp256k1_ec_pubkey_create(PrivKey, false),
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

    Msg32 = crypto:hash(sha256, Message),
    Sig = secp256k1:secp256k1_ecdsa_sign(Msg32, PrivKey, default, <<>>),
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
    Msg32 = crypto:hash(sha256, Message),
    case secp256k1:secp256k1_ecdsa_verify(Msg32, Sig, Pub) of
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

