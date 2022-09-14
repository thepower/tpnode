-module(blockchain).
-include("include/tplog.hrl").
-export([exists/1, receive_block/2, blkid/1]).
-export([last_meta/0,
         ready/0,
         last/0, last/1, chain/0,
         last_permanent_meta/0,
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
    exit:{timeout,{gen_server,call,[blockchain_updater,ready,_]}} ->
      ?LOG_DEBUG("selftimer5 BC is not ready"),
      false;
    Ec:Ee ->
      StackTrace = erlang:process_info(whereis(blockchain_updater), current_stacktrace),
      ProcInfo = erlang:process_info(whereis(blockchain_updater)),
      utils:print_error("SYNC BC is not ready err", Ec, Ee, StackTrace),
      ?LOG_ERROR("BC process info: ~p", [ProcInfo]),

      false
  end.

chain() ->
  {ok, Chain} = chainsettings:get_setting(mychain),
  Chain.

rel(genesis, prev) ->
  throw(badarg);

rel(<<0,0,0,0,0,0,0,0>>, child) ->
  gen_server:call(blockchain_reader, {last_block, 0});

rel(genesis, self) ->
  gen_server:call(blockchain_reader, {last_block, 0});

rel(genesis, child) ->
  gen_server:call(blockchain_reader, {last_block, 1});

rel(Hash, Rel) when Rel==prev orelse Rel==child ->
  gen_server:call(blockchain_reader, {get_block, Hash, Rel});

rel(Hash, self) ->
  gen_server:call(blockchain_reader, {get_block, Hash}).

last_meta() ->
  [{last_meta, Blk}]=ets:lookup(lastblock,last_meta),
  Blk.

last_permanent_meta() ->
  [{header, Hdr}]=ets:lookup(lastblock,header),
  [{hash, Hash}]=ets:lookup(lastblock,hash),
  [{sign, Sign}]=ets:lookup(lastblock,sign),
  #{ hash => Hash,
     header => Hdr,
     sign => Sign
   }.
last(N) ->
  gen_server:call(blockchain_reader, {last_block, N}).

last() ->
  gen_server:call(blockchain_reader, last_block).

blkid(<<X:8/binary, _/binary>>) ->
  binary_to_list(bin2hex:dbin2hex(X));

blkid(X) ->
  binary_to_list(bin2hex:dbin2hex(X)).


