-module(tx).

-export([get_ext/2, set_ext/3, sign/2, verify/1, verify/2, pack/1, unpack/1]).
-export([txlist_hash/1, rate/2, mergesig/2, verify1/1, mkmsg/1]).
-export([encode_purpose/1, decode_purpose/1, encode_kind/2, decode_kind/1, 
         construct_tx/1]).

-ifndef(TEST).
-define(TEST, 1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("apps/tpnode/include/tx_const.hrl").

mergesig(#{sig:=S1}=Tx1, #{sig:=S2}) ->
  Tx1#{sig=>
       maps:merge(S1, S2)
      }.

checkaddr(<<Ia:64/big>>) -> {true, Ia};
checkaddr(_) -> false.

get_ext(K, Tx) ->
  Ed=maps:get(extdata, Tx, #{}),
  case maps:is_key(K, Ed) of
    true ->
      {ok, maps:get(K, Ed)};
    false ->
      undefined
  end.

set_ext(<<"fee">>, V, Tx) ->
  Ed=maps:get(extdata, Tx, #{}),
  Tx#{
    extdata=>maps:put(fee, V, Ed)
   };

set_ext(<<"feecur">>, V, Tx) ->
  Ed=maps:get(extdata, Tx, #{}),
  Tx#{
    extdata=>maps:put(feecur, V, Ed)
   };

set_ext(K, V, Tx) when is_atom(K) ->
  Ed=maps:get(extdata, Tx, #{}),
  Tx#{
    extdata=>maps:put(atom_to_binary(K, utf8), V, Ed)
   };

set_ext(K, V, Tx) ->
  Ed=maps:get(extdata, Tx, #{}),
  Tx#{
    extdata=>maps:put(K, V, Ed)
   }.

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

-spec to_list(Arg :: binary() | list()) -> list().

to_list(Arg) when is_list(Arg) ->
  Arg;
to_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg).

to_binary(Arg) when is_binary(Arg) ->
  Arg;
to_binary(Arg) when is_list(Arg) ->
  list_to_binary(Arg).

construct_tx(#{
  kind:=register,
  t:=Timestamp
 }=Tx0) ->
  Tx=maps:with([ver,t],Tx0),
  E0=#{
    "k"=>encode_kind(2,register),
    "t"=>Timestamp,
    "e"=>to_binary(maps:get(txext, Tx, ""))
   },
  Tx0#{
    kind=>register,
    body=>msgpack:pack(E0,[{spec,new},{pack_str, from_list}]),
    sign=>#{}
   };

construct_tx(#{
  kind:=generic,
  from:=F,
  to:=To,
  t:=Timestamp,
  seq:=Seq,
  payload:=Amounts
 }=Tx0) ->
  Tx=maps:with([ver,from,to,t,seq,payload,call,extradata],Tx0),
  A1=lists:map(
       fun(#{amount:=Amount, cur:=Cur, purpose:=Purpose}) when
             is_integer(Amount), is_binary(Cur) ->
           [encode_purpose(Purpose), to_list(Cur), Amount]
       end, Amounts),
  Ext=maps:get(txext, Tx, #{}),
  true=is_map(Ext),
  E0=#{
    "k"=>encode_kind(2,generic),
    "f"=>F,
    "to"=>To,
    "t"=>Timestamp,
    "s"=>Seq,
    "p"=>A1,
    "e"=>Ext
   },
  {E1,Tx1}=case maps:find(call,Tx) of
             {ok, #{function:=Fun,args:=Args}} when is_binary(Fun),
                                                    is_list(Args) ->
               {E0#{"c"=>[Fun,Args]},Tx};
             _ ->
               {E0, maps:remove(call, Tx)}
           end,
  Tx1#{
    kind=>generic,
    body=>msgpack:pack(E1,[{spec,new},{pack_str, from_list}]),
    sign=>#{}
   }.

unpack_body(#{body:=Body}=Tx) ->
  {ok,#{"k":=IKind}=B}=msgpack:unpack(Body,[{spec,new},{unpack_str, as_list}]),
  {Ver, Kind}=decode_kind(IKind),
  unpack_body(Tx#{ver=>Ver, kind=>Kind},B).

unpack_body(#{ ver:=2,
              kind:=generic
             }=Tx,
            #{ "f":=From,
               "to":=To,
               "t":=Timestamp,
               "s":=Seq,
               "p":=Payload,
               "e":=Extradata
             }=Unpacked) ->
  Amounts=lists:map(
       fun([Purpose, Cur, Amount]) ->
         #{amount=>Amount,
           cur=>to_binary(Cur),
           purpose=>decode_purpose(Purpose)
          }
       end, Payload),
  Decoded=Tx#{
    ver=>2,
    from=>From,
    to=>To,
    t=>Timestamp,
    seq=>Seq,
    payload=>Amounts,
    txext=>Extradata
   },
  case maps:is_key("c",Unpacked) of
    false -> Decoded;
    true ->
      [Function, Args]=maps:get("c",Unpacked),
      Decoded#{
        call=>#{function=>Function, args=>Args}
       }
  end;

unpack_body(#{ ver:=2,
              kind:=register
             }=Tx,
            #{ "t":=Timestamp,
               "e":=Extradata
             }=_Unpacked) ->
  Tx#{
    ver=>2,
    t=>Timestamp,
    txext=>Extradata
   };

unpack_body(#{ver:=Ver, kind:=Kind},_Unpacked) ->
  throw({unknown_ver_or_kind,{Ver,Kind},_Unpacked}).

sign(#{kind:=_Kind,
       body:=Bin,
       sign:=PS}=Tx, PrivKey) ->
  Pub=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
  Sig = tpecdsa:secp256k1_ecdsa_sign(Bin, PrivKey, default, <<>>),
  Tx#{sign=>maps:put(Pub,Sig,PS)};

sign(#{
  from:=From
 }=Tx, PrivKey) ->
  Pub=tpecdsa:secp256k1_ec_pubkey_create(PrivKey, true),
  case checkaddr(From) of
    {true, _IAddr} ->
      ok;
    _ ->
      throw({invalid_address, from})
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
             case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
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

-type tx() :: tx2() | tx1().
-type tx2() :: #{
        ver:=non_neg_integer(),
        kind:=atom(),
        body:=binary(),
        sign:=map(),
        sigverify=>#{valid:=integer(),
                     invalid:=integer()
                    }
       }.
-type tx1() :: #{ 'patch':=binary(), 'sig':=list() } 
| #{ 'type':='register', 'pow':=binary(), 
     'register':=binary(), 'timestamp':=integer() }
| #{ from := binary(), sig := map(), timestamp := integer() }.

-spec verify(tx()|binary(), ['nocheck_ledger'| {ledger, pid()}]) ->
  {ok, tx()} | 'bad_sig'.

verify(Tx) ->
  verify(Tx, []).

verify(#{
  from:=From,
  body:=Body,
  sign:=HSigs,
  ver:=2,
  kind:=_K
 }=Tx, Opts) ->
  CI=get_ext(<<"contract_issued">>, Tx),
  Res=case checkaddr(From) of
        {true, _IAddr} when CI=={ok, From} ->
          %contract issued. Check nodes key.
          try
            maps:fold(
              fun(Pub, Sig, {AValid, AInvalid}) ->
                  case tpecdsa:secp256k1_ecdsa_verify(Body, Sig, Pub) of
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
          VerFun=case lists:member(nocheck_ledger,Opts) of
                   false ->
                     LedgerInfo=ledger:get(
                            proplists:get_value(ledger,Opts,ledger),
                            From),
                     case LedgerInfo of
                       #{pubkey:=PK} when is_binary(PK) ->
                         fun(Pub, Sig, {AValid, AInvalid}) ->
                             case tpecdsa:secp256k1_ecdsa_verify(Body, Sig, Pub) of
                               correct when PK==Pub ->
                                 {AValid+1, AInvalid};
                               _ ->
                                 {AValid, AInvalid+1}
                             end
                         end;
                       _ ->
                         throw({ledger_err, From})
                     end;
                   true ->
                     fun(Pub, Sig, {AValid, AInvalid}) ->
                         case tpecdsa:secp256k1_ecdsa_verify(Body, Sig, Pub) of
                           correct ->
                             {AValid+1, AInvalid};
                           _ ->
                             {AValid, AInvalid+1}
                         end
                     end
                 end,
          maps:fold(
            VerFun,
            {0, 0}, HSigs);
        _ ->
          throw({invalid_address, from})
      end,

  case Res of
    {0, _} ->
      bad_sig;
    {Valid, Invalid} when Valid>0 ->
      {ok, Tx#{
             sigverify=>#{
               valid=>Valid,
               invalid=>Invalid
              }
            }
      }
  end;

verify(#{
  body:=Body,
  sign:=HSigs,
  ver:=2,
  kind:=Kind
 }=Tx, _Opts) when Kind==register ->
  VerFun=fun(Pub, Sig, {AValid, AInvalid}) ->
             case tpecdsa:secp256k1_ecdsa_verify(Body, Sig, Pub) of
               correct ->
                 {AValid+1, AInvalid};
               _ ->
                 {AValid, AInvalid+1}
             end
         end,
  Res=maps:fold(
        VerFun,
        {0, 0}, HSigs),
  case Res of
    {0, _} ->
      bad_sig;
    {Valid, Invalid} when Valid>0 ->
      {ok, Tx#{
             sigverify=>#{
               valid=>Valid,
               invalid=>Invalid
              }
            }
      }
  end;



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

  CI=get_ext(<<"contract_issued">>, Tx),
  {Valid, Invalid}=case checkaddr(From) of
                     {true, _IAddr} when CI=={ok, From} ->
                       %contract issued. Check nodes key.
                       try
                         maps:fold(
                           fun(Pub, Sig, {AValid, AInvalid}) ->
                               case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
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
                                      case tpecdsa:secp256k1_ecdsa_verify(Message, Sig, Pub) of
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
  settings:verify(Patch);

verify(Bin, Opts) when is_binary(Bin) ->
  Tx=unpack(Bin),
  verify(Tx, Opts).

-spec pack(tx()) -> binary().

pack(#{ ver:=2,
        body:=Bin,
        sign:=PS}) ->
  msgpack:pack(
    #{"ver"=>2,
      "body"=>Bin,
      "sign"=>PS
     },[{spec,new},{pack_str, from_list}]);

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

unpack(Tx) when is_map(Tx) ->
  Tx;

unpack(BinTx) when is_binary(BinTx) ->
  unpack_mp(BinTx).

unpack_mp(BinTx) when is_binary(BinTx) ->
  {ok, Tx0} = msgpack:unpack(BinTx, [{known_atoms,
                                      [type, sig, tx, patch, register,
                                       register, address, block] },
                                     {unpack_str, as_binary}] ),
  case Tx0 of
    #{<<"ver">>:=2, <<"sign">>:=Sign, <<"body">>:=TxBody} ->
      unpack_body(#{ver=>2,
                    sign=>Sign,
                    body=>TxBody
                   });
    _ ->
      Tx=maps:fold(
           fun
             ("tx", Val, Acc) ->
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
          maps:fold( fun set_ext/3, R, maps:get(<<"extdata">>, Tx));
        false ->
          R
      end
  end.

txlist_hash(List) ->
  crypto:hash(sha256,
              iolist_to_binary(lists:foldl(
                                 fun({Id, Bin}, Acc) when is_binary(Bin) ->
                                     [Id, Bin|Acc];
                                    ({Id, #{}=Tx}, Acc) ->
                                     [Id, tx:pack(Tx)|Acc]
                                 end, [], lists:keysort(1, List)))).

rate1(#{extradata:=ED}, Cur, TxAmount, GetRateFun) ->
  #{<<"base">>:=Base,
    <<"kb">>:=KB}=Rates=GetRateFun(Cur),
  BaseEx=maps:get(<<"baseextra">>, Rates, 0),
  ExtCur=max(0, size(ED)-BaseEx),
  Cost=Base+trunc(ExtCur*KB/1024),
  {TxAmount >= Cost,
   #{ cur=>Cur,
      cost=>Cost,
      tip => max(0, TxAmount - Cost)
    }}.

rate(#{cur:=TCur}=Tx, GetRateFun) ->
  try
    case maps:get(extdata, Tx, #{}) of
      #{fee:=TxAmount, feecur:=Cur} ->
        rate1(Tx, Cur, TxAmount, GetRateFun);
      #{fee:=TxAmount} ->
        rate1(Tx, TCur, TxAmount, GetRateFun);
      _ ->
        case GetRateFun({params, <<"feeaddr">>}) of
          X when is_binary(X) ->
            {false, #{ cost=>null } };
          _ ->
            {true, #{ cost=>0, tip => 0, cur=>TCur }}
        end
    end
  catch _:_ -> throw('cant_calculate_fee')
  end.

-ifdef(TEST).
register_test() ->
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

tx_jsondata_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24, 240,
          248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  %Pub1Min=tpecdsa:secp256k1_ec_pubkey_create(Pvt1, true),
  From=(naddress:construct_public(0, 0, 1)),
  BinTx1=sign(#{
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
  BinTx2=sign(#{
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
   ?assertMatch({true, #{cost:=20, tip:=10}}, rate(UTx1, GetRateFun)),
   ?assertMatch({false, #{cost:=20, tip:=0}}, rate(UTx2, GetRateFun))
  ].

digaddr_tx_test() ->
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

patch_test() ->
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
  io:format("PK ~p~n", [settings:verify(Patch)]),
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

txs_sig_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Addr=naddress:construct_public(1, 2, 3),
  BinTx1=sign(#{
           from => Addr,
           to => Addr,
           cur => <<"test">>,
           timestamp => 1512450000,
           seq => 1,
           amount => 10
          }, Pvt1),
  BinTx2=sign(#{
           from => Addr,
           to => Addr,
           cur => <<"test2">>,
           timestamp => 1512450011,
           seq => 2,
           amount => 20
          }, Pvt1),
  Txs=[{<<"txid1">>, BinTx1}, {<<"txid2">>, BinTx2}],
  H1=txlist_hash(Txs),

  Txs2=[ {<<"txid2">>, tx:unpack(BinTx2)}, {<<"txid1">>, tx:unpack(BinTx1)} ],
  H2=txlist_hash(Txs2),

  Txs3=[ {<<"txid1">>, tx:unpack(BinTx2)}, {<<"txid2">>, tx:unpack(BinTx1)} ],
  H3=txlist_hash(Txs3),

  [
   ?assertEqual(H1, H2),
   ?assertNotEqual(H1, H3)
  ].

tx2_reg_test() ->
  Pvt1= <<194, 124, 65, 109, 233, 236, 108, 24, 50, 151, 189, 216, 23, 42, 215, 220, 24,
          240, 248, 115, 150, 54, 239, 58, 218, 221, 145, 246, 158, 15, 210, 165>>,
  Pub=tpecdsa:calc_pub(Pvt1,true),
  T1=#{
    kind => register,
    t => 1530106238743,
    ver => 2
   },
  TXConstructed=tx:construct_tx(T1),
  Packed=tx:pack(tx:sign(TXConstructed,Pvt1)),
  [
  ?assertMatch({ok,#{sigverify:=#{valid:=1,invalid:=0}}}, verify(Packed, [])),
  ?assertMatch({ok,#{sign:=#{Pub:=_}} }, verify(Packed))
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
    seq => 5,sign => #{},t => 1530106238743,
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
                            sigverify:=#{valid:=1,invalid:=0}
                           }}, verify(Packed, [{ledger, LedgerPID}]))
           ]
       end,
  Ledger=[ {<<128,0,32,0,2,0,0,3>>, bal:put(pubkey, PubKey, bal:new()) } ],
  ledger:deploy4test(Ledger, Test).
-endif.


