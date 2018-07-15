-module(tx).

-export([get_ext/2, set_ext/3, sign/2, verify/1, verify/2, pack/1, unpack/1]).
-export([txlist_hash/1, rate/2, mergesig/2]).
-export([encode_purpose/1, decode_purpose/1, encode_kind/2, decode_kind/1,
         construct_tx/1,construct_tx/2, get_payload/2]).
-export([hashdiff/1,upgrade/1]).

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


-spec to_list(Arg :: binary() | list()) -> list().

to_list(Arg) when is_list(Arg) ->
  Arg;
to_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg).

to_binary(Arg) when is_binary(Arg) ->
  Arg;
to_binary(Arg) when is_list(Arg) ->
  list_to_binary(Arg).

pack_body(Body) ->
  msgpack:pack(Body,[{spec,new},{pack_str, from_list}]).

construct_tx(Any) ->
  construct_tx(Any,[]).

construct_tx(#{
  kind:=register,
  t:=Timestamp,
  keys:=PubKeys
 }=Tx0,Params) ->
  Tx=maps:with([ver,t,txext],Tx0),
  Keys1=iolist_to_binary(lists:sort(PubKeys)),
  KeysH=crypto:hash(sha256,Keys1),
  E0=#{
    "k"=>encode_kind(2,register),
    "t"=>Timestamp,
    "e"=>maps:get(txext, Tx, #{}),
    "h"=>KeysH
   },

  InvBody=case Tx0 of
            #{inv:=Invite} ->
              E0#{"inv"=>crypto:hash(sha256,Invite)};
            _ ->
              E0
          end,

  PowBody=case proplists:get_value(pow_diff,Params) of
            undefined -> InvBody;
            I when is_integer(I) ->
              mine_sha512(InvBody, 0, I)
          end,

  case Tx0 of
    #{inv:=Invite1} ->
      maps:remove(keys,
                  Tx0#{
                    inv=>Invite1,
                    kind=>register,
                    body=>pack_body(PowBody),
                    keysh=>KeysH,
                    sig=>#{}
                   });
    _ ->
      maps:remove(keys,
                  Tx0#{
                    kind=>register,
                    body=>pack_body(PowBody),
                    keysh=>KeysH,
                    sig=>#{}
                   })
  end;

construct_tx(#{
  kind:=generic,
  from:=F,
  to:=To,
  t:=Timestamp,
  seq:=Seq,
  payload:=Amounts
 }=Tx0,_Params) ->
  Tx=maps:with([ver,from,to,t,seq,payload,call,txext],Tx0),
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
    sig=>#{}
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
               "e":=Extradata,
               "h":=Hash
             }=_Unpacked) ->
  Tx#{
    ver=>2,
    t=>Timestamp,
    keysh=>Hash,
    txext=>Extradata
   };

unpack_body(#{ver:=Ver, kind:=Kind},_Unpacked) ->
  throw({unknown_ver_or_kind,{Ver,Kind},_Unpacked}).

sign(#{kind:=_Kind,
       body:=Bin,
       sig:=PS}=Tx, PrivKey) ->
  Pub=tpecdsa:calc_pub(PrivKey, true),
  Sig = tpecdsa:sign(Bin, PrivKey),
  Tx#{sig=>maps:put(Pub,Sig,PS)};

sign(Any, PrivKey) ->
  tx1:sign(Any, PrivKey).


-type tx() :: tx2() | tx1().
-type tx2() :: #{
        ver:=non_neg_integer(),
        kind:=atom(),
        body:=binary(),
        sig:=map(),
        sigverify=>#{valid:=integer(),
                     invalid:=integer()
                    }
       }.
-type tx1() :: #{ 'patch':=binary(), 'sig':=list() }
| #{ 'type':='register', 'pow':=binary(),
     'register':=binary(), 'timestamp':=integer() }
| #{ from := binary(), sig := map(), timestamp := integer() }.

-spec verify(tx()|binary()) ->
  {ok, tx()} | 'bad_sig'.

verify(Tx) ->
  verify(Tx, []).

-spec verify(tx()|binary(), ['nocheck_ledger'| {ledger, pid()}]) ->
  {ok, tx()} | 'bad_sig'.

verify(#{
  kind:=generic,
  from:=From,
  body:=Body,
  sig:=HSigs,
  ver:=2
 }=Tx, Opts) ->
  CI=get_ext(<<"contract_issued">>, Tx),
  Res=case checkaddr(From) of
        {true, _IAddr} when CI=={ok, From} ->
          %contract issued. Check nodes key.
          try
            maps:fold(
              fun(Pub, Sig, {AValid, AInvalid}) ->
                  case tpecdsa:verify(Body, Pub, Sig) of
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
                             case tpecdsa:verify(Body, Pub, Sig) of
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
                         case tpecdsa:verify(Body, Pub, Sig) of
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
  kind:=register,
  body:=Body,
  sig:=HSigs,
  ver:=2
 }=Tx, _Opts) ->
  VerFun=fun(Pub, Sig, {AValid, AInvalid}) ->
             case tpecdsa:verify(Body, Pub, Sig) of
               correct ->
                 {[Pub|AValid], AInvalid};
               _ ->
                 {AValid, AInvalid+1}
             end
         end,
  Res=maps:fold(
        VerFun,
        {[], 0}, HSigs),
  case Res of
    {0, _} ->
      bad_sig;
    {Valid, Invalid} when length(Valid)>0 ->
      BodyHash=hashdiff(crypto:hash(sha512,Body)),
      Pubs=crypto:hash(sha256,iolist_to_binary(lists:sort(Valid))),
      #{keysh:=H}=unpack_body(Tx),
      if Pubs==H ->
           {ok, Tx#{
                  sigverify=>#{
                    pow_diff=>BodyHash,
                    valid=>length(Valid),
                    invalid=>Invalid
                   }
                 }
           };
         true ->
           bad_keys
      end
  end;


verify(Bin, Opts) when is_binary(Bin) ->
  Tx=unpack(Bin),
  verify(Tx, Opts);

verify(Struct, Opts) ->
  tx1:verify(Struct, Opts).

-spec pack(tx()) -> binary().

pack(#{ ver:=2,
        body:=Bin,
        sig:=PS}=Tx) ->
  T=#{"ver"=>2,
      "body"=>Bin,
      "sig"=>PS
     },
  T1=case Tx of
    #{inv:=Invite} ->
         T#{"inv"=>Invite};
       _ ->
         T
     end,
  msgpack:pack(T1,[
                  {spec,new},
                  {pack_str, from_list}
                 ]);

pack(Any) ->
  tx1:pack(Any).

unpack(Tx) when is_map(Tx) ->
  Tx;

unpack(BinTx) when is_binary(BinTx) ->
  {ok, Tx0} = msgpack:unpack(BinTx, [{known_atoms,
                                      [type, sig, tx, patch, register,
                                       register, address, block ] },
                                     {unpack_str, as_binary}] ),
  case Tx0 of
    #{<<"ver">>:=2, sig:=Sign, <<"body">>:=TxBody, <<"inv">>:=Inv} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody,
        inv=>Inv
       });
    #{<<"ver">>:=2, sig:=Sign, <<"body">>:=TxBody} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody
       });
    #{<<"ver">>:=2, <<"sig">>:=Sign, <<"body">>:=TxBody, <<"inv">>:=Inv} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody,
        inv=>Inv
       });
    #{<<"ver">>:=2, <<"sig">>:=Sign, <<"body">>:=TxBody} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody
       });
    _ ->
      tx1:unpack_mp(Tx0)
  end.

txlist_hash(List) ->
  crypto:hash(sha256,
              iolist_to_binary(lists:foldl(
                                 fun({Id, Bin}, Acc) when is_binary(Bin) ->
                                     [Id, Bin|Acc];
                                    ({Id, #{}=Tx}, Acc) ->
                                     [Id, tx:pack(Tx)|Acc]
                                 end, [], lists:keysort(1, List)))).

get_payload(#{ver:=2, kind:=generic, payload:=Payload}=_Tx, Purpose) ->
  lists:foldl(
    fun(#{amount:=_,cur:=_,purpose:=P1}=A, undefined) when P1==Purpose ->
        A;
       (_,A) ->
        A
    end, undefined, Payload).


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

rate2(#{body:=Body}, Cur, TxAmount, GetRateFun) ->
  #{<<"base">>:=Base,
    <<"kb">>:=KB}=Rates=GetRateFun(Cur),
  BaseEx=maps:get(<<"baseextra">>, Rates, 0),
  BodySize=size(Body)-32, %correcton rate
  ExtCur=max(0, BodySize-BaseEx),
  Cost=Base+trunc(ExtCur*KB/1024),
  {TxAmount >= Cost,
   #{ cur=>Cur,
      cost=>Cost,
      tip => max(0, TxAmount - Cost)
    }}.

rate(#{ver:=2, kind:=generic}=Tx, GetRateFun) ->
  try
    case get_payload(Tx, srcfee) of
      #{cur:=Cur, amount:=TxAmount} ->
        rate2(Tx, Cur, TxAmount, GetRateFun);
      _ ->
        case GetRateFun({params, <<"feeaddr">>}) of
          X when is_binary(X) ->
            {false, #{ cost=>null } };
          _ ->
            {true, #{ cost=>0, tip => 0, cur=><<"NONE">> }}
        end
    end
  catch _:_ -> throw('cant_calculate_fee')
  end;


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

intdiff(I) when I>0 andalso I<128 ->
  intdiff(I bsl 1)+1;

intdiff(_I) ->
  0.

hashdiff(<<0,_Rest/binary>>) ->
  hashdiff(_Rest)+8;

hashdiff(<<I:8/integer,_Rest/binary>>) ->
  intdiff(I);

hashdiff(_) ->
  0.

mine_sha512(Body, Nonce, Diff) ->
  DS=Body#{pow=>Nonce},
%  if Nonce rem 1000000 == 0 ->
%       io:format("nonce ~w~n",[Nonce]);
%     true -> ok
%  end,
  Hash=crypto:hash(sha512,pack_body(DS)),
  Act=if Diff rem 8 == 0 ->
           <<Act1:Diff/big,_/binary>>=Hash,
           Act1;
         true ->
           Pad=8-(Diff rem 8),
           <<Act1:Diff/big,_:Pad/big,_/binary>>=Hash,
           Act1
      end,
  if Act==0 ->
       %io:format("Mined nonce ~w~n",[Nonce]),
       DS;
     true ->
       mine_sha512(Body,Nonce+1,Diff)
  end.

upgrade(#{
  from:=From,
  to:=To,
  amount:=Amount,
  cur:=Cur,
  seq:=Seq,
  timestamp:=T
 }=Tx) ->
  DED=jsx:decode(maps:get(extradata, Tx, "{}"), [return_maps]),
  Fee=case DED of 
        #{ <<"fee">>:=FeeA, <<"feecur">>:=FeeC } ->
          [#{amount=>FeeA, cur=>FeeC, purpose=>srcfee}];
        _ ->
          []
      end,
  TxExt=case DED of
          #{<<"message">>:=Msg} ->
            #{msg=>Msg};
          _ ->
            #{}
        end,
  construct_tx(#{
    ver=>2,
    kind=>generic,
    from=>From,
    to=>To,
    t=>T,
    seq=>Seq,
    payload=>[#{amount=>Amount, cur=>Cur, purpose=>transfer}|Fee],
    txext => TxExt
   }).





-ifdef(TEST).
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
  ?assertMatch(<<0,0,_/binary>>, crypto:hash(sha512,maps:get(body,unpack(Packed)))),
  ?assertMatch(#{ ver:=2, kind:=register, keysh:=_}, TXConstructed),
  ?assertMatch(#{ ver:=2, kind:=register, keysh:=_}, tx:unpack(Packed)),
  ?assertMatch({ok,_}, verify(Packed, [])),
  ?assertMatch({ok,#{sigverify:=#{pow_diff:=PD,valid:=2,invalid:=0}}}
                 when PD>=16, verify(Packed, [])),
  ?assertMatch({ok,#{sig:=#{Pub1:=_,Pub2:=_}} }, verify(Packed))
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
                           }}, verify(Packed, [{ledger, LedgerPID}]))
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
   ?assertMatch({true, #{cost:=20, tip:=10}}, rate(UTx1, GetRateFun)),
   ?assertMatch({false, #{cost:=20, tip:=0}}, rate(UTx2, GetRateFun))
  ].


-endif.

