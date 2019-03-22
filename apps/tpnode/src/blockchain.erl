-module(blockchain).
-export([exists/1, receive_block/2, blkid/1]).
-export([last_meta/0,
         ready/0,
         last/0, last/1, chain/0,
         rel/2]).

receive_block(Handler, BlockPart) ->
  blockchain_sync:receive_block(Handler, BlockPart).

exists(Hash) ->
  try
    gen_server:call(blockchain_reader, {block_exists, Hash})
  catch
    exit:{timeout,{gen_server,call,[blockchain_reader,block_exists,_]}} ->
      timeout
  end.

ready() ->
  try
    gen_server:call(blockchain_updater, ready, 50)
  catch
    exit:{timeout,{gen_server,call,[blockchain,ready,_]}} ->
      lager:debug("selftimer5 BC is not ready"),
      false;
    Ec:Ee ->
      StackTrace = erlang:process_info(whereis(blockchain), current_stacktrace),
      ProcInfo = erlang:process_info(whereis(blockchain)),
      utils:print_error("SYNC BC is not ready err", Ec, Ee, StackTrace),
      lager:error("BC process info: ~p", [ProcInfo]),

      false
  end.

chain() ->
  {ok, Chain} = chainsettings:get_setting(mychain),
  Chain.

rel(Hash, Rel) when Rel==prev orelse Rel==child ->
  gen_server:call(blockchain_reader, {get_block, Hash, Rel});

rel(Hash, self) ->
  gen_server:call(blockchain_reader, {get_block, Hash}).

last_meta() ->
  [{last_meta, Blk}]=ets:lookup(lastblock,last_meta),
  Blk.

last(N) ->
  gen_server:call(blockchain_reader, {last_block, N}).

last() ->
  gen_server:call(blockchain_reader, last_block).

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).

