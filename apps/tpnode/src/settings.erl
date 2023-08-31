-module(settings).
-include("include/tplog.hrl").

-export([new/0, set/3, patch/2, mp/1, dmp/1, get/2, get/3]).
-export([get_patches/1, get_patches/2]).
-export([verify/1]).
-export([upgrade/1]).
-export([make_meta/2, clean_meta/1]).

%sign(Patch, PrivKey) when is_list(Patch) ->
%    BinPatch=mp(Patch),
%    sign(#{patch=>BinPatch, sig=>[]}, PrivKey);
%sign(Patch, PrivKey) when is_binary(Patch) ->
%    sign(#{patch=>Patch, sig=>[]}, PrivKey);
%
%sign(#{patch:=LPatch}=Patch, PrivKey) ->
%    BPatch=if is_list(LPatch) -> mp(LPatch);
%                is_binary(LPatch) -> LPatch
%             end,
%    Sig=bsig:signhash(
%          crypto:hash(sha256, BPatch),
%          [{timestamp, os:system_time(millisecond)}],
%          PrivKey),
%    #{ patch=>BPatch,
%        sig => [Sig|maps:get(sig, Patch, [])]
%     }.
%
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

clean_meta(Set) when is_map(Set) ->
  S1=maps:remove(<<".">>,Set),
  maps:map(
    fun(_,V) when is_map(V)->
        clean_meta(V);
       (_,V) ->
        V
    end, S1).

meta_path(set, Path) ->
  {Pre,Post}=lists:split(length(Path)-1,Path),
  Pre++[<<".">>]++Post;

meta_path(list, Path) ->
  {Pre,Post}=lists:split(length(Path)-1,Path),
  Pre++[<<".">>]++Post.

make_meta1(Patch, MetaInfo, Acc) when is_binary(Patch) ->
  make_meta1(dmp(Patch), MetaInfo, Acc);

make_meta1([], _, Acc) ->
  Acc;

make_meta1([#{"t":=T,"p":=P,"v":=V}|Rest], MetaInfo, Acc) ->
  make_meta1([#{<<"t">>=>T,<<"p">>=>P,<<"v">>=>V}|Rest], MetaInfo, Acc);


make_meta1([#{<<"t">>:=<<"list_",_/binary>>,<<"p">>:=Path,<<"v">>:=_}|Rest], MetaInfo, Acc) ->
  Acc2=maps:fold(
         fun(K,V,Acc1) ->
             BasePath=meta_path(list,Path),
             maps:put(BasePath++[K],V,Acc1)
         end, Acc, MetaInfo),
  make_meta1(Rest, MetaInfo, Acc2);

make_meta1([#{<<"t">>:=<<"set">>,<<"p">>:=Path,<<"v">>:=_}|Rest], MetaInfo, Acc) ->
  Acc2=maps:fold(
         fun(K,V,Acc1) ->
             BasePath=meta_path(set,Path),
             maps:put(BasePath++[K],V,Acc1)
         end, Acc, MetaInfo),
  make_meta1(Rest, MetaInfo, Acc2);

make_meta1([#{<<"t">>:=_,<<"p">>:=_,<<"v">>:=_}|Rest], MetaInfo, Acc) ->
  make_meta1(Rest, MetaInfo, Acc).

fixtype(X) when is_integer(X) -> X;
fixtype(X) when is_binary(X) -> X;
fixtype(X) when is_atom(X) -> atom_to_binary(X,utf8);
fixtype(X) ->
  throw({'bad_type',X}).

make_meta(Patches, MetaInfo) ->
    MI=maps:fold(
       fun(K,V,Acc) ->
           maps:put(fixtype(K),fixtype(V),Acc)
       end, #{}, MetaInfo),
  Map=make_meta1(Patches, MI, #{}),
  maps:fold(
    fun(Key,Val, Acc) ->
        [#{<<"t">>=><<"set">>, <<"p">>=>Key, <<"v">>=>Val}|Acc]
    end, [], Map).

get([], M, _D) -> M;
get([Hd], M, D) when is_atom(Hd) ->
  case maps:is_key(Hd, M) of
    true ->
      maps:get(Hd, M, D);
    false ->
      maps:get(atom_to_binary(Hd,utf8), M, D)
  end;
get([Hd], M, D) ->
    maps:get(Hd, M, D);
get([Hd|Path], M, D) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    get(Path, H1, D).


get([], M) -> M;
get([Hd|Path], M) when is_list(Path) ->
    H1=maps:get(Hd, M, #{}),
    get(Path, H1).

%change(Action, [Element|Path], Value, M, FPath) when
%      Element==<<"chain">> orelse
%      Element==<<"chains">> orelse
%      Element==<<"nodechain">> orelse
%      Element==<<"keys">> orelse
%      Element==<<"globals">> orelse
%      Element==<<"patchsig">> orelse
%      Element==<<"blocktime">> orelse
%      Element==<<"minsig">> orelse
%      Element==<<"enable">> orelse
%      Element==<<"params">> orelse
%      Element==<<"disable">> orelse
%      Element==<<"nodes">> ->
%    change(Action, [binary_to_atom(Element, utf8)|Path], Value, M, FPath);

change(lcleanup, [], <<"empty_list">>, Map, FPath) ->
  if(is_map(Map)) ->
      ToDel=maps:fold(
              fun(K,[],A) ->
                  [K|A];
                (_,_,A) ->
                  A
              end, [], Map),
      M1=maps:without(ToDel,Map),
      case maps:is_key(<<".">>,Map) of
        true ->
          M1#{<<".">>=>maps:without(ToDel,maps:get(<<".">>,Map))};
        false ->
          M1
      end;
    true ->
      throw({'non_map_of_lists',FPath})
      end;

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

change(delete, [Path], [], M, _FPath) -> %delete if list empty
  case M of
    #{Path:=[]} ->
      maps:remove(Path, M);
    _ ->
      M
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


change(set, [Path], Value, M, FPath) when is_atom(Path) -> %set or replace
    if not is_map(M) ->
         throw({'non_map', FPath});
       true ->
         ok
    end,
    BPath=atom_to_binary(Path, utf8),
    {OType, PrevValue}=case maps:is_key(Path, M) of
                          true ->
                            {atom, maps:get(Path, M)};
                          false ->
                            case maps:is_key(BPath, M) of
                              true -> {binary, maps:get(BPath, M)};
                              false -> {none, undefined}
                            end
                        end,
    if is_list(PrevValue) orelse is_map(PrevValue) ->
         io:format("change(set,[~p],~p,~p,~p)~n",[Path,Value,M,FPath]),
         throw({'non_value', FPath});
       true andalso OType==atom ->
         maps:put(BPath, Value,
                  maps:remove(Path, M)
                 );
       true ->
         maps:put(BPath, Value, M)
    end;

change(set, [Path], Value, M, FPath) -> %set or replace
    if is_map(M) ->
           PrevValue=maps:get(Path, M, undefined),
           if is_list(PrevValue) orelse is_map(PrevValue) ->
                io:format("change(set,[~p],~p,~p,~p)~n",[Path,Value,M,FPath]),
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

patch1([#{"t":=Action, "p":=K, "v":=V}|Settings], M) ->
    M1=change(action(Action), K, V, M),
    patch1(Settings, M1);

patch1([#{<<"t">>:=Action, <<"p">>:=K, <<"v">>:=V}|Settings], M) ->
    M1=change(action(Action), K, V, M),
    patch1(Settings, M1).

%txv2
patch(#{patches:=Patch, sig:=_Sigs}, M) ->
    patch1(Patch, M);

%txv2
patch({_TxID, #{patches:=Patch, sig:=_Sigs}}, M) ->
    patch1(Patch, M);

%tvx1
patch({_TxID, #{patch:=Patch, sig:=Sigs}}=E, M) ->
  ?LOG_NOTICE("deprecated v1 patch ~p", [E]),
  patch(#{patch=>Patch, sig=>Sigs}, M);

%txv1
patch(#{patch:=Patch}=E, M) ->
  ?LOG_NOTICE("deprecated v1 patch ~p", [E]),
  patch(Patch, M);

%naked
patch(Changes, M) when is_list(Changes) ->
  patch1(Changes, M);

%packed
patch(MP, M) when is_binary(MP) ->
    DMP=dmp(MP),
    patch1(DMP, M).

upgrade(true) -> true;
upgrade(false) -> false;
upgrade(Term) when is_binary(Term) ->
  Term;
upgrade(Term) when is_list(Term) ->
  Term;
upgrade(Term) when is_integer(Term) ->
  Term;

upgrade(Term) when is_map(Term) ->
  maps:fold(
    fun(Element,V,Acc) when
      Element==chain orelse
      Element==chains orelse
      Element==nodechain orelse
      Element==keys orelse
      Element==globals orelse
      Element==patchsig orelse
      Element==blocktime orelse
      Element==minsig orelse
      Element==enable orelse
      Element==params orelse
      Element==disable orelse
      Element==nodes ->
        maps:put(atom_to_binary(Element, utf8), upgrade(V), Acc);
       (Element, _V, _Acc) when is_atom(Element) ->
        try
          throw(bad)
        catch throw:bad:S ->
                logger:error("Found atom ~p in settings at ~p", [Element, S]),
                throw({'bad_atom',Element})
        end;
       (Element, V, Acc) when is_integer(Element) ->
        maps:put(Element, upgrade(V), Acc);
       (Element, V, Acc) when is_binary(Element) ->
        maps:put(Element, upgrade(V), Acc)
    end, #{}, Term).

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
action(<<"lists_cleanup">>) -> lcleanup;
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
    lists:reverse(parse_settings(maps:keys(Settings), Settings, [], [], Mode));

get_patches(Settings, Mode = scalar) when is_map(Settings) ->
    lists:reverse(parse_settings_scalar(maps:keys(Settings), Settings, [], [], Mode)).

parse_settings([], _, _, Patches, _Mode) -> Patches;
parse_settings([H|T], Settings, Path, Patches, Mode) ->
  NewPath = [H|Path],
  Item = maps:get(H, Settings),
  NewPatches = case Item of
                 #{} ->
                   parse_settings(maps:keys(Item), Item, NewPath, Patches, Mode);
                 [_|_] ->
                   lists:foldl(
                     fun(Elem, Acc) ->
                         [#{<<"t">> => <<"list_add">>,
                            <<"p">> => lists:reverse(NewPath),
                            <<"v">> => Elem}|Acc]
                     end, Patches, Item);
                 _ ->
                   [#{<<"t">> => <<"set">>,
                      <<"p">> => lists:reverse(NewPath),
                      <<"v">> => Item}|Patches]
               end,
  parse_settings(T, Settings, Path, NewPatches, Mode).

parse_settings_scalar([], _, _, Patches, _Mode) -> Patches;
parse_settings_scalar([H|T], Settings, Path, Patches, Mode) ->
  NewPath = [H|Path],
  Item = maps:get(H, Settings),
  NewPatches = case Item of
                 _ when not is_map(Item) ->
                   [{lists:reverse(NewPath),Item}|Patches];
                 #{} ->
                   parse_settings_scalar(maps:keys(Item), Item, NewPath, Patches, Mode)
               end,
  parse_settings_scalar(T, Settings, Path, NewPatches, Mode).

