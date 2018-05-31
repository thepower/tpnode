-module(settings).

-export([new/0, set/3, patch/2, mp/1, dmp/1, get/2]).
-export([sign/2, verify/1, verify/2, get_patches/1, get_patches/2]).

-ifndef(TEST).
-define(TEST, 1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%pack(#{patch:=_LPatch, sig:=Sigs}=Patch) when is_list(Sigs) ->
%    msgpack:pack(Patch).
%
%unpack(Bin) ->
%    msgpack:unpack(Bin).



sign(Patch, PrivKey) when is_list(Patch) ->
    BinPatch=mp(Patch),
    sign(#{patch=>BinPatch, sig=>[]}, PrivKey);
sign(Patch, PrivKey) when is_binary(Patch) ->
    sign(#{patch=>Patch, sig=>[]}, PrivKey);

sign(#{patch:=LPatch}=Patch, PrivKey) ->
    BPatch=if is_list(LPatch) -> mp(LPatch);
                is_binary(LPatch) -> LPatch
             end,
    Sig=bsig:signhash(
          crypto:hash(sha256, BPatch),
          [{timestamp, os:system_time(millisecond)}],
          PrivKey),
    #{ patch=>BPatch,
        sig => [Sig|maps:get(sig, Patch, [])]
     }.

verify(#{patch:=LPatch, sig:=HSig}=Patch, VerFun) ->
  BinPatch=if is_list(LPatch) -> mp(LPatch);
              is_binary(LPatch) -> LPatch
           end,
  {Valid, Invalid}=bsig:checksig(crypto:hash(sha256, BinPatch), HSig),
  case length(Valid) of
    0 ->
      bad_sig;
    N when N>0 ->
      Map=lists:foldl(%make signatures unique
            fun(#{extra:=ED}=P,Acc) ->
                case proplists:get_value(pubkey,ED) of
                  PK when is_binary(PK) ->
                    maps:put(PK,P,Acc);
                  _ ->
                    Acc
                end
            end, #{}, Valid),
      ValidSig=if VerFun==undefined -> 
                    maps:values(Map);
                 is_function(VerFun) ->
                    maps:fold(
                      fun(K,V,Acc) ->
                          case VerFun(K) of
                            true ->
                              [V|Acc];
                            false ->
                              Acc
                          end
                      end, [], Map)
               end,
      {ok, Patch#{
             sigverify=>#{
               valid=>ValidSig,
               invalid=>Invalid
              }
            }
      }
  end.

verify(#{patch:=_, sig:=_}=Patch) ->
  verify(Patch, undefined).

new() ->
    #{}.

set(A, B, C) ->
    change(set, A, B, C).

get([], M) -> M;
get([Hd|Path], M) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    get(Path, H1).

change(Action, [Element|Path], Value, M, FPath) when
      Element==<<"chain">> orelse
      Element==<<"chains">> orelse
      Element==<<"nodechain">> orelse
      Element==<<"keys">> orelse
      Element==<<"globals">> orelse
      Element==<<"patchsig">> orelse
      Element==<<"blocktime">> orelse
      Element==<<"minsig">> orelse
      Element==<<"enable">> orelse
      Element==<<"params">> orelse
      Element==<<"disable">> orelse
      Element==<<"nodes">> ->
    change(Action, [binary_to_atom(Element, utf8)|Path], Value, M, FPath);

change(add, [], Value, M, FPath) ->
    M1=if M==#{} -> [];
          is_list(M) -> M;
          true -> throw({'non_list', FPath})
       end,
    lists:usort([Value|M1]);

change(remove, [], Value, M, FPath) ->
    M1=if M==#{} -> [];
          is_list(M) -> M;
          true -> throw({'non_list', FPath})
       end,
    lists:usort(M1--[Value]);

change({member, T}, [], Value, M, FPath) ->
    M1=if is_list(M) -> M;
          true -> throw({'non_list', FPath})
       end,
    case lists:member(Value, M1) of
        T ->
            M;
        _ ->
            throw({'member', FPath})
    end;

change({exist, T}, [Path], _Value, M, FPath) ->
    if is_map(M) ->
           Exist=maps:is_key(Path, M),
           if Exist == T ->
                  M;
              true ->
                  throw({exist, FPath})
           end;
       true ->
           throw({'non_map', FPath})
    end;


change(compare, [Path], Value, M, FPath) ->
    if is_map(M) ->
           Val=maps:get(Path, M, undefined),
           if Val==Value ->
                  M;
              true ->
                  throw({compare, FPath})
           end;
       true ->
           throw({'non_map', FPath})
    end;

change(delete, [Path], null, M, FPath) -> %force delete
    if is_map(M) ->
           maps:remove(Path, M);
       true ->
           throw({'non_map', FPath})
    end;

change(delete, [Path], Value, M, FPath) -> %compare and delete
    if is_map(M) ->
           Val=maps:get(Path, M, undefined),
           if Val==Value ->
                  maps:remove(Path, M);
              true ->
                  throw({delete_val, FPath, Value})
           end;
       true ->
           throw({'non_map', FPath})
    end;


change(set, [Path], Value, M, FPath) -> %set or replace
    if is_map(M) ->
           PrevValue=maps:get(Path, M, undefined),
           if is_list(PrevValue) orelse is_map(PrevValue) ->
                  throw({'non_value', FPath});
              true ->
                  maps:put(Path, Value, M)
           end;
       true ->
           throw({'non_map', FPath})
    end;

change(Action, [Hd|Path], Value, M, FPath) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    maps:put(Hd, change(Action, Path, Value, H1, FPath), M).

change(Action, Path, Value, M) when is_list(Path) ->
    change(Action, Path, Value, M, Path).

patch1([], M) -> M;

patch1([#{<<"t">>:=Action, <<"p">>:=K, <<"v">>:=V}|Settings], M) ->
    lager:debug("Settings ~s K ~p v ~p", [Action, K, V]),
    M1=change(action(Action), K, V, M),
    patch1(Settings, M1).

%patch({_TxID, MP}, M) when is_binary(MP)->
%    {Patch, Sigs}=unpack(MP),
%    patch(#{patch=>Patch,
%            sig=>Sigs}, M);

patch({_TxID, #{patch:=Patch,
               sig:=Sigs}}, M) ->
    patch(#{patch=>Patch,
            sig=>Sigs}, M);

patch(#{patch:=Patch}, M) ->
    patch(Patch, M);

patch(Changes, M) when is_list(Changes) ->
  patch1(Changes, M);

patch(MP, M) when is_binary(MP) ->
    DMP=dmp(MP),
    patch1(DMP, M).

dmp(Term) when is_binary(Term) ->
    {ok, T}=msgpack:unpack(Term, [
                                %Not supported in msgpack or broken
                                %{known_atoms, [ chain ]}
                               ]),
    T;

dmp(Term) when is_list(Term) -> Term.

mp(Term) ->
    msgpack:pack(Term, [{map_format, jiffy}, {spec, new}]).
%mpk(Key) ->
%    E1=binary:split(Key, <<":">>, [global]),
%    mp(E1).


action(<<"list_add">>) -> add;
action(<<"list_del">>) -> remove;
action(<<"set">>) -> set;
action(<<"delete">>) -> delete;
action(<<"compare">>) -> compare;
action(<<"exist">>) -> {exist, true};
action(<<"nonexist">>) -> {exist, false};
action(<<"member">>) -> {member, true};
action(<<"nonmember">>) -> {member, false};
action(Action) -> throw({action, Action}).

get_patches(Settings) ->
  get_patches(Settings, export).

get_patches(Settings, Mode = export) when is_map(Settings) ->
    dmp(mp(lists:reverse(parse_settings(maps:keys(Settings), Settings, [], [], Mode))));

get_patches(Settings, Mode = ets) when is_map(Settings) ->
    lists:reverse(parse_settings(maps:keys(Settings), Settings, [], [], Mode)).

parse_settings([], _, _, Patches, _Mode) -> Patches;
parse_settings([H|T], Settings, Path, Patches, Mode) ->
  NewPath = [H|Path],
  Item = maps:get(H, Settings),
  NewPatches = if is_map(Item) ->
       parse_settings(maps:keys(Item), Item, NewPath, Patches, Mode);
     is_list(Item) ->
       (lists:foldl(fun(Elem, Acc) ->
                                   [#{<<"t">> => <<"list_add">>, 
                                      <<"p">> => lists:reverse(NewPath), 
                                      <<"v">> => Elem}|Acc]
                                 end, Patches, Item));
     not is_map(Item) and not is_list(Item) ->
       [#{<<"t">> => <<"set">>, 
          <<"p">> => lists:reverse(NewPath), 
          <<"v">> => Item}|Patches]
  end,
  parse_settings(T, Settings, Path, NewPatches, Mode).


-ifdef(TEST).
exists_test() ->
    TestPatch=settings:dmp(
                settings:mp(
                  [
                   #{t=><<"nonexist">>, p=>[current, allocblock, last], v=>any},
                   #{t=>set, p=>[current, allocblock, group], v=>10},
                   #{t=>set, p=>[current, allocblock, block], v=>2},
                   #{t=>set, p=>[current, allocblock, last], v=>3}
                  ])),
    ExTest=settings:patch(TestPatch, #{}),
    [
     ?assertException(throw,
                       {exist, [<<"current">>, <<"allocblock">>, <<"last">>]},
                       settings:patch(TestPatch, ExTest))
    ].

patch_sign_test() ->
    TestPriv1= <<8, 3, 173, 195, 34, 179, 247, 43, 170, 25, 72, 141, 197, 33, 16, 27, 243, 255,
                62, 9, 86, 147, 15, 193, 9, 244, 229, 208, 76, 222, 83, 208>>,
    TestPriv2= <<183, 31, 13, 74, 198, 72, 211, 62, 196, 207, 92, 98, 28, 31, 136, 0, 127, 128,
                 189, 172, 129, 122, 6, 39, 221, 242, 157, 21, 164, 81, 236, 181>>,
    Patch1=#{patch =>
             [#{p => [chain, 0, blocktime], t => set, v => 1},
              #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
            },
    Patch2=#{patch =>
             [#{p => [chain, 0, blocktime], t => set, v => 2},
              #{p => [chain, 0, <<"allowempty">>], t => set, v => 0}]
            },
    TwoSig= settings:sign(
              settings:sign(Patch1, TestPriv1),
              TestPriv2),
    RePack=tx:unpack(tx:pack(TwoSig)),
    BadSig=maps:merge(TwoSig, Patch2),
    ReSig=settings:sign(
            BadSig,
            TestPriv2),
    TstGenesis=dmp(mp([
       #{t=>set, p=>[globals, patchsigs], v=>2},
       #{t=>set, p=>[chains], v=>[0]},
       #{t=>set, p=>[chain, 0, minsig], v=>2},
       #{t=>set, p=>[chain, 0, blocktime], v=>5},
       #{t=>set, p=>[keys, node1], v=>
				 hex:parse("035AE7DF4FCB5B97A86FCEBB107D440858DDFB28C708E70E06C625AA210E8A6F16") },
       #{t=>set, p=>[keys, node2], v=>
				 hex:parse("020783EF674851FCE9BED45B494D838C6B5F394F175B37DD26A511F29E1F21394B") },
       #{t=>set, p=>[keys, node3], v=>
				 hex:parse("0260CC110AF0A34E7CD51C287320612F017B52AABBEA8EBFA619CF94FDE823C36C") }
       #{t=>set, p=>[nodechain], v=>#{node1=>0, node2=>0, node3=>0 } }
      ])),

    Genesis=patch(TstGenesis, #{}),
    Patched=patch(verify(RePack), Genesis),


    [

     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=0,
                       valid:=[_, _]
                      }}
                  }, verify(TwoSig)), %simple check
     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=0,
                       valid:=[_, _]
                      }}
                  }, verify(RePack)), %check after packing and unpacking
     ?assertEqual(bad_sig, verify(BadSig)), %broken patch
     ?assertMatch({ok, #{
                     sigverify:=#{
                       invalid:=2,
                       valid:=[_]
                      }}
                  }, verify(ReSig)), %resig broken patch
     ?assertMatch([_|_], TstGenesis),
     ?assertMatch(#{}, Genesis),
     ?assertMatch(5, get([chain, 0, blocktime], Genesis)),
     ?assertMatch(1, get([chain, 0, blocktime], Patched)),
     ?assertMatch(#{}, get([chain, 0, <<"allowempty">>], Genesis)),
     ?assertMatch(0, get([chain, 0, <<"allowempty">>], Patched))
    ].

-endif.


