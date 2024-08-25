-module(mledger).
% vim: tabstop=2 shiftwidth=2 expandtab
-include("include/tplog.hrl").
-compile({no_auto_import,[get/1]}).
-export([start_db/0,deploy4test/2, put/2,get/1,get_vers/1,hash/1,hashl/1]).
-export([bi_create/6,bi_set_ver/2]).
-export([bals2patch/1, apply_patch/2]).
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
  [
   table_descr(bal_items),
   table_descr(ledger_tree),
   table_descr(address_storage)
  ].


table_descr(bal_items) ->
  {
   bal_items,
   record_info(fields, bal_items),
   [address,key,version,path],
   [[address,version],[address,key]],
   undefined
  };

table_descr(ledger_tree) ->
  {
   ledger_tree,
   [key, value],
   [key],
   [],
   fun() ->
       case rockstable:get(mledger,undefined,{ledger_tree,<<"R">>,'_'}) of
         not_found ->
           rockstable:put(mledger,undefined,{ledger_tree,<<"R">>,db_merkle_trees2:empty()});
         [{ledger_tree,<<"R">>,_}] ->
           ok
       end
   end
  };

table_descr(address_storage) ->
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
  application:start(rockstable),
  TmpDir="/tmp/ledger_test."++(integer_to_list(os:system_time(),16)),
  filelib:ensure_dir(TmpDir),
  ok=rockstable:open_db(mledger,TmpDir,tables()),
  try
    Patches=bals2patch(LedgerData),
    {ok,_}=apply_patch(Patches,{commit,1}),
    TestFun(undefined)
  after
    rockstable:close_db(mledger),
    rm_rf(TmpDir)
  end.

start_db() ->
  Path=utils:dbpath(mledger),
  case rockstable:open_db(mledger,Path,tables()) of
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



get_kpvs(Address, Key, Path, Opts) ->
  case rockstable:get(mledger,
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


get_kpvs(Address, Key, Path) ->
  get_kpvs(Address, Key, Path, []).

get_kpv(Address, Key, Path) ->
  case rockstable:get(mledger,
                      undefined,
                      #bal_items{address=Address,
                                 version=latest,
                                 key=Key,
                                 path=Path,
                                 _='_'}) of
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


do_apply(Table, [], _) ->
  {ok,
   db_merkle_trees2:root_hash({fun dbmtfun/4, #{}, {Table, ledger_tree} })
  };

do_apply(Table, [E1|_]=Patches, HeiHash) when is_record(E1, bal_items) ->
  ChAddrs=lists:usort([ Address || #bal_items{address=Address} <- Patches ]),

  %ensure merkle tree for exists for all changed accounts
  lists:foreach(
    fun(Address) ->
        account_to_mt(Table, Address)
    end,
    ChAddrs
   ),

  case HeiHash of
    _ when is_integer(HeiHash) ->
      lists:foreach( fun(E) ->
                         write_with_height(Table,E,HeiHash)
                     end, Patches);
    {Height, Hash} when is_integer(Height), is_binary(Hash) ->
      lists:foreach( fun(E) ->
                         write_with_height(Table,E, Height)
                     end, Patches),
      lists:foreach(fun(Address) ->
                        write_with_height(Table,
                                          bi_create(Address,latest,ublk,[],Height,Hash),
                                          Height
                                         )
                    end,ChAddrs);
    _ ->
      lists:foreach( fun (BalItem) ->
                         rockstable:put(Table, env, BalItem),
                         account_mt(Table, BalItem, undefined)
                     end, Patches)
  end,
  NewMT=apply_mt(ChAddrs),
  RH=db_merkle_trees2:root_hash({fun dbmtfun/4,
                   NewMT,
                   {Table, ledger_tree}
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

apply_backup(Patches) ->
  do_apply(mledger, Patches, undefined).

apply_patch(Patches, check) ->
  F=fun() ->
        NewHash=do_apply(mledger, Patches, undefined),
        throw({'abort',NewHash})
    end,
  {aborted,{throw,{abort,NewHash}}}=rockstable:transaction(mledger,F),
  %io:format("Check hash ~p~n",[NewHash]),
  NewHash;

apply_patch(Patches, {commit, HeiHash, ExpectedHash}) ->
  F=fun() ->
        {ok,LH}=do_apply(mledger, Patches, HeiHash),
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
  case rockstable:transaction(mledger,F) of
    {atomic,Res} ->
      {ok, Res};
    {aborted,{throw,{abort,NewHash}}} ->
      {error, NewHash}
  end;

apply_patch(Patches, {commit, HeiHash}) ->
  %Filename="ledger_"++integer_to_list(os:system_time(millisecond))++atom_to_list(node()),
  %?LOG_INFO("Ledger dump ~s",[Filename]),
  %wrfile(Filename, Patches),
  %dump_ledger("pre",Filename),
  {atomic,Res}=rockstable:transaction(mledger,
                                      fun() ->
                                          try
                                            do_apply(mledger, Patches, HeiHash)
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


rollback_internal(Table, Height) ->
  ToDelete=rockstable:get(Table,env,#bal_items{introduced=Height,_='_'}),
  ToRestore=rockstable:get(Table,env,#bal_items{version=Height,_='_'}),

  OldAddr=lists:usort([ Address || #bal_items{address=Address} <- ToRestore ]),
  NewAddr=lists:usort([ Address || #bal_items{address=Address} <- ToDelete ]),
  Addr2Del=NewAddr -- OldAddr,

  lists:foreach(
    fun(#bal_items{version=latest}=BalItem) ->
        rockstable:del(Table,env,BalItem),
        account_mt(Table, BalItem#bal_items{value= <<>>},undefined)
    end,
    ToDelete),

  lists:foreach(
    fun(#bal_items{}=BalItem) ->
        rockstable:del(Table,env,BalItem),
        OldBal1=bi_set_ver(BalItem,latest),
        rockstable:put(Table,env,OldBal1),
        account_mt(Table, OldBal1,undefined)
    end,
    ToRestore),

  del_mt(Addr2Del),
  NewMT=apply_mt(OldAddr),
  db_merkle_trees2:root_hash({fun dbmtfun/4,
                                 NewMT,
                                 {mledger, ledger_tree}
                                }).

  
rollback(Height, ExpectedHash) ->
  rollback(mledger, Height, ExpectedHash).

rollback(Table, Height, ExpectedHash) ->
  case application:get_env(tpnode,rollback_snapshot,false) of
    true ->
      Backup=utils:dbpath("rollback_"++atom_to_list(Table)++"_"++integer_to_list(Height)++"_"++binary_to_list(hex:encodex(ExpectedHash))++"_bck"),
      ?LOG_NOTICE("Backup ~p before rollback ~s",[Table, Backup]),
      rockstable:backup(Table,Backup);
    false ->
      ok
  end,
  Trans=fun() ->
            RH=rollback_internal(Table, Height),
            if(RH==ExpectedHash) ->
                {ok, RH};
              true ->
                throw({hash_mismatch, RH, ExpectedHash})
            end
        end,
  case
    rockstable:transaction(Table, Trans) of
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

apply_mt(ChAddrs) ->
  lists:foldl(
    fun(Addr,Acc) ->
      db_merkle_trees2:balance({fun dbmtfun/4,
                    #{},
                    {mledger, address_storage, Addr}
                   }),
      Hash=db_merkle_trees2:root_hash(
           {fun mledger:dbmtfun/4,
          #{},
          {mledger, address_storage, Addr}
           }),
      db_merkle_trees2:enter(Addr, Hash, {fun dbmtfun/4,
                        Acc,
                        {mledger, ledger_tree}
                         })
  end, #{}, ChAddrs),
  db_merkle_trees2:balance({fun dbmtfun/4,
              #{},
              {mledger, ledger_tree}
               }).

addr_proof(Address) ->
  {atomic,Res}=rockstable:transaction(mledger,
    fun() -> {
    db_merkle_trees2:root_hash({fun dbmtfun/4, #{}, {mledger, ledger_tree}}),
    db_merkle_trees2:merkle_proof(Address,{fun dbmtfun/4, #{}, {mledger, ledger_tree}})
        }
    end),
  Res.

getfun({storage,Addr,Key}) ->
  case mledger:get_kpv(Addr,state,Key) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;
getfun({code,Addr}) ->
  case mledger:get_kpv(Addr,code,[]) of
    undefined ->
      <<>>;
    {ok, Bin} ->
      Bin
  end;
getfun({lstore,Addr,Path}) ->
  mledger:get_lstore_map(Addr,Path);
getfun({Addr, _Cur}) -> %this method actually returns everything, except lstore and state
  case mledger:get(Addr) of
    #{amount:=_}=Bal -> maps:without([changes],Bal);
    undefined -> mbal:new()
  end;
getfun(Addr) -> %this method actually returns everything, except lstore and state
  case mledger:get(Addr) of
    #{amount:=_}=Bal -> maps:without([changes],Bal);
    undefined -> mbal:new()
  end.


