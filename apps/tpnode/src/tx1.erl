-module(tx1).

-export([sign/2,verify1/1,verify/2,pack/1,unpack_mp/1,mkmsg/1]).

checkaddr(<<Ia:64/big>>) -> {true, Ia};
checkaddr(_) -> false.

mkmsg(#{ from:=From,
         deploy:=VMType,
         code:=NewCode,
         seq:=Seq,
         timestamp:=Timestamp
       }=Tx) ->
  if is_binary(From) -> ok;
     true -> throw('non_bin_addr_from')
  end,
  if is_binary(VMType) -> ok;
     true -> throw('non_bin_vmtype')
  end,
  if is_binary(NewCode) -> ok;
     true -> throw('non_bin_code')
  end,
  TB=case maps:is_key(state, Tx) of
       true ->
         State=maps:get(state, Tx),
         if is_binary(State) -> ok;
            true -> throw('non_bin_state')
         end,
         [
          "deploy",
          From,
          Timestamp,
          Seq,
          VMType,
          NewCode,
          State
         ];
       false ->
         [
          "deploy",
          From,
          Timestamp,
          Seq,
          VMType,
          NewCode
         ]
     end,
  msgpack:pack(TB);

mkmsg(#{ from:=From, amount:=Amount,
         cur:=Currency, to:=To,
         seq:=Seq, timestamp:=Timestamp
       }=Tx) ->
  %{ToValid, _}=checkaddr(To),
  %if not ToValid ->
  %       throw({invalid_address, to});
  %   true -> ok
  %end,

  case maps:is_key(outbound, Tx) of
    true ->
      lager:notice("MKMSG FIXME: save outbound flag in tx");
    false -> ok
  end,
  Append=maps:get(extradata, Tx, <<"">>),
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
                to_list(Currency),
                Timestamp,
                Seq,
                to_list(Append)
               ]);

mkmsg(Unknown) ->
  throw({unknown_tx_type, Unknown}).

sign(#{
  from:=From
 }=Tx, PrivKey) ->
  Pub=tpecdsa:calc_pub(PrivKey, true),
  case checkaddr(From) of
    {true, _IAddr} ->
      ok;
    _ ->
      throw({invalid_address, from})
  end,

  TxBin=mkmsg(Tx),
  {ok, [MType|LTx]} = msgpack:unpack(TxBin),

  Sig = tpecdsa:sign(TxBin, PrivKey),

  msgpack:pack(
    maps:merge(
      #{
      type => MType,
      tx => LTx,
      sig => maps:put(Pub, Sig, maps:get(signature, Tx, #{}) )
     },
      maps:with([extdata], Tx))
   ).

verify1(#{
  from := _From,
  sig := HSigs,
  timestamp := T
 }=Tx) ->
  Message=mkmsg(Tx),
  if is_integer(T) ->
       ok;
     true ->
       throw({bad_timestamp, T})
  end,
  VerFun=fun(Pub, Sig, {AValid, AInvalid}) ->
             case tpecdsa:verify(Message, Pub, Sig) of
               correct ->
                 {AValid+1, AInvalid};
               _ ->
                 {AValid, AInvalid+1}
             end
         end,
  {Valid, Invalid}=maps:fold(
                     VerFun,
                     {0, 0}, HSigs),

  case Valid of
    0 ->
      {bad_sig, hex:encode(Message)};
    N when N>0 ->
      {ok, Tx#{
             sigverify=>#{
               valid=>Valid,
               invalid=>Invalid
              }
            }
      }
  end.

pack(#{
  hash:=_,
  header:=_,
  sign:=_
 }=Block) ->
  msgpack:pack(
    #{
    type => <<"block">>,
    block => block:pack(Block)
   }
   );

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
      maps:with([extdata], Tx))
   );

pack(#{
  register:=Reg
 }=Tx) ->
  msgpack:pack(
    maps:merge(
      maps:with([address, timestamp, pow], Tx),
      #{ type => <<"register">>,
         register => Reg
       }
     )
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
      maps:with([extdata], Tx))
   );

pack(Unknown) ->
  throw({unknown_tx_to_pack, Unknown}).

-spec to_list(Arg :: binary() | list()) -> list().

to_list(Arg) when is_list(Arg) ->
  Arg;
to_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg).

verify(null, _) ->
  throw(no_transaction);

verify(#{register:=_, type:=register}=Tx, _) ->
  {ok, Tx};

verify(#{
  from := From,
  sig := HSigs,
  timestamp := T
 }=Tx, Opts) ->
  Message=mkmsg(Tx),
  if is_integer(T) ->
       ok;
     true ->
       throw({bad_timestamp, T})
  end,

  CI=tx:get_ext(<<"contract_issued">>, Tx),
  {Valid, Invalid}=case checkaddr(From) of
                     {true, _IAddr} when CI=={ok, From} ->
                       %contract issued. Check nodes key.
                       try
                         maps:fold(
                           fun(Pub, Sig, {AValid, AInvalid}) ->
                               case tpecdsa:verify(Message, Pub, Sig) of
                                 correct ->
                                   V=chainsettings:is_our_node(Pub) =/= false,
                                   if V ->
                                        {AValid+1, AInvalid};
                                      true ->
                                        {AValid, AInvalid+1}
                                   end;
                                 _ ->
                                   {AValid, AInvalid+1}
                               end
                           end,
                           {0, 0}, HSigs)
                       catch _:_ ->
                               throw(verify_error)
                       end;
                     {true, _IAddr} ->
                       LedgerInfo=ledger:get(
                                    proplists:get_value(ledger,Opts,ledger),
                                    From),
                       case LedgerInfo of
                         #{pubkey:=PK} when is_binary(PK) ->
                           VerFun=fun(Pub, Sig, {AValid, AInvalid}) ->
                                      case tpecdsa:verify(Message, Pub, Sig) of
                                        correct when PK==Pub ->
                                          {AValid+1, AInvalid};
                                        _ ->
                                          {AValid, AInvalid+1}
                                      end
                                  end,
                           maps:fold(
                             VerFun,
                             {0, 0}, HSigs);
                         _ ->
                           throw({ledger_err, From})
                       end;
                     _ ->
                       throw({invalid_address, from})
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

verify(#{patch:=_, sig:=_}=Patch, _) ->
  settings:verify(Patch).

unpack_mp(Tx0) ->
  Tx=maps:fold(
       fun ("tx", Val, Acc) ->
           maps:put(tx,
                    lists:map(
                      fun(LI) when is_list(LI) ->
                          list_to_binary(LI);
                         (OI) -> OI
                      end, Val), Acc);
           ("type", Val, Acc) ->
           maps:put(type,
                    try
                      erlang:list_to_existing_atom(Val)
                    catch error:badarg ->
                            Val
                    end, Acc);
           ("address", Val, Acc) ->
           maps:put(address,
                    list_to_binary(Val),
                    Acc);
           ("register", Val, Acc) ->
           maps:put(register,
                    list_to_binary(Val),
                    Acc);
           ("sig", Val, Acc) ->
           maps:put(sig,
                    if is_map(Val) ->
                         maps:fold(
                           fun(PubK, PrivK, KAcc) ->
                               maps:put(
                                 iolist_to_binary(PubK),
                                 iolist_to_binary(PrivK),
                                 KAcc)
                           end, #{}, Val);
                       is_list(Val) ->
                         lists:foldl(
                           fun([PubK, PrivK], KAcc) ->
                               maps:put(PubK, PrivK, KAcc)
                           end, #{}, Val)
                    end,
                    Acc);
           (sig, Val, Acc) ->
           maps:put(sig,
                    if is_map(Val) ->
                         maps:fold(
                           fun(PubK, PrivK, KAcc) ->
                               maps:put(
                                 iolist_to_binary(PubK),
                                 iolist_to_binary(PrivK),
                                 KAcc)
                           end, #{}, Val);
                       is_list(Val) ->
                         case Val of
                           [X|_] when is_binary(X) ->
                             Val;
                           [[_, _]|_] ->
                             lists:foldl(
                               fun([PubK, PrivK], KAcc) ->
                                   maps:put(PubK, PrivK, KAcc)
                               end, #{}, Val)
                         end;
                       Val==<<>> ->
                         lager:notice("Temporary workaround. Fix me"),
                         []
                    end,
                    Acc);
           (K, Val, Acc) ->
           maps:put(K, Val, Acc)
       end, #{}, Tx0),
      #{type:=Type}=Tx,
      R=case Type of
          <<"deploy">> ->
            #{sig:=Sig}=Tx,
            lager:debug("tx ~p", [Tx]),
            [From, Timestamp, Seq, VMType, NewCode| State] = maps:get(tx, Tx),
            if is_integer(Timestamp) -> ok;
               true -> throw({bad_timestamp, Timestamp})
            end,
            if is_binary(From) -> ok;
               true -> throw({bad_type, from})
            end,
            if is_binary(NewCode) -> ok;
               true -> throw({bad_type, code})
            end,
            if is_binary(VMType) -> ok;
               true -> throw({bad_type, deploy})
            end,
            FTx=#{ type => Type,
                   from => From,
                   timestamp => Timestamp,
                   seq => Seq,
                   deploy => VMType,
                   code => NewCode,
                   sig => Sig
                 },
            case State of
              [] -> FTx;
              [St] ->
                if is_binary(St) -> ok;
                   true -> throw({bad_type, state})
                end,
                FTx#{state => St}
            end;
          tx -> %generic finance tx
            #{sig:=Sig}=Tx,
            lager:debug("tx ~p", [Tx]),
            [From, To, Amount, Cur, Timestamp, Seq, ExtraJSON] = maps:get(tx, Tx),
            if is_integer(Timestamp) ->
                 ok;
               true ->
                 throw({bad_timestamp, Timestamp})
            end,
            FTx=#{ type => Type,
                   from => From,
                   to => To,
                   amount => Amount,
                   cur => Cur,
                   timestamp => Timestamp,
                   seq => Seq,
                   extradata => ExtraJSON,
                   sig => Sig
                 },
            case maps:is_key(<<"extdata">>, Tx) of
              true -> FTx;
              false ->
                try %parse fee data, if no extdata
                  DecodedJSON=jsx:decode(ExtraJSON, [return_maps]),
                  %make exception if no cur data
                  #{<<"fee">> := Fee,
                    <<"feecur">> := FeeCur}=DecodedJSON,
                  true=is_integer(Fee),
                  true=is_binary(FeeCur),
                  FTx#{extdata=> #{
                         fee=>Fee,
                         feecur=>FeeCur
                        }}
                catch _:_ ->
                        FTx
                end
            end;

          block ->
            block:unpack(maps:get(block, Tx));

          patch -> %settings patch
            #{sig:=Sig}=Tx,
            #{ patch => maps:get(patch, Tx),
               sig => Sig};

          register ->
            PubKey=maps:get(register, Tx),
            T=maps:get(<<"timestamp">>, Tx, 0),
            POW=maps:get(<<"pow">>, Tx, <<>>),
            case size(PubKey) of
              33 -> ok;
              _ -> throw('bad_pubkey')
            end,
            case maps:is_key(address, Tx) of
              false ->
                #{ type => register,
                   register => PubKey,
                   timestamp => T,
                   pow => POW
                 };
              true ->
                #{ type => register,
                   register => PubKey,
                   timestamp => T,
                   pow => POW,
                   address => maps:get(address, Tx)
                 }
            end;

          _ ->
            lager:error("Bad tx ~p", [Tx]),
            throw({"bad tx type", Type})
        end,
      case maps:is_key(<<"extdata">>, Tx) of
        true ->
          %probably newly parsed extdata should have priority? or not?
          maps:fold( fun tx:set_ext/3, R, maps:get(<<"extdata">>, Tx));
        false ->
          R
      end.


