-module(importexport).
-export([import_all/1]).

import_all(Path) ->
  application:stop(tpnode),
  rdb_dispatcher:start_link(),
  Ledgers=avail_ledger(Path),
  Blocks=avail_block(Path),
  Settings=avail_settings(Path),
  BIds=[ L || {L,_} <- Blocks ],
  case match_lids(
         lists:reverse(
           lists:keysort(1,Ledgers)
          ), BIds, Settings) of
    nomatch -> throw('nomatch');
    N when is_integer(N) ->
      {N,Ledger}=lists:keyfind(N,1,Ledgers),
      {N,Set}=lists:keyfind(N,1,Settings),
      restore_settings(filename:join(Path,Set)),
      restore_blocks(Path,N),
      restore_ledger(filename:join(Path,Ledger))
  end.

restore_settings(SetFile) ->
  {ok, LDB}=ldb:open("db/db_" ++ atom_to_list(node())),
  {ok, SF} = file:read_file(SetFile),
  true=is_map(binary_to_term(SF)),
  ldb:put_key(LDB, <<"settings">>, SF).

blockfile(N) ->
  "block_"++integer_to_list(N)++".bin".

restore_blocks(Path, N) ->
  BlockFile = filename:join(Path,blockfile(N)),
  {ok, LDB}=ldb:open("db/db_" ++ atom_to_list(node())),
  {ok, BinBlk} = file:read_file(BlockFile),
  Block = block:unpack(BinBlk),
  BlockHash=maps:get(hash, Block),
  ldb:put_key(LDB, <<"block:", BlockHash/binary>>, Block),
  ldb:put_key(LDB, <<"lastblock">>, BlockHash),
  restore_blocks(Path, N-1, LDB).

restore_blocks(_, 0, _) ->
  done;

restore_blocks(Path, N, LDB) ->
  io:format("Restoring block ~w~n",[N]),
  BlockFile = filename:join(Path,blockfile(N)),
  {ok, BinBlk} = file:read_file(BlockFile),
  Block = block:unpack(BinBlk),
  BlockHash=maps:get(hash, Block),
  ldb:put_key(LDB, <<"block:", BlockHash/binary>>, Block),
  restore_blocks(Path, N-1, LDB).

restore_ledger(LFile) ->
  rockstable:close_db(mledger),
  mledger:start_db(),
  {ok, BinDump} = file:read_file(LFile),
  All=binary_to_term(BinDump),
  rockstable:transaction(mledger,
                         fun() ->
                             ToDo=lists:foldl(
                               fun({bal_items,_,latest,_,_,_,_}=E,A) ->
                                   [E|A];
                                   ({bal_items,_,_,_,_,_,_}=E,A) ->
                                   rockstable:put(mledger, env, E),
                                   A
                               end, [], All),
                             mledger:apply_backup(ToDo)
                         end).


match_lids([],_,_) -> nomatch;
match_lids([{LID,_}|Rest], BIDs, Settings) ->
  case lists:member(LID, BIDs) of
    true ->
      case lists:keyfind(LID,1,Settings) of
        {LID,_} -> LID;
        false ->
          match_lids(Rest, BIDs, Settings)
      end;
    false ->
      match_lids(Rest, BIDs, Settings)
  end.

avail_settings(Path) ->
  Files=filelib:wildcard("settings_*.bin",Path),
  [ { h(N), N } || N <- Files ].

avail_ledger(Path) ->
  Files=filelib:wildcard("ledger_*.bin",Path),
  [ { h(N), N } || N <- Files ].

avail_block(Path) ->
  Files=filelib:wildcard("block_*.bin",Path),
  [ { h(N), N } || N <- Files ].

h(N) ->
  [_Prefix,Rest]=string:split(N,"_"),
  [Num,"bin"]=string:split(Rest,"."),
  list_to_integer(Num).
