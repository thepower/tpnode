-module(settings).

-export([new/0,set/3,patch/2,mp/1,mpk/1,dmp/1,get/2]).
-export([pack_patch/2,unpack_patch/1,sign_patch/2]).

pack_patch(Patch, Sigs) when is_list(Sigs) ->
    msgpack:pack([Patch,Sigs]).

unpack_patch(Bin) ->
    [Patch,Sigs]=msgpack:unpack(Bin),
    {Patch,Sigs}.

sign_patch(Patch, PrivKey) when is_list(Patch) ->
    sign_patch(settings:mp(Patch), PrivKey);

sign_patch(Patch, PrivKey) when is_binary(Patch) ->
    {Patch,
     block:signhash(
       crypto:hash(sha256,Patch),
       [{timestamp,os:system_time(millisecond)}],
       PrivKey)
    }.

new() ->
    #{}.

set(A,B,C) ->
    change(set,A,B,C).

get([],M) -> M;
get([Hd|Path],M) when is_list(Path) ->
    H1=maps:get(Hd,M,#{}),
    get(Path,H1).


change(Action,[Element|Path],Value,M,FPath) when 
      Element==<<"chain">> orelse
      Element==<<"chains">> orelse
      Element==<<"nodechain">> orelse
      Element==<<"keys">> orelse
      Element==<<"globals">> orelse
      Element==<<"patchsig">> orelse
      Element==<<"blocktime">> orelse
      Element==<<"minsig">> orelse
      Element==<<"nodes">> ->
    change(Action,[binary_to_atom(Element,utf8)|Path],Value,M,FPath);

change(add,[],Value,M,FPath) ->
    M1=if M==#{} -> [];
          is_list(M) -> M;
          true -> throw({'non_list',FPath})
       end,
    lists:usort([Value|M1]);

change(remove,[],Value,M,FPath) ->
    M1=if M==#{} -> [];
          is_list(M) -> M;
          true -> throw({'non_list',FPath})
       end,
    lists:usort(M1--[Value]);

change({member,T},[],Value,M,FPath) ->
    M1=if is_list(M) -> M;
          true -> throw({'non_list',FPath})
       end,
    case lists:member(Value,M1) of
        T ->
            M;
        _ ->
            throw({'member',FPath})
    end;

change(compare,[Path],Value,M,FPath) ->
    if is_map(M) ->
           Val=maps:get(Path,M,undefined),
           if Val==Value ->
                  M;
              true ->
                  throw({compare,FPath})
           end;
       true ->
           throw({'non_map',FPath})
    end;

change(delete,[Path],null,M,FPath) -> %force delete
    if is_map(M) ->
           maps:remove(Path,M);
       true ->
           throw({'non_map',FPath})
    end;

change(delete,[Path],Value,M,FPath) -> %compare and delete
    if is_map(M) ->
           Val=maps:get(Path,M,undefined),
           if Val==Value ->
                  maps:remove(Path,M);
              true ->
                  throw({delete_val,FPath,Value})
           end;
       true ->
           throw({'non_map',FPath})
    end;


change(set,[Path],Value,M,FPath) -> %set or replace
    if is_map(M) ->
           PrevValue=maps:get(Path,M,undefined),
           if is_list(PrevValue) orelse is_map(PrevValue) ->
                  throw({'non_value',FPath});
              true ->
                  maps:put(Path,Value,M)
           end;
       true ->
           throw({'non_map',FPath})
    end;

change(Action,[Hd|Path],Value,M,FPath) when is_list(Path) ->
    H1=maps:get(Hd,M,#{}),
    maps:put(Hd,change(Action,Path,Value,H1,FPath),M).

change(Action,Path,Value,M) when is_list(Path) ->
    change(Action,Path,Value,M, Path).

patch1([],M) -> M;

patch1([#{<<"t">>:=Action,<<"p">>:=K,<<"v">>:=V}|Settings],M) ->
    lager:debug("Settings ~s K ~p v ~p",[Action,K,V]),
    M1=change(action(Action),K,V,M),
    patch1(Settings,M1).

patch({_TxID,MP},M) when is_binary(MP)->
    {Patch,Sigs}=unpack_patch(MP),
    patch(#{patch=>Patch,
            signatures=>Sigs},M);

patch({_TxID,#{patch:=Patch,
               signatures:=Sigs}},M) ->
    patch(#{patch=>Patch,
            signatures=>Sigs},M);

patch(#{patch:=Patch},M) ->
    patch(Patch,M);

patch(MP,M) ->
    DMP=dmp(MP),
    patch1(DMP,M).

dmp(Term) ->
    {ok,T}=msgpack:unpack(Term,[
                                %Not supported in msgpack or broken
                                %{known_atoms, [ chain ]}
                               ]),
    T.

mp(Term) ->
    msgpack:pack(Term,[{map_format,jiffy}, {spec,new}]).
mpk(Key) ->
    E1=binary:split(Key,<<":">>,[global]),
    mp(E1).


action(<<"list_add">>) -> add;
action(<<"list_del">>) -> remove;
action(<<"set">>) -> set;
action(<<"delete">>) -> delete;
action(<<"compare">>) -> compare;
action(<<"member">>) -> {member,true};
action(<<"nonmember">>) -> {member,false};
action(Action) -> throw({action,Action}).

