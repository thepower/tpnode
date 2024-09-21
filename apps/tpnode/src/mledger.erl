-module(mledger).
% vim: tabstop=2 shiftwidth=2 expandtab
-include("include/tplog.hrl").

%new API starts here
-export([tables/1, deploy4test/3]).
-export([db_get_one/5, db_get_multi/5]).
-export([apply_patch/3]).
-export([apply_backup/2]).
-export([getfun/2]).
-export([field_to_id/1]).
-export([id_to_field/1]).

%OLD API
-compile({no_auto_import,[get/1]}).
-export([start_db/0,  deploy4test/2, put/2,get/1,get_vers/1,hash/1,hashl/1]).
-export([bi_create/6,bi_set_ver/2]).
-export([bals2patch/1, apply_patch/2]).
-export([patch_pstate2mledger/1]).
-export([dbmtfun/4]).
-export([mb2item/1]).
-export([get_lstore/2,get_lstore_map/2]).
-export([getfun/1]).
-export([get_kv/1]).
-export([get_kpv/3, get_kpvs/4, get_kpvs/3]).
-export([get_kpvs_height/5, get_kpvs_height/4]). % <- it's relative slow !!
-export([addr_proof/1, bi_decode/1]).
-export([rollback/2]).
-export([apply_backup/1]).
-export([tables/0]).
-export([account_to_mt/2, account_mt_check/2]).

-record(bal_items, { address,version,key,path,introduced,value }).
-record(address_storage, { address,key,value }).
-opaque bal_items() :: #bal_items{}.
-export_type([bal_items/0]).

-record(mb,
        {
         address,
         key,
         path,
         value,
         version,
         introduced
        }).

tables() ->
  tables(mledger).

tables(DBName) ->
  [
   table_descr(DBName, bal_items),
   table_descr(DBName, ledger_tree),
   table_descr(DBName, address_storage)
  ].


table_descr(_DBName, bal_items) ->
  {
   bal_items,
   record_info(fields, bal_items),
   [address,key,version,path],
   [[address,version],[address,key]],
   undefined
  };

table_descr(DBName, ledger_tree) ->
  {
   ledger_tree,
   [key, value],
   [key],
   [],
   fun() ->
       case rockstable:get(DBName,undefined,{ledger_tree,<<"R">>,'_'}) of
         not_found ->
           rockstable:put(DBName,undefined,{ledger_tree,<<"R">>,db_merkle_trees2:empty()});
         [{ledger_tree,<<"R">>,_}] ->
           ok
       end
   end
  };

table_descr(_DBName, address_storage) ->
  {
   address_storage,
   record_info(fields, address_storage),
   [address, key],
   [],
   undefined
  }.

rm_rf(Dir) ->
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).

deploy4test(LedgerData, TestFun) ->
  deploy4test(mledger, LedgerData, TestFun).

deploy4test(DBName, LedgerData, TestFun) ->
  application:start(rockstable),
  TmpDir="/tmp/"++atom_to_list(DBName)++"_test."++(integer_to_list(os:system_time(),16)),
  filelib:ensure_dir(TmpDir),
  ok=rockstable:open_db(DBName, TmpDir, tables(DBName)),
  try
    Patches=bals2patch(LedgerData),
    {ok,_}=apply_patch(DBName, Patches, {commit,1}),
    TestFun(DBName)
  after
    rockstable:close_db(DBName),
    rm_rf(TmpDir)
  end.

start_db() ->
  start_db(mledger).

start_db(DbName) ->
  Path=utils:dbpath(DbName),
  case rockstable:open_db(DbName,Path,tables(DbName)) of
    ok -> ok;
    {error,alias_in_use} -> ok
  end.

bi_set_ver(#bal_items{}=BI,Ver) ->
  BI#bal_items{version=Ver}.

bi_create(Address,Ver,Key,Path,Introduced,Value) ->
  #bal_items{address=Address,
             version=Ver,
             key=Key,
             path=Path,
             introduced=Introduced,
             value=Value
            }.

bi_decode(#bal_items{address=Address,version=Ver,key=Key,path=Path,introduced=Introduced,value=Value})
->
  {Address,Ver,Key,Path,Introduced,Value}.

put(_Address, Bal) ->
  Changes=maps:get(changes,Bal),
  lists:foldl(
    fun(_Field,Acc) ->
        Acc
    end, #{}, Changes).

get_vers(Address) ->
  get_vers(Address,trans).

get_vers(Address, notrans) ->
  {Addr,Key}=case Address of
               {A, K} when is_binary(A) ->
                 {A, K};
               A when is_binary(A) ->
                 {A, '_'}
             end,

  rockstable:get(mledger,env,
                 #bal_items{
                    address=Addr,
                    key=Key,
                    _='_'
                   });

get_vers(Address, trans) ->
  {atomic,List}=rockstable:transaction(mledger,
                                       fun()->
                                           get_vers(Address, notrans)
                                       end),
  List.

mb2item( #mb{ address=A, key=K, path=P, value=V, version=Ver, introduced=Int }) ->
  bi_create(A,Ver,K,P,Int,V).

get_lstore_map(Address, Path) ->
  settings:get(Path,
               lists:foldl(
                 fun({lstore,P,Val},A) ->
                     settings:set(P,Val,A)
                 end, #{}, get_lstore(Address,Path))
              ).

get_lstore(Address, Path) ->
  %% it might be non optimal way, possible need to compile predicate, needs benchmarking
  case rockstable:get(mledger,
                      undefined,
                      #bal_items{address=Address,
                                 version=latest,
                                 key=lstore,
                                 _='_'},
                      [{pred,fun(#bal_items{path=P}) ->
                                 lists:prefix(Path,P)
                             end}]
                     ) of
    not_found -> [];
    [] -> [];
    List ->
      [ {K, P, V} || #bal_items{key=K,path=P,value=V} <- List]
  end.


%it's relative slow, do not use in production too much
get_kpvs_height(Address, Key, Path, BlockHeight) ->
  get_kpvs_height(Address, Key, Path, BlockHeight,[]).

get_kpvs_height(Address, Key, Path, BlockHeight, Opts) ->
  case rockstable:get(mledger,
                      undefined,
                      #bal_items{address=Address,
                                 key=Key,
                                 path=Path,
                                 _='_'}, Opts) of
    not_found -> [];
    [] -> [];
    List ->
      [ {K, P, V} || #bal_items{key=K,path=P,value=V,introduced=I,version=E} <- List,
                     BlockHeight>=I,
                     E>BlockHeight
      ]
  end.

get_kpvs(Address, Key, Path) ->
  db_get_multi(mledger, Address, Key, Path, []).

get_kpvs(Address, Key, Path, Opts) ->
  db_get_multi(mledger, Address, Key, Path, Opts).

get_kpv(Address, Key, Path) ->
  db_get_one(mledger, Address, Key, Path, []).

db_get_multi(DB, Address, Key, Path, Opts) ->
  case rockstable:get(DB,
                      undefined,
                      #bal_items{address=Address,
                                 version=latest,
                                 key=Key,
                                 path=Path,
                                 _='_'}, Opts) of
    not_found -> [];
    [] -> [];
    List ->
      [ {K, P, V} || #bal_items{key=K,path=P,value=V} <- List]
  end.

db_get_one(DB, Address, Key, Path, Opts) ->
  case rockstable:get(DB,
                      undefined,
                      #bal_items{address=Address,
                                 version=latest,
                                 key=Key,
                                 path=Path,
                                 _='_'}, Opts) of
    not_found -> undefined;
    [] -> undefined;
    [#bal_items{value=V}] ->
      {ok, V}
  end.

% This function returns mbal with follwing fields :
% amount,lastblk,pubkey,seq,t,vm,ublk,code
% no lstore and state!
get(Address) ->
  get(Address,trans).

get_kv(Address) -> %only for HTTP API [<<"address">>, TAddr, <<"verify">>]
  {atomic,Items}=rockstable:transaction(mledger,
    fun() ->
        get_raw(Address, notrans)
    end),
  [ {{K,P},V} || #bal_items{ key=K,path=P,value=V } <- Items ].

get_raw(Address, notrans) ->
  rockstable:get(mledger, env, #bal_items{
                                  address=Address,
                                  version=latest,
                                  _ ='_'
                                 }).

get(Address, notrans) ->
  Fields=[amount,lastblk,pubkey,seq,t,vm,ublk,code],
  Raw=lists:flatten(
        lists:foldl(
          fun(Key,Acc) ->
              [rockstable:get(mledger, env, #bal_items{
                                               address=Address,
                                               version=latest,
                                               key=Key,
                                               path=[],
                                               _ ='_'
                                              })|Acc]
          end,[],Fields)),
  if Raw == [] ->
       undefined;
     true ->
       maps:remove(changes,
                   lists:foldl(
                     fun
                       (not_found,A) ->
                         A;
                       (#bal_items{key=code, path=_, value=Code}, A) ->
                         mbal:put(code,[], Code,A);
                       (#bal_items{key=K, path=P, value=V},A) ->
                         mbal:put(K,P,V,A)
                     end,
                     mbal:new(),
                     Raw
                    ))
  end;

get(Address, trans) ->
  {atomic,List}=rockstable:transaction(mledger,
                                       fun()->
                                           get(Address, notrans)
                                       end),
  List.

hashl(BIs) when is_list(BIs) ->
  MT=gb_merkle_trees:balance(
       lists:foldl(
         fun
           (#bal_items{key=ublk},Acc) ->
             Acc;
           (#bal_items{key=_K,path=_P,value= <<>>},Acc) ->
             Acc;
           (#bal_items{key=K,path=P,value=V},Acc) ->
             gb_merkle_trees:enter(sext:encode({K,P}),sext:encode(V),Acc)
         end, gb_merkle_trees:empty(), BIs)
      ),
  gb_merkle_trees:root_hash(MT).

hash(Address) when is_binary(Address) ->
  BIs=get_raw(Address,notrans),
  hashl(BIs).

patch_pstate2mledger([]) ->
  [];

patch_pstate2mledger([[Address,FieldId,Path,OldValue,NewValue]|Rest]) when is_integer(FieldId) ->
  patch_pstate2mledger([{Address,id_to_field(FieldId),Path,OldValue,NewValue}|Rest]);

patch_pstate2mledger([{Address,storage,Path,_OldValue,NewValue}|Rest]) ->
  Res = bi_create(Address, latest, state, Path, here, NewValue),
  [ Res | patch_pstate2mledger(Rest)];

patch_pstate2mledger([{Address,Field,Path,_OldValue,NewValue}|Rest]) ->
  Res = bi_create(Address, latest, Field, Path, here, NewValue),
  [ Res | patch_pstate2mledger(Rest)].

bals2patch(Data) ->
  bals2patch(Data,[]).

bals2patch([], Acc) -> Acc;
bals2patch([{A,Bal}|Rest], PRes) ->
  FoldFun=fun (Key,Val,Acc) when Key == amount;
                                 Key == code;
                                 Key == pubkey;
                                 Key == vm;
                                 Key == view;
                                 Key == t;
                                 Key == seq;
                                 Key == usk;
                                 Key == lastblk ->
              [bi_create(A, latest, Key, [], here, Val)|Acc];
              (state,BState,Acc) ->
                  case mbal:get(vm,Bal) of
                    <<"chainfee">> ->
                      [bi_create(A, latest, state, <<>>, here, BState)|Acc];
                    <<"erltest">> ->
                      [bi_create(A, latest, state, <<>>, here, BState)|Acc];
                    _ when is_binary(BState) ->
                      % io:format("BS ~p~n",[BState]),
                      {ok, State} = msgpack:unpack(BState),
                      maps:fold(
                        fun(K,V,Ac) ->
                            [bi_create(A, latest, state, K, here, V)|Ac]
                        end, Acc, State);
                    _ when is_map(BState) ->
                      % io:format("BS ~p~n",[BState]),
                      maps:fold(
                        fun(K,V,Ac) ->
                            [bi_create(A, latest, state, K, here, V)|Ac]
                        end, Acc, BState)
                  end;
              (changes,_,Acc) ->
                  Acc;
              (lstore,BState,Acc) ->
                  State=if is_binary(BState) ->
                         {ok, S1} = msgpack:unpack(BState),
                         S1;
                       is_map(BState) ->
                         BState
                    end,

              Patches=settings:get_patches(State,scalar),
              %io:format("LStore ~p~n",[Patches]),
              lists:foldl(
                fun({K,V},Ac1) ->
                    [bi_create(A, latest, lstore, K, here, V)|Ac1]
                end, Acc, Patches);
              (Key,_,Acc) ->
              io:format("Unhandled field ~p~n",[Key]),
              throw({'bad_field',Key}),
              Acc
          end,
  Res=maps:fold(FoldFun, PRes, Bal),
  bals2patch(Rest,Res).

dbmtfun(get, Key, Acc, {DbName,ledger_tree}) ->
  [{ledger_tree, Key, Val}] = rockstable:get(DbName,env,{ledger_tree,Key}),
  {Val,Acc};

dbmtfun(put, {Key, Value}, Acc, {DbName,ledger_tree}) ->
%  io:format("Put ~p ~p~n",[Key,Value]),
  ok=rockstable:put(DbName,env,{ledger_tree,Key,Value}),
  Acc;

dbmtfun(del, Key, Acc, {DbName, ledger_tree}) ->
  ok=rockstable:del(DbName,env,{ledger_tree,Key}),
  Acc;

dbmtfun(get, Key, Acc, {DbName, address_storage, Addr}) ->
  [{address_storage,Addr,Key,Val}] = rockstable:get(DbName,env,{address_storage,Addr,Key,'_'}),
%  io:format("get ~p key ~p~n - val ~p~n",[Addr, Key, Val]),
  {Val,Acc};

dbmtfun(put, {Key, Value}, Acc, {DbName, address_storage, Addr}) ->
%  io:format("put ~p key ~p~n - val ~p~n",[Addr,Key,Value]),
  ok=rockstable:put(DbName,env,{address_storage, Addr, Key, Value}),
  Acc;

dbmtfun(del, Key, Acc, {DbName, address_storage, Addr}) ->
%  io:format("del ~p acc ~p~n",[{address_storage, Addr, Key},Acc]),
  ok=rockstable:del(DbName,env,{address_storage, Addr, Key}),
  Acc.

account_mt(_Table, #bal_items{key=ublk},Acc) -> Acc;
account_mt(Table, #bal_items{address=Addr, key=K, path=P, value= <<>>}=_BI,Acc) ->
  %io:format("Del ~p~n",[_BI]),
  db_merkle_trees2:delete(
    sext:encode({K,P}),
    {fun dbmtfun/4, Acc, {Table, address_storage, Addr} }
   );
account_mt(Table, #bal_items{address=Addr, key=K, path=P, value=V}=_BI,Acc) ->
  %io:format("Put ~p~n",[_BI]),
  db_merkle_trees2:enter(
    sext:encode({K,P}),
    sext:encode(V),
    {fun dbmtfun/4, Acc, {Table, address_storage, Addr} }
   ).

account_mt_check(Table, Address) ->
  BIs=rockstable:get(Table, undefined, #bal_items{
                    address=Address,
                    version=latest,
                    _ ='_'
                   }),
  H1=hashl(BIs),
  Fun=fun() ->
        db_merkle_trees2:root_hash({fun mledger:dbmtfun/4, #{},
                      {Table,
                       address_storage,Address}
                       }) end,
  case rockstable:transaction(Table, Fun) of
    {atomic,H2} when H1==H2 ->
      {ok, H1};
    {atomic,H2} ->
      {error, {H1, H2}};
    Other ->
      {error, {H1, Other}}
  end.


account_to_mt(Table, Address) ->
  case rockstable:get(Table,env,{address_storage, Address, <<"R">>,'_'}) of
    not_found ->
      rockstable:put(Table, env, {address_storage, Address, <<"R">>,db_merkle_trees2:empty()}),
      BIs=rockstable:get(Table, env, #bal_items{
                        address=Address,
                        version=latest,
                        _ ='_'
                       }),
      lists:foldl(fun (BI,A) ->
                account_mt(Table, BI, A)
            end, undefined, BIs),
      db_merkle_trees2:balance({fun dbmtfun/4,
                    #{},
                    {Table, address_storage, Address}
                   });
    [{address_storage,Address,<<"R">>,_}] ->
      exists
  end.


do_apply(DbName, [], _) ->
  {ok,
   db_merkle_trees2:root_hash({fun dbmtfun/4, #{}, {DbName, ledger_tree} })
  };

do_apply(DbName, [E1|_]=Patches, HeiHash) when is_record(E1, bal_items) ->
  ChAddrs=lists:usort([ Address || #bal_items{address=Address} <- Patches ]),

  %ensure merkle tree for exists for all changed accounts
  lists:foreach(
    fun(Address) ->
        account_to_mt(DbName, Address)
    end,
    ChAddrs
   ),

  case HeiHash of
    _ when is_integer(HeiHash) ->
      lists:foreach( fun(E) ->
                         write_with_height(DbName,E,HeiHash)
                     end, Patches);
    {Height, Hash} when is_integer(Height), is_binary(Hash) ->
      lists:foreach( fun(E) ->
                         write_with_height(DbName,E, Height)
                     end, Patches),
      lists:foreach(fun(Address) ->
                        write_with_height(DbName,
                                          bi_create(Address,latest,ublk,[],Height,Hash),
                                          Height
                                         )
                    end,ChAddrs);
    _ ->
      lists:foreach( fun (BalItem) ->
                         rockstable:put(DbName, env, BalItem),
                         account_mt(DbName, BalItem, undefined)
                     end, Patches)
  end,
  NewMT=apply_mt(DbName, ChAddrs),
  RH=db_merkle_trees2:root_hash({fun dbmtfun/4,
                   NewMT,
                   {DbName, ledger_tree}
                  }),
  {ok, RH};


do_apply(_Table, [E1|_],_) ->
  throw({bad_patch, E1}).

write_with_height(Table,#bal_items{value=NewVal}=BalItem,Height) ->
  case rockstable:get(Table, env, BalItem) of
    not_found ->
      rockstable:put(Table, env,BalItem#bal_items{introduced=Height}),
      account_mt(Table, BalItem, undefined);
    [#bal_items{introduced=_OVer, value=OVal}=OldBal]  ->
      if(OVal == NewVal) ->
          ok;
        NewVal == <<>> ->
          rockstable:put(Table, env, bi_set_ver(OldBal,Height)),
          rockstable:del(Table, env, OldBal),
          account_mt(Table, BalItem, undefined);
        true ->
          rockstable:put(Table, env, bi_set_ver(OldBal,Height)),
          rockstable:put(Table, env, BalItem#bal_items{introduced=Height}),
          account_mt(Table, BalItem, undefined)
      end
  end.

apply_backup(DbName, Patches) ->
  do_apply(DbName, Patches, undefined).

apply_backup(Patches) ->
  do_apply(mledger, Patches, undefined).

apply_patch(Patches, Action) ->
  apply_patch(mledger, Patches, Action).

apply_patch(DBName, Patches, check) ->
  F=fun() ->
        NewHash=do_apply(DBName, Patches, undefined),
        throw({'abort',NewHash})
    end,
  {aborted,{throw,{abort,NewHash}}}=rockstable:transaction(DBName,F),
  %io:format("Check hash ~p~n",[NewHash]),
  NewHash;

apply_patch(DBName, Patches, {commit, HeiHash, ExpectedHash}) ->
  F=fun() ->
        {ok,LH}=do_apply(DBName, Patches, HeiHash),
        case LH == ExpectedHash of
          true ->
            ?LOG_DEBUG("check and commit expected ~p actual ~p",
                       [hex:encode(ExpectedHash), hex:encode(LH)]),
            LH;
          false ->
            ?LOG_ERROR("check and commit expected ~p actual ~p",
                      [hex:encode(ExpectedHash), hex:encode(LH)]),
            throw({'abort',LH})
        end
    end,
  case rockstable:transaction(DBName,F) of
    {atomic,Res} ->
      {ok, Res};
    {aborted,{throw,{abort,NewHash}}} ->
      {error, NewHash}
  end;

apply_patch(DBName, Patches, {commit, HeiHash}) ->
  %Filename="ledger_"++integer_to_list(os:system_time(millisecond))++atom_to_list(node()),
  %?LOG_INFO("Ledger dump ~s",[Filename]),
  %wrfile(Filename, Patches),
  %dump_ledger("pre",Filename),
  {atomic,Res}=rockstable:transaction(DBName,
                                      fun() ->
                                          try
                                            do_apply(DBName, Patches, HeiHash)
                                          catch Ec:Ee:S ->
                                                  throw({Ec,Ee,S})
                                          end
                                      end
                                     ),
  %dump_ledger("post",Filename),
  %io:format("Apply hash ~p~n",[Res]),
  Res.

%wrfile(Filename, Data) ->
%  file:write_file(Filename,
%                  io_lib:format("~p.~n", [ Data ])
%                 ).


rollback_internal(DbName, Height) ->
  ToDelete=rockstable:get(DbName,env,#bal_items{introduced=Height,_='_'}),
  ToRestore=rockstable:get(DbName,env,#bal_items{version=Height,_='_'}),

  OldAddr=lists:usort([ Address || #bal_items{address=Address} <- ToRestore ]),
  NewAddr=lists:usort([ Address || #bal_items{address=Address} <- ToDelete ]),
  Addr2Del=NewAddr -- OldAddr,

  lists:foreach(
    fun(#bal_items{version=latest}=BalItem) ->
        rockstable:del(DbName,env,BalItem),
        account_mt(DbName, BalItem#bal_items{value= <<>>},undefined)
    end,
    ToDelete),

  lists:foreach(
    fun(#bal_items{}=BalItem) ->
        rockstable:del(DbName,env,BalItem),
        OldBal1=bi_set_ver(BalItem,latest),
        rockstable:put(DbName,env,OldBal1),
        account_mt(DbName, OldBal1,undefined)
    end,
    ToRestore),

  del_mt(Addr2Del),
  NewMT=apply_mt(DbName, OldAddr),
  db_merkle_trees2:root_hash({fun dbmtfun/4,
                                 NewMT,
                                 {mledger, ledger_tree}
                                }).


rollback(Height, ExpectedHash) ->
  rollback(mledger, Height, ExpectedHash).

rollback(DbName, Height, ExpectedHash) ->
  case application:get_env(tpnode,rollback_snapshot,false) of
    true ->
      Backup=utils:dbpath("rollback_"++atom_to_list(DbName)++"_"++integer_to_list(Height)++"_"++binary_to_list(hex:encodex(ExpectedHash))++"_bck"),
      ?LOG_NOTICE("Backup ~p before rollback ~s",[DbName, Backup]),
      rockstable:backup(DbName,Backup);
    false ->
      ok
  end,
  Trans=fun() ->
            RH=rollback_internal(DbName, Height),
            if(RH==ExpectedHash) ->
                {ok, RH};
              true ->
                throw({hash_mismatch, RH, ExpectedHash})
            end
        end,
  case
    rockstable:transaction(DbName, Trans) of
    {atomic, {ok, Hash}} -> {ok, Hash};
    {aborted, Err} -> {error,Err}
  end.

del_mt(ChAddrs) ->
  lists:foldl(
    fun(Addr,Acc) ->
      db_merkle_trees2:delete(Addr, {fun dbmtfun/4,
                       Acc,
                       {mledger, ledger_tree}
                      })
    end, #{}, ChAddrs).

apply_mt(DbName, ChAddrs) ->
  lists:foldl(
    fun(Addr,Acc) ->
      db_merkle_trees2:balance({fun dbmtfun/4,
                    #{},
                    {DbName, address_storage, Addr}
                   }),
      Hash=db_merkle_trees2:root_hash(
           {fun mledger:dbmtfun/4,
          #{},
          {DbName, address_storage, Addr}
           }),
      db_merkle_trees2:enter(Addr, Hash, {fun dbmtfun/4,
                        Acc,
                        {DbName, ledger_tree}
                         })
  end, #{}, ChAddrs),
  db_merkle_trees2:balance({fun dbmtfun/4,
              #{},
              {DbName, ledger_tree}
               }).

addr_proof(Address) ->
  addr_proof(mledger, Address).

addr_proof(DbName, Address) ->
  {atomic,Res}=rockstable:transaction(DbName,
    fun() -> {
    db_merkle_trees2:root_hash({fun dbmtfun/4, #{}, {DbName, ledger_tree}}),
    db_merkle_trees2:merkle_proof(Address,{fun dbmtfun/4, #{}, {DbName, ledger_tree}})
        }
    end),
  Res.


getfun({storage,Addr,Key}, DB) ->
  case db_get_one(DB, Addr, state, Key, []) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;
getfun({Field, Addr, _Path}, DB) when Field == pubkey;
                                      Field == code;
                                      Field == vm;
                                      Field == lastblk;
                                      Field == seq;
                                      Field == t ->
  case db_get_one(DB, Addr, Field, [], []) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;
getfun({balance,Addr,Token}, DB) ->
  case db_get_one(DB, Addr, amount, [], []) of
    undefined ->
      0;
    {ok, Map} when is_map(Map) ->
      maps:get(Token, Map, 0)
  end;

getfun({lstore_raw,Addr,Path0},DB) -> %subtree match
  RawData=case Path0 of
            {Path} ->
              rockstable:get(DB,
                             undefined,
                             #bal_items{address=Addr,
                                        version=latest,
                                        path=Path,
                                        key=lstore,
                                        _='_'},
                             []
                            );
            Path ->
              rockstable:get(DB,
                             undefined,
                             #bal_items{address=Addr,
                                        version=latest,
                                        key=lstore,
                                        _='_'},
                             [{pred,fun(#bal_items{path=P}) ->
                                        lists:prefix(Path,P)
                                    end}]
                            )
          end,

  case RawData of
    not_found -> [];
    List ->
      lists:map(
        fun(#bal_items{key=lstore,path=P,value=Val}) ->
            {P,Val}
        end, List)
  end;

getfun({lstore,Addr,{Path}},DB) -> %exact path match
  case rockstable:get(DB,
                      undefined,
                      #bal_items{address=Addr,
                                 version=latest,
                                 path=Path,
                                 key=lstore,
                                 _='_'},
                      []
                     ) of
    not_found -> <<>>;
    [#bal_items{key=lstore,path=Path,value=V}] -> V;
    List ->
      lists:foldl(
        fun(#bal_items{key=lstore,path=Path1,value=V}, A) when Path1==Path ->
            [V|A]
        end, [], List)
  end;

getfun({lstore,Addr,Path},DB) -> %subtree match
  case rockstable:get(DB,
                      undefined,
                      #bal_items{address=Addr,
                                 version=latest,
                                 key=lstore,
                                 _='_'},
                      [{pred,fun(#bal_items{path=P}) ->
                                 lists:prefix(Path,P)
                             end}]
                     ) of
    not_found -> <<>>;
    [#bal_items{key=lstore,path=Path,value=V}] -> V;
    List ->
      %TODO: fix path handling, strip prefix before set
      settings:get(Path,
                   lists:foldl(
                     fun(#bal_items{key=lstore,path=P,value=Val},A) ->
                         settings:set(P,Val,A)
                     end, #{},
                     List
                    )
                  )
  end.


%legacy handler

getfun({storage,Addr,Key}) ->
  case get_kpv(Addr,state,Key) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;

getfun({code,Addr}) ->
  getfun({code,Addr,[]});
getfun({code, Addr, _}) -> %this is for compatibility
  case get_kpv(Addr,code,[]) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;
getfun({balance,Addr,Token}) ->
  case get_kpv(Addr,amount,[]) of
    undefined ->
      0;
    {ok, Map} when is_map(Map) ->
      maps:get(Token, Map, 0)
  end;
getfun({lstore,Addr,Path}) ->
  get_lstore_map(Addr,Path);

getfun({Addr, _Cur}) when is_binary(Addr) -> %this method actually returns everything, except lstore and state
  case mledger:get(Addr) of
    #{amount:=_}=Bal -> maps:without([changes],Bal);
    undefined -> mbal:new()
  end;
getfun(Addr) when is_binary(Addr) -> %this method actually returns everything, except lstore and state
  case mledger:get(Addr) of
    #{amount:=_}=Bal -> maps:without([changes],Bal);
    undefined -> mbal:new()
  end.

field_to_id(balance)-> 1;
field_to_id(seq)    -> 2;
field_to_id(code)   -> 3;
field_to_id(storage)-> 4;
field_to_id(pubkey) -> 5;
field_to_id(lstore) -> 6;
field_to_id(t)      -> 7;
field_to_id(vm)     -> 8;
field_to_id(view)   -> 64;
field_to_id(lastblk)-> 65;
field_to_id(_) -> 0.

id_to_field(1) -> balance;
id_to_field(2) -> seq;
id_to_field(3) -> code;
id_to_field(4) -> storage;
id_to_field(5) -> pubkey;
id_to_field(6) -> lstore;
id_to_field(7) -> t;
id_to_field(8) -> vm;
id_to_field(64) -> view;
id_to_field(65) -> lastblk;
id_to_field(_) -> throw(unknown).


