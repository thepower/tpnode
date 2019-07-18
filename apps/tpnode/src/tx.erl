-module(tx).

-export([del_ext/2, get_ext/2, set_ext/3]).
-export([sign/2, verify/1, verify/2, pack/1, pack/2, unpack/1, unpack/2]).
-export([txlist_hash/1, rate/2, mergesig/2]).
-export([encode_purpose/1, decode_purpose/1, encode_kind/2, decode_kind/1]).
-export([construct_tx/1,construct_tx/2, get_payload/2, get_payloads/2]).
-export([hashdiff/1,upgrade/1]).

-include("apps/tpnode/include/tx_const.hrl").

mergesig(#{sig:=S1}=Tx1, #{sig:=S2}) when is_map(S1), is_map(S2)->
  Tx1#{sig=>
       maps:merge(S1, S2)
      };

mergesig(#{sig:=S1}=Tx1, #{sig:=S2}) when is_list(S1), is_list(S2)->
  F=lists:foldl(
      fun(P,A) ->
          S=bsig:extract_pubkey(bsig:unpacksig(P)),
          maps:put(S,P,A)
      end,
      #{},
      S1++S2),
  Tx1#{sig=> maps:values(F)};

mergesig(Tx1, Tx2) ->
  file:write_file("tmp/merge1.txt", io_lib:format("~p.~n~p.~n", [Tx1,Tx2])),
  Tx1.

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

del_ext(K, Tx) ->
  Ed=maps:get(extdata, Tx, #{}),
  Tx#{
    extdata=>maps:remove(K, Ed)
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
  ver:=2,
  kind:=patch,
  patches:=Patches
 }=Tx0,_Params) ->
  Tx=maps:with([ver,txext,patches],Tx0),
  E0=#{
    "k"=>encode_kind(2,patch),
    "e"=>maps:get(txext, Tx, #{}),
    "p"=>Patches
   },
  Tx#{
    patches=>settings:dmp(settings:mp(Patches)),
    kind=>patch,
    body=>pack_body(E0),
    sig=>[]
   };


construct_tx(#{
  ver:=2,
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
                    sig=>[]
                   });
    _ ->
      maps:remove(keys,
                  Tx0#{
                    kind=>register,
                    body=>pack_body(PowBody),
                    keysh=>KeysH,
                    sig=>[]
                   })
  end;

construct_tx(#{
  ver:=2,
  kind:=tstore,
  from:=F,
  t:=Timestamp,
  seq:=Seq,
  payload:=Amounts
 }=Tx0,_Params) ->
  Tx=maps:with([ver,from,t,seq,payload,txext],Tx0),
  A1=lists:map(
       fun(#{amount:=Amount, cur:=Cur, purpose:=Purpose}) when
             is_integer(Amount), is_binary(Cur) ->
           [encode_purpose(Purpose), to_list(Cur), Amount]
       end, Amounts),
  Ext=maps:get(txext, Tx, #{}),
  true=is_map(Ext),
  E0=#{
    "k"=>encode_kind(2,tstore),
    "f"=>F,
    "t"=>Timestamp,
    "s"=>Seq,
    "p"=>A1,
    "e"=>Ext
   },
  Tx#{
    kind=>tstore,
    body=>msgpack:pack(E0,[{spec,new},{pack_str, from_list}]),
    sig=>[]
   };

construct_tx(#{
  ver:=2,
  kind:=deploy,
  from:=F,
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
    "k"=>encode_kind(2,deploy),
    "f"=>F,
    "t"=>Timestamp,
    "s"=>Seq,
    "p"=>A1,
    "e"=>Ext
   },
  {E1,Tx1}=case maps:find(call,Tx) of
             {ok, #{function:=Fun,args:=Args}} when is_list(Fun),
                                                    is_list(Args) ->
               {E0#{"c"=>[Fun,{array,Args}]},Tx};
             error ->
               {E0#{"c"=>["init",{array,[]}]}, maps:remove(call, Tx)}
           end,
  Tx1#{
    kind=>deploy,
    body=>msgpack:pack(E1,[{spec,new},{pack_str, from_list}]),
    sig=>[]
   };

construct_tx(#{
  ver:=2,
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
             {ok, #{function:=Fun,args:=Args}} when is_list(Fun),
                                                    is_list(Args) ->
               {E0#{"c"=>[Fun,{array,Args}]},Tx};
             _ ->
               {E0, maps:remove(call, Tx)}
           end,
  Tx1#{
    kind=>generic,
    body=>msgpack:pack(E1,[{spec,new},{pack_str, from_list}]),
    sig=>[]
   }.

unpack_body(#{sig:=<<>>}=Tx) ->
  unpack_body(Tx#{sig:=[]});

unpack_body(#{body:=Body}=Tx) ->
  case msgpack:unpack(Body,[{spec,new},{unpack_str, as_list}]) of
    {ok,#{"k":=IKind}=B} ->
      {Ver, Kind}=decode_kind(IKind),
      unpack_body(Tx#{ver=>Ver, kind=>Kind},B);
    {ok, #{<<"hash">>:=_,
           <<"header">>:=_,
           <<"sign">>:=_}} ->
      block:unpack(Body);
    {error,{invalid_string,_}} ->
      case msgpack:unpack(Body,[{spec,new},{unpack_str, as_binary}]) of
        {ok,#{<<"k">>:=IKind}=B0} ->
          {Ver, Kind}=decode_kind(IKind),
          B=maps:fold(
              fun(K,V,Acc) ->
                  maps:put(unicode:characters_to_list(K),V,Acc)
              end, #{}, B0),
          unpack_body(Tx#{ver=>Ver, kind=>Kind},B)
      end
  end.

unpack_addr(<<_:64/big>>=From,_) -> From;
unpack_addr([_,_,_,_,_,_,_,_]=From,_) -> list_to_binary(From);
unpack_addr(_,T) -> throw(T).

unpack_timestamp(Time) when is_integer(Time) -> Time;
unpack_timestamp(_Time) -> throw(bad_timestamp).

unpack_seq(Int) when is_integer(Int) -> Int;
unpack_seq(_Int) -> throw(bad_seq).

%TODO: remove this temporary fix
unpack_txext(<<>>) -> #{};
unpack_txext(Map) when is_map(Map) -> Map;
unpack_txext(_Any) -> throw(bad_ext).

unpack_payload(Amounts) when is_list(Amounts) ->
  lists:map(
    fun([Purpose, Cur, Amount]) ->
        if is_integer(Amount) -> ok;
           true -> throw('bad_amount')
        end,
        #{amount=>Amount,
          cur=>to_binary(Cur),
          purpose=>decode_purpose(Purpose)
         }
    end, Amounts).

unpack_body(#{ ver:=2,
              kind:=GenericOrDeploy
             }=Tx,
            #{ "f":=From,
               "to":=To,
               "t":=Timestamp,
               "s":=Seq,
               "p":=Payload
             }=Unpacked) when GenericOrDeploy == generic ; 
                              GenericOrDeploy == deploy ->
  Amounts=unpack_payload(Payload),
  Decoded=Tx#{
    ver=>2,
    from=>unpack_addr(From,bad_from),
    to=>unpack_addr(To,bad_to),
    t=>unpack_timestamp(Timestamp),
    seq=>unpack_seq(Seq),
    payload=>Amounts,
    txext=>unpack_txext(maps:get("e", Unpacked, #{}))
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
              kind:=deploy
             }=Tx,
            #{ "f":=From,
               "t":=Timestamp,
               "s":=Seq,
               "p":=Payload
             }=Unpacked) ->
  Amounts=unpack_payload(Payload),
  Decoded=Tx#{
    ver=>2,
    from=>unpack_addr(From,bad_from),
    t=>unpack_timestamp(Timestamp),
    seq=>unpack_seq(Seq),
    payload=>Amounts,
    txext=>unpack_txext(maps:get("e", Unpacked, #{}))
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
              kind:=tstore
             }=Tx,
            #{ "f":=From,
               "t":=Timestamp,
               "s":=Seq,
               "p":=Payload
             }=Unpacked) ->
  Amounts=unpack_payload(Payload),
  Tx#{
    ver=>2,
    from=>unpack_addr(From,bad_from),
    t=>unpack_timestamp(Timestamp),
    seq=>unpack_seq(Seq),
    payload=>Amounts,
    txext=>unpack_txext(maps:get("e", Unpacked, #{}))
   };

unpack_body(#{ ver:=2,
              kind:=register
             }=Tx,
            #{ "t":=Timestamp,
               "h":=Hash
             }=Unpacked) ->
  Tx#{
    ver=>2,
    t=>unpack_timestamp(Timestamp),
    keysh=>Hash,
    txext=>unpack_txext(maps:get("e", Unpacked, #{}))
   };

unpack_body(#{ ver:=2,
              kind:=patch
             }=Tx,
            #{ "p":=Patches
             }=Unpacked) ->
  Tx#{
    ver=>2,
    patches=>Patches,
    txext=>unpack_txext(maps:get("e", Unpacked, #{}))
   };

unpack_body(#{ver:=Ver, kind:=Kind},_Unpacked) ->
  throw({unknown_ver_or_kind,{Ver,Kind},_Unpacked}).

sign(#{kind:=_Kind,
       body:=Body,
       sig:=PS}=Tx, PrivKey) ->
  Sig=bsig:signhash(Body,[],PrivKey),
  Tx#{sig=>[Sig|PS]};

sign(Any, PrivKey) ->
  tx1:sign(Any, PrivKey).


-type tx() :: tx2() | tx1().
-type tx2() :: #{
        ver:=non_neg_integer(),
        kind:=atom(),
        body:=binary(),
        sig:=list(),
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
  kind:=GenericOrDeploy,
  from:=From,
  body:=Body,
  sig:=LSigs,
  ver:=2
 }=Tx, Opts) when GenericOrDeploy==generic;
                  GenericOrDeploy==deploy;
                  GenericOrDeploy==tstore;
                  GenericOrDeploy==lstore ->
  CI=get_ext(<<"contract_issued">>, Tx),
  Res=case checkaddr(From) of
        {true, _IAddr} when CI=={ok, From} ->
          %contract issued. Check nodes key.
          try
            bsig:checksig(Body, LSigs, 
                          fun(PubKey,_) ->
                              chainsettings:is_our_node(PubKey) =/= false
                          end)
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
                         fun(PubKey, _) ->
                             PK==PubKey
                         end;
                       _ ->
                         throw({ledger_err, From})
                     end;
                   true ->
                     undefined
                 end,
          bsig:checksig(Body, LSigs, VerFun);
        _ ->
          throw({invalid_address, from})
      end,

  case Res of
    {[], _} ->
      bad_sig;
    {Valid, Invalid} when length(Valid)>0 ->
      {ok, Tx#{
             sigverify=>#{
               valid=>length(Valid),
               invalid=>Invalid,
               pubkeys=>bsig:extract_pubkeys(Valid)
              }
            }
      }
  end;

verify(#{
  kind:=register,
  body:=Body,
  sig:=LSigs,
  ver:=2
 }=Tx, _Opts) ->
  Res=bsig:checksig(Body, LSigs),
  case Res of
    {[], _} ->
      bad_sig;
    {Valid, Invalid} when length(Valid)>0 ->
      BodyHash=hashdiff(crypto:hash(sha512,Body)),
      ValidPK=bsig:extract_pubkeys(Valid),
      Pubs=crypto:hash(sha256,iolist_to_binary(lists:sort(ValidPK))),
      #{keysh:=H}=unpack_body(Tx),
      if Pubs==H ->
           {ok, Tx#{
                  sigverify=>#{
                    pow_diff=>BodyHash,
                    valid=>length(Valid),
                    invalid=>Invalid,
                    pubkeys=>ValidPK
                   }
                 }
           };
         true ->
           bad_keys
      end
  end;

verify(#{
  kind:=patch,
  body:=Body,
  sig:=LSigs,
  ver:=2
 }=Tx, Opts) ->
  CheckFun=case lists:keyfind(settings,1,Opts) of
             {_,Sets} ->
               fun(PubKey,_) ->
                   chainsettings:is_our_node(PubKey, Sets) =/= false
               end;
             false ->
               fun(PubKey,_) ->
                   chainsettings:is_our_node(PubKey) =/= false
               end
           end,
  Res=bsig:checksig(Body, LSigs, CheckFun),
  case Res of
    {[], _} ->
      bad_sig;
    {Valid, Invalid} when length(Valid)>0 ->
      {ok, Tx#{
             sigverify=>#{
               valid=>length(Valid),
               invalid=>Invalid,
               pubkeys=>bsig:extract_pubkeys(Valid)
              }
            }
      }
  end;

verify(Bin, Opts) when is_binary(Bin) ->
  MaxTxSize = proplists:get_value(maxsize, Opts, 0),
  case size(Bin) of
    _Size when MaxTxSize > 0 andalso _Size > MaxTxSize ->
      tx_too_big;
    _ ->
      Tx = unpack(Bin),
      verify(Tx, Opts)
  end;


verify(Struct, Opts) ->
  tx1:verify(Struct, Opts).

-spec pack(tx()) -> binary().

pack(Tx) ->
  pack(Tx, []).

pack(#{
  hash:=_,
  header:=_,
  sign:=_
 }=Block, _Opts) ->
  msgpack:pack(
    #{
    "ver"=>2,
    "sig"=>[],
    "body" => block:pack(Block)
   },
    [
     {spec,new},
     {pack_str, from_list}
    ]
   );

pack(#{ ver:=2,
        body:=Bin,
        sig:=PS}=Tx, Opts) ->
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
  T2=case lists:member(withext, Opts) andalso maps:is_key(extdata, Tx) of
       false -> T1;
       true ->
         T1#{
           "extdata" => maps:get(extdata,Tx)
          }
     end,
  msgpack:pack(T2,[
                  {spec,new},
                  {pack_str, from_list}
                 ]);

pack(Any, _) ->
  tx1:pack(Any).

unpack(Tx) when is_map(Tx) ->
  Tx;

unpack(BinTx) when is_binary(BinTx) ->
  unpack(BinTx,[]).

unpack(BinTx,Opts) when is_binary(BinTx), is_list(Opts) ->
  {ok, Tx0} = msgpack:unpack(BinTx, [{known_atoms,
                                      [type, sig, tx, patch, register,
                                       register, address, block ] },
                                     {unpack_str, as_binary}] ),
  Trusted=lists:member(trusted, Opts),
  case Tx0 of
    #{<<"ver">>:=2, sig:=Sign, <<"body">>:=TxBody, <<"inv">>:=Inv} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody,
        inv=>Inv
       });
    #{<<"ver">>:=2, sig:=Sign, <<"body">>:=TxBody} ->
      unpack_generic(Trusted, Tx0, TxBody, Sign);
    #{<<"ver">>:=2, <<"sig">>:=Sign, <<"body">>:=TxBody, <<"inv">>:=Inv} ->
      unpack_body( #{
        ver=>2,
        sig=>Sign,
        body=>TxBody,
        inv=>Inv
       });
    #{<<"ver">>:=2, <<"sig">>:=Sign, <<"body">>:=TxBody} ->
      unpack_generic(Trusted, Tx0, TxBody, Sign);
    _ ->
      tx1:unpack_mp(Tx0)
  end.

unpack_generic(Trusted, Tx0, TxBody, Sign) ->
  Ext=if Trusted ->
           case maps:find(<<"extdata">>,Tx0) of
             {ok, Val} ->
               Val;
             _ -> false
           end;
         true -> false
      end,
  unpack_body(
    if Ext == false ->
         #{ ver=>2,
            sig=>Sign,
            body=>TxBody
          };
       true ->
         #{ extdata => Ext,
            ver=>2,
            sig=>Sign,
            body=>TxBody
          }
    end).

txlist_hash(List) ->
  crypto:hash(sha256,
              iolist_to_binary(lists:foldl(
                                 fun({Id, Bin}, Acc) when is_binary(Bin) ->
                                     [Id, Bin|Acc];
                                    ({Id, #{}=Tx}, Acc) ->
                                     [Id, tx:pack(Tx)|Acc]
                                 end, [], lists:keysort(1, List)))).

get_payload(#{ver:=2, kind:=Kind, payload:=Payload}=_Tx, Purpose)
  when Kind==deploy; Kind==generic; Kind==tstore; Kind==lstore ->
  lists:foldl(
    fun(#{amount:=_,cur:=_,purpose:=P1}=A, undefined) when P1==Purpose ->
        A;
       (_,A) ->
        A
    end, undefined, Payload);

get_payload(#{ver:=2, kind:=Kind},_) ->
  throw({unknown_kind_for_get_payload,Kind}).

get_payloads(#{ver:=2, kind:=Kind, payload:=Payload}=_Tx, Purpose) 
  when Kind==deploy; Kind==generic; Kind==tstore; Kind==lstore ->
  lists:filter(
    fun(#{amount:=_,cur:=_,purpose:=P1}) ->
        P1==Purpose
    end, Payload);

get_payloads(#{ver:=2, kind:=Kind},_) ->
  throw({unknown_kind_for_get_payloads,Kind}).

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

%rate(#{ver:=2, kind:=deploy}=Tx, GetRateFun) ->
%  try
%    case get_payload(Tx, srcfee) of
%      #{cur:=Cur, amount:=TxAmount} ->
%        rate2(Tx, Cur, TxAmount, GetRateFun);
%      _ ->
%        case GetRateFun({params, <<"feeaddr">>}) of
%          X when is_binary(X) ->
%            {false, #{ cost=>null } };
%          _ ->
%            {true, #{ cost=>0, tip => 0, cur=><<"none">> }}
%        end
%    end
%  catch Ec:Ee -> 
%          file:write_file("tmp/rate.txt", [io_lib:format("~p.~n~p.~n", 
%                                                         [
%                                                          Tx,
%                                                          erlang:term_to_binary(GetRateFun)
%                                                         ])]),
%          S=erlang:get_stacktrace(),
%          lager:error("Calc fee error ~p tx ~p",[{Ec,Ee},Tx]),
%          lists:foreach(fun(SE) ->
%                            lager:error("@ ~p", [SE])
%                        end, S),
%          throw('cant_calculate_fee')
%  end;

rate(#{ver:=2, kind:=_}=Tx, GetRateFun) ->
  try
    case get_payload(Tx, srcfee) of
      #{cur:=Cur, amount:=TxAmount} ->
        rate2(Tx, Cur, TxAmount, GetRateFun);
      _ ->
        case GetRateFun({params, <<"feeaddr">>}) of
          X when is_binary(X) ->
            rate2(Tx, <<"none">>, 0, GetRateFun);
            %{false, #{ cost=>null } };
          _ ->
            {true, #{ cost=>0, tip => 0, cur=><<"none">> }}
        end
    end
  catch Ec:Ee -> 
          S=erlang:get_stacktrace(),
          file:write_file("tmp/rate.txt", [io_lib:format("~p.~n~p.~n~n~p.~n~n~p.~n~n~p.~n", 
                                                         [
                                                          Ec,
                                                          Ee,
                                                          S,
                                                          Tx,
                                                          element(2,erlang:fun_info(GetRateFun,env))
                                                         ])]),
          lager:error("Calc fee error ~p tx ~p",[{Ec,Ee},Tx]),
          lists:foreach(fun(SE) ->
                            lager:error("@ ~p", [SE])
                        end, S),
          throw('cant_calculate_fee')
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
            rate1(Tx, <<"none">>, 0, GetRateFun);
%            {false, #{ cost=>null } };
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

