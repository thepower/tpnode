-module(mledger).
-include("include/tplog.hrl").
-compile({no_auto_import,[get/1]}).
-export([start_db/0,deploy4test/2, put/2,get/1,get_vers/1,hash/1,hashl/1]).
-export([bi_create/6,bi_set_ver/2]).
-export([bals2patch/1, apply_patch/2]).
-export([dbmtfun/3]).
-export([mb2item/1]).
-export([get_kv/1]).
-export([get_kpv/3, get_kpvs/3]).
-export([addr_proof/1, bi_decode/1]).
-export([rollback/2]).
-export([apply_backup/1]).

-record(bal_items, { address,version,key,path,introduced,value }).
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
  [table_descr(bal_items),table_descr(ledger_tree)].

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
           rockstable:put(mledger,undefined,{ledger_tree,<<"R">>,db_merkle_trees:empty()});
         [{ledger_tree,<<"R">>,_}] ->
           ok
       end
   end
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
  %Path="db/mledger_" ++ atom_to_list(node()) ++ ".db",
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

get_kpvs(Address, Key, Path) ->
  case rockstable:get(mledger,
                      undefined,
                      #bal_items{address=Address,
                                 version=latest,
                                 key=Key,
                                 path=Path,
                                 _='_'}) of
    not_found -> [];
    [] -> [];
    List ->
      [ {K, P, V} || #bal_items{key=K,path=P,value=V} <- List]
  end.

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

get(Address) -> 
  get(Address,trans).

get_kv(Address) ->
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
  Raw=get_raw(Address, notrans),
  if Raw == [] ->
       undefined;
     true ->
       maps:remove(changes,
                   lists:foldl(
                     fun
                       (#bal_items{key=code, path=_, value=Code}, A) ->
                         mbal:put(code,[], Code,A);
                       (#bal_items{key=lstore, path=K, value=V1}, A) ->
                         mbal:put(lstore, K, V1, A);
                       (#bal_items{key=state, path=K, value=V1}, A) ->
                         mbal:put(state, K, V1, A);
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
           (#bal_items{key=K,path=P,value= <<>>},Acc) ->
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

dbmtfun(get, Key, Acc) ->
  [{ledger_tree, Key, Val}] = rockstable:get(mledger,env,{ledger_tree,Key}),
  {Val,Acc};

dbmtfun(put, {Key, Value}, Acc) ->
%  io:format("Put ~p ~p~n",[Key,Value]),
  ok=rockstable:put(mledger,env,{ledger_tree,Key,Value}),
  Acc;

dbmtfun(del, Key, Acc) ->
  ok=rockstable:del(mledger,env,{ledger_tree,Key}),
  Acc.

do_apply([], _) ->
  {ok,
   db_merkle_trees:root_hash({fun dbmtfun/3, #{} })
  };

do_apply([E1|_]=Patches, HeiHash) when is_record(E1, bal_items) ->
  ChAddrs=lists:usort([ Address || #bal_items{address=Address} <- Patches ]),

  WriteWHeight=fun(#bal_items{value=NewVal}=BalItem,Height) ->
                   case rockstable:get(mledger, env, BalItem) of
                     not_found ->
                       rockstable:put(mledger, env,BalItem#bal_items{introduced=Height});
                     [#bal_items{introduced=_OVer, value=OVal}=OldBal]  ->
                       if(OVal == NewVal) ->
                           ok;
                         NewVal == <<>> ->
                           rockstable:put(mledger, env, bi_set_ver(OldBal,Height)),
                           rockstable:del(mledger, env, OldBal);
                         true ->
                           rockstable:put(mledger, env, bi_set_ver(OldBal,Height)),
                           rockstable:put(mledger, env, BalItem#bal_items{introduced=Height})
                       end
                   end
               end,
  case HeiHash of
    _ when is_integer(HeiHash) ->
      lists:foreach( fun(E) ->
                         WriteWHeight(E,HeiHash)
                     end, Patches);
    {Height, Hash} when is_integer(Height), is_binary(Hash) ->
      lists:foreach( fun(E) ->
                         WriteWHeight(E, Height)
                     end, Patches),
      lists:foreach(fun(Address) ->
                        WriteWHeight(
                          bi_create(Address,latest,ublk,[],Height,Hash),
                          Height
                         )
                        end,ChAddrs);
    _ ->
      lists:foreach( fun (Patch) ->
                         rockstable:put(mledger, env, Patch)
                     end, Patches)
  end,
  NewMT=apply_mt(ChAddrs),
  RH=db_merkle_trees:root_hash({fun dbmtfun/3,
                                NewMT
                               }),
  %io:format("RH ~p~n",[RH]),
  {ok, RH};

do_apply([E1|_],_) ->
  throw({bad_patch, E1}).

apply_backup(Patches) ->
  do_apply(Patches, undefined).

apply_patch(Patches, check) ->
  F=fun() ->
        NewHash=do_apply(Patches, undefined),
        throw({'abort',NewHash})
    end,
  {aborted,{throw,{abort,NewHash}}}=rockstable:transaction(mledger,F),
  %io:format("Check hash ~p~n",[NewHash]),
  NewHash;

apply_patch(Patches, {commit, HeiHash, ExpectedHash}) ->
  F=fun() ->
        {ok,LH}=do_apply(Patches, HeiHash),
        ?LOG_INFO("check and commit expected ~p actual ~p",[ExpectedHash, LH]),
        case LH == ExpectedHash of
          true ->
            LH;
          false ->
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
  F=fun() ->
          do_apply(Patches, HeiHash)
    end,
  {atomic,Res}=rockstable:transaction(mledger, F),
  %dump_ledger("post",Filename),
  %io:format("Apply hash ~p~n",[Res]),
  Res.

%wrfile(Filename, Data) ->
%  file:write_file(Filename,
%                  io_lib:format("~p.~n", [ Data ])
%                 ).


rollback(Height, ExpectedHash) ->
  case
  rockstable:transaction(mledger,
    fun() ->
        ToDelete=rockstable:get(mledger,env,#bal_items{introduced=Height,_='_'}),
        ToRestore=rockstable:get(mledger,env,#bal_items{version=Height,_='_'}),

        OldAddr=lists:usort([ Address || #bal_items{address=Address} <- ToRestore ]),
        NewAddr=lists:usort([ Address || #bal_items{address=Address} <- ToDelete ]),
        Addr2Del=NewAddr -- OldAddr,

        lists:foreach(
          fun(#bal_items{version=latest}=BalItem) ->
              rockstable:del(mledger,env,BalItem)
          end,
          ToDelete),

        lists:foreach(
          fun(#bal_items{}=BalItem) ->
              OldBal1=bi_set_ver(BalItem,latest),
              rockstable:put(mledger,env,OldBal1)
          end,
          ToRestore),

        del_mt(Addr2Del),
        NewMT=apply_mt(OldAddr),
        RH=db_merkle_trees:root_hash({fun dbmtfun/3,
                                      NewMT
                                     }),

        if(RH==ExpectedHash) ->
            {ok, RH};
          true ->
            throw({hash_mismatch, RH, ExpectedHash})
        end
    end) of
    {atomic, {ok, Hash}} -> {ok, Hash};
    {aborted, Err} -> {error,Err}
  end.

del_mt(ChAddrs) ->
  lists:foldl(
    fun(Addr,Acc) ->
        db_merkle_trees:delete(Addr, {fun dbmtfun/3,Acc})
    end, #{}, ChAddrs).

apply_mt(ChAddrs) ->
  NewLedger=[ {Address, hash(Address)} || Address <- ChAddrs ],
  ?LOG_DEBUG("Apply ledger ~p",[NewLedger]),
  lists:foldl(
    fun({Addr,Hash},Acc) ->
        db_merkle_trees:enter(Addr, Hash, {fun dbmtfun/3,Acc})
    end, #{}, NewLedger),
  db_merkle_trees:balance({fun dbmtfun/3,#{}}).

addr_proof(Address) ->
  {atomic,Res}=rockstable:transaction(mledger,
    fun() -> {
         db_merkle_trees:root_hash({fun dbmtfun/3, #{}}),
        db_merkle_trees:merkle_proof(Address,{fun dbmtfun/3, #{}})
        }
    end),
  Res.


