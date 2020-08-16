-module(mledger).
-compile({no_auto_import,[get/1]}).
-export([start_db/0,deploy4test/2, put/2,get/1,get_vers/1,hash/1,hashl/1]).
-export([bi_create/6,bi_set_ver/2]).
-export([bals2patch/1, apply_patch/2]).
-export([dbmtfun/3]).
-export([mb2item/1,item2mb/1]).
-export([dump_ledger/0, dump_ledger/2]).

-record(bal_items,
        {
         addr_key_ver_path,
         address,version,key,path,introduced,value,
         addr_ver, addr_key
        }).
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
  [bal_items,bal_tree,ledger_tree].

ensure_tables([]) ->
  [];

ensure_tables([E|Rest]) ->
  try
    true=is_list(mnesia:table_info(E,attributes)),
    ensure_tables(Rest)
  catch exit: {aborted,{no_exists,_,attributes}} ->
          [{E,create_table(E)} | ensure_tables(Rest)]
  end.

table_descr(bal_items) ->
  {[
    {attributes,record_info(fields, bal_items)},
    {rocksdb_copies, [node()]}
   ],[addr_ver, addr_key],
   undefined};

table_descr(bal_tree) ->
  {[
    {attributes,[key,value]},
    {rocksdb_copies, [node()]}
   ],[],
   undefined};

table_descr(ledger_tree) ->
  {[
    {attributes,[key,value]},
    {rocksdb_copies, [node()]}
   ],[],fun() ->
            mnesia:write({ledger_tree,<<"R">>,db_merkle_trees:empty()})
        end
  };
%mnesia:transaction(fun()-> mnesia:write({ledger_tree,<<"R">>,db_merkle_trees:empty()}) end)

table_descr(Any) ->
  throw({no_table_descr, Any}).

create_table(TN) ->
  {Descr, Indexes, Createfun} = table_descr(TN),
  {mnesia:create_table(TN, Descr),
   [ mnesia:add_table_index(TN, Idx) || Idx <- Indexes ],
   if is_function(Createfun) ->
        mnesia:transaction(fun() ->
                               Createfun()
                           end);
      true ->
        ignore
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
  no=mnesia:system_info(),
  TmpDir="/tmp/ledger_test."++(integer_to_list(os:system_time(),16)),
  filelib:ensure_dir(TmpDir),
  application:set_env(mnesia, dir, TmpDir),
  _ = mnesia:create_schema([node()]),
  mnesia:start(),
  mnesia_rocksdb:register(),
  ensure_tables(tables()),
  try
    Patches=bals2patch(LedgerData),
    {ok,_}=apply_patch(Patches,{commit,1}),
    TestFun(undefined)
  after
    mnesia:stop(),
    rm_rf(TmpDir)
  end.

start_db() ->
  _ = mnesia:create_schema([node()]),
  mnesia:start(),
  mnesia_rocksdb:register(),
  %mnesia:change_table_copy_type(schema, node(), disc_copies),
  L=ensure_tables(tables()),
  lager:info("Created tables ~p",[L]),
  true=is_list(L),
  ok.

bi_set_ver(#bal_items{address=Address, key=Key, path=Path}=BI,Ver) ->
  BI#bal_items{version=Ver,
               addr_ver={Address, Ver},
               addr_key={Address, Key},
               addr_key_ver_path={Address, Key, Ver, Path}
              }.

bi_create(Address,Ver,Key,Path,Introduced,Value) ->
  #bal_items{address=Address,
             version=Ver,
             key=Key,
             path=Path,
             introduced=Introduced,
             value=Value,
             addr_ver={Address, Ver},
             addr_key={Address, Key},
             addr_key_ver_path={Address, Key, Ver, Path}
            }.

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

  lists:map(
    fun item2mb/1,
    mnesia:match_object(bal_items,
                        #bal_items{
                           address=Addr,
                           version='_', key=Key, path='_', introduced='_', value='_', addr_ver='_', addr_key='_', addr_key_ver_path='_'
                          },
                        read)
   );

get_vers(Address, trans) -> 
  {atomic,List}=mnesia:transaction(
                  fun()->
                      get_vers(Address, notrans)
                  end),
  List.

item2mb(#bal_items{ address=A, key=K, path=P, value=V, version=Ver, introduced=Int }) ->
  #mb{ address=A, key=K, path=P, value=V, version=Ver, introduced=Int }.

mb2item( #mb{ address=A, key=K, path=P, value=V, version=Ver, introduced=Int }) ->
  bi_create(A,Ver,K,P,Int,V).

get(Address) -> 
  get(Address,trans).

get_raw(Address, notrans) ->
  mnesia:match_object(bal_items,
                      #bal_items{
                         addr_ver={Address, latest},
                         _ ='_'
                        },
                      read).

get(Address, notrans) -> 
  Pattern=#bal_items{ addr_ver={Address, latest}, key='$1', value='$2', _='_'},
  PatternCode=#bal_items{addr_ver={Address, latest}, key='$1', path='$2', value='$3', _='_'},
  maps:remove(changes,
              lists:foldl(
                fun(#bal_items{key=K, path=P, value=V},A) ->
                    mbal:put(K,P,V,A);
                   ([code,_,Code], A) ->
                    mbal:put(code,[], Code,A);
%                                 case mnesia:dirty_match_object(
%                                        #bal_items{
%                                           address=Address,
%                                           version=latest,
%                                           key=code,
%                                           _ = '_'
%                                          }
%                                       ) of
%                                   [] -> undefined;
%                                   [#bal_items{value=Code}] -> Code
%                                 end
%                             end,
%                             A);
                   ([lstore,K,V1], A) ->
                    mbal:put(lstore, K, V1, A);
                   ([state,K,V1], A) ->
                    mbal:put(state, K, V1, A)
                    %case maps:is_key(state, A) of
                    %  true ->
                    %  false ->
                    %    mbal:put(state, K, V1, A)
                    %    %mbal:put(state,fun(Key) when is_binary(Key) ->
                    %    %                   io:format("Req key ~p~n",[Key]),
                    %    %                   case mnesia:dirty_match_object(
                    %    %                          #bal_items{
                    %    %                             address=Address,
                    %    %                             version=latest,
                    %    %                             key=state,
                    %    %                             path=Key,
                    %    %                             _ = '_'
                    %    %                            }
                    %    %                         ) of
                    %    %                     [] -> undefined;
                    %    %                     [#bal_items{value=Code}] -> Code
                    %    %                   end;
                    %    %                  (full) ->
                    %    %                   io:format("Req all keys~n"),
                    %    %                   WholeState=mnesia:dirty_match_object(
                    %    %                                #bal_items{
                    %    %                                   address=Address,
                    %    %                                   version=latest,
                    %    %                                   key=state,
                    %    %                                   _ = '_'
                    %    %                                  }
                    %    %                               ),
                    %    %                   WholeMap=lists:foldl(
                    %    %                              fun(#bal_items{path=SK,value=SV},SA) ->
                    %    %                                  maps:put(SK,SV,SA)
                    %    %                              end, #{}, WholeState),
                    %    %                   msgpack:pack(WholeMap)
                    %    %               end,A)
                    %end
                end,
                mbal:new(),
                mnesia:select(bal_items,
                              [
                               {Pattern,    [{'==','$1',amount}  ],['$_']},
                               {Pattern,    [{'==','$1',lastblk} ],['$_']},
                               {Pattern,    [{'==','$1',pubkey}  ],['$_']},
                               {Pattern,    [{'==','$1',seq}     ],['$_']},
                               {Pattern,    [{'==','$1',t}       ],['$_']},
                               {Pattern,    [{'==','$1',ublk}    ],['$_']},
                               {Pattern,    [{'==','$1',usk}     ],['$_']},
                               {Pattern,    [{'==','$1',view}    ],['$_']},
                               {Pattern,    [{'==','$1',vm}      ],['$_']},
                               {PatternCode,[{'==','$1',lstore}  ],['$$']},
                               {PatternCode,[{'==','$1',code}    ],['$$']},
                               {PatternCode,[{'==','$1',state}   ],['$$']}
                              ],
                              read)
               ));

    %mnesia:match_object(bal_items,
    %                    #bal_items{
    %                       address=Address,
    %                       version=latest,
    %                       key='_',
    %                       path='_',
    %                       introduced='_',
    %                       value='_',
    %                       addr_ver='_',
    %                       addr_key='_',
    %                       addr_key_ver_path='_'
    %                      },
    %                    read)

get(Address, trans) -> 
  {atomic,List}=mnesia:transaction(
                  fun()->
                      get(Address, notrans)
                  end),
  List.

hashl(BIs) when is_list(BIs) ->
  MT=gb_merkle_trees:balance(
       lists:foldl(
         fun(#bal_items{key=K,path=P,value=V},Acc) ->
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
                _ ->
                  %                io:format("BS ~p~n",[BState]),
                  {ok, State} = msgpack:unpack(BState),
                  maps:fold(
                    fun(K,V,Ac) ->
                        [bi_create(A, latest, state, K, here, V)|Ac]
                    end, Acc, State)
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
              Acc
          end,
  Res=maps:fold(FoldFun, PRes, Bal),
  bals2patch(Rest,Res).

dbmtfun(get, Key, Acc) ->
  [{ledger_tree, Key, Val}] = mnesia:read({ledger_tree,Key}),
  {Val,Acc};

dbmtfun(put, {Key, Value}, Acc) ->
  ok=mnesia:write({ledger_tree,Key,Value}),
  Acc;

dbmtfun(del, Key, Acc) ->
  ok=mnesia:delete({ledger_tree,Key}),
  Acc.

do_apply([], _) ->
  {ok,
   db_merkle_trees:root_hash({fun dbmtfun/3, #{} })
  };

do_apply([E1|_]=Patches, Height) when is_record(E1, bal_items) ->
  if is_integer(Height) ->
       lists:foreach(
         fun(#bal_items{addr_key_ver_path=AKVP,value=NewVal}=BalItem) ->
             case mnesia:read(bal_items, AKVP) of
               [] ->
                 mnesia:write(BalItem#bal_items{introduced=Height});
               [#bal_items{introduced=OVer, value=OVal}=OldBal]  ->
                 if(OVal == NewVal) ->
                     ok;
                   true ->
                     OldBal1=bi_set_ver(OldBal,OVer),
                     mnesia:write(OldBal1),
                     mnesia:write(BalItem#bal_items{introduced=Height})
                 end
             end
         end,
         Patches
        );
     true ->
       lists:foreach( fun mnesia:write/1, Patches)
  end,
  ChAddrs=lists:usort([ Address || #bal_items{address=Address} <- Patches ]),
  NewLedger=[ {Address, hash(Address)} || Address <- ChAddrs ],
  lager:debug("Apply ledger ~p",[NewLedger]),
  lists:foldl(
    fun({Addr,Hash},Acc) ->
        db_merkle_trees:enter(Addr, Hash, {fun dbmtfun/3,Acc})
    end, #{}, NewLedger),
  RH=db_merkle_trees:root_hash({fun dbmtfun/3,
                                db_merkle_trees:balance({fun dbmtfun/3,#{}})
                               }),
  %io:format("RH ~p~n",[RH]),
  {ok, RH};

do_apply([E1|_],_) ->
  throw({bad_patch, E1}).

apply_patch(Patches, check) ->
  F=fun() ->
        NewHash=do_apply(Patches, undefined),
        throw({'abort',NewHash})
    end,
  {aborted,{throw,{abort,NewHash}}}=mnesia:transaction(F),
  %io:format("Check hash ~p~n",[NewHash]),
  NewHash;

apply_patch(Patches, {commit, Height, ExpectedHash}) ->
  F=fun() ->
        {ok,LH}=do_apply(Patches, Height),
        lager:info("check and commit expected ~p actual ~p",[ExpectedHash, LH]),
        case LH == ExpectedHash of
          true ->
            LH;
          false ->
            throw({'abort',LH})
        end
    end,
  case mnesia:transaction(F) of
    {atomic,Res} ->
      {ok, Res};
    {aborted,{throw,{abort,NewHash}}} ->
      {error, NewHash}
  end;

apply_patch(Patches, {commit, Height}) ->
  %Filename="ledger_"++integer_to_list(os:system_time(millisecond))++atom_to_list(node()),
  %lager:info("Ledger dump ~s",[Filename]),
  %wrfile(Filename, Patches),
  %dump_ledger("pre",Filename),
  F=fun() ->
        do_apply(Patches, Height)
    end,
  {atomic,Res}=mnesia:transaction(F),
  %dump_ledger("post",Filename),
  %io:format("Apply hash ~p~n",[Res]),
  Res.

%wrfile(Filename, Data) ->
%  file:write_file(Filename,
%                  io_lib:format("~p.~n", [ Data ])
%                 ).

dump_ledger(Info,Filename) ->
  file:write_file(Filename,
                  io_lib:format("~p.~n~p.~n~p.~n",
                                [Info,
                                 mnesia:dirty_match_object(#bal_items{_='_',version=latest}),
                                 mnesia:dirty_match_object({ledger_tree,'_','_'})
                                ]),
                  [append]
                 ).

dump_ledger() ->
  file:write_file("ledger_"++atom_to_list(node()),
                  io_lib:format("~p.~n~p.~n",
                                [
                                 mnesia:dirty_match_object(#bal_items{_='_',version=latest}),
                                 mnesia:dirty_match_object({ledger_tree,'_','_'})
                                ])).

