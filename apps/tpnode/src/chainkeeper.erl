%%%-------------------------------------------------------------------
%% @doc chainkeeper gen_server
%% @end
%%%-------------------------------------------------------------------
-module(chainkeeper).

-behaviour(gen_server).
-define(SERVER, ?MODULE).


% make chain checkout in CHAIN_CHECKOUT_TIMER_FACTOR * block time period
% after the last activity
-define(CHAIN_CHECKOUT_TIMER_FACTOR, 2).


-define(TPIC, tpic).

-define(isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp),
  TheirHeight > MyHeight
  orelse (TheirHeight =:= MyHeight andalso TheirTmp == false andalso MyTmp =/= false)
  orelse (TheirHeight =:= MyHeight andalso is_integer(TheirTmp)
            andalso is_integer(MyTmp) andalso TheirTmp > MyTmp)
  ).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%%-export([check_fork2/3]).
-export([get_permanent_hash/1, discovery/1, find_tallest/3]).
-export([resolve_tpic_assoc/2, resolve_tpic_assoc/1]).
-export([check_and_sync/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok,
    #{
      lookaround_timer => erlang:send_after(10*1000, self(), lookaround_timer),
      sync_lock => null
    }
  }.

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.


handle_cast(are_we_synced, #{sync_lock := null} = State) ->
  
  MyMeta = blockchain:last_meta(),
  MyHeader = maps:get(header, MyMeta, #{}),
  MyHeight = maps:get(height, MyHeader, 0),
  MyTmp = maps:get(temporary, MyMeta, false),
  
  stout:log(forkstate, [
    {state, are_we_synced},
    {mymeta, MyMeta},
    {myheight, MyHeight},
    {tmp, MyTmp},
    {mynode, nodekey:node_name()}
  ]),
  
  Pid = check_and_sync_runner(
    ?TPIC,
    #{
      theirnode => nodekey:node_name(),
      mynode => nodekey:node_name(),
      minsig => chainsettings:get_val(minsig)
    }),
  
  {noreply, State#{sync_lock => Pid}};


handle_cast(are_we_synced, #{sync_lock := LockPid} = State) when is_pid(LockPid) ->
  stout:log(forkstate, [
    {state, skip_are_we_synced},
    {mynode, nodekey:node_name()}
  ]),
  
  lager:debug("skip 'are we synced' message because we are syncing"),

  {noreply, State};


handle_cast({possible_fork, #{mymeta := LastMeta, hash := MissingHash}}, State) ->
  
  stout:log(forkstate, [
    {state, possible_fork},
    {last_meta, LastMeta},
    {hash, MissingHash},
    {mynode, nodekey:node_name()}
  ]),
  
  {noreply, State};

handle_cast({tpic, _NodeName, _From, _Payload}, #{lookaround_timer := _Timer} = State) ->
  {noreply, State};

%%handle_cast({tpic, NodeName, _From, Payload}, #{lookaround_timer := Timer} = State) ->
%%  catch erlang:cancel_timer(Timer),
%%  Blk =
%%    try
%%      case msgpack:unpack(Payload, [{known_atoms, []}]) of
%%        {ok, Decode} when is_map(Decode) ->
%%          case Decode of
%%            #{null := <<"block_installed">>,<<"blk">> := ReceivedBlk} ->
%%              lager:info("got ck_beacon from ~s, block: ~p", [NodeName, Payload]),
%%              block:unpack(ReceivedBlk);
%%            _ ->
%%              lager:info("got ck_beacon from ~s, unpacked payload: ~p", [NodeName, Decode]),
%%              #{}
%%          end;
%%        _ ->
%%          lager:error("can't decode msgpack: ~p", [Payload]),
%%          #{}
%%      end
%%    catch
%%      Ec:Ee ->
%%        utils:print_error(
%%          "msgpack decode error/can't unpack block", Ec, Ee, erlang:get_stacktrace()),
%%        #{}
%%    end,
%%
%%  lager:info("Blk: ~p", [Blk]),
%%
%%  stout:log(ck_beacon,
%%    [
%%      {node, NodeName},
%%      {block, Blk}
%%    ]
%%  ),
%%
%%%%  check_block(
%%%%    Blk,
%%%%    #{
%%%%      theirnode => NodeName,
%%%%      mynode => nodekey:node_name()
%%%%    }
%%%%  ),
%%
%%  {noreply, State#{
%%    lookaround_timer => setup_timer(lookaround_timer)
%%  }};


% we update timer on new block setup
handle_cast(accept_block, #{lookaround_timer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
  {noreply, State#{
    lookaround_timer => setup_timer(lookaround_timer)
  }};


handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.


handle_info(
  {'DOWN', _Ref, process, Pid, Reason},
  #{sync_lock := Pid, lookaround_timer := Timer} = State) when is_pid(Pid) ->
%%  lager:debug("chainkeeper check'n'sync ~p finished with reason: ~p", [_Pid, Reason]),
  
  catch erlang:cancel_timer(Timer),
  
  stout:log(ck_fork, [
    {action, stop_check_n_sync},
    {reason, Reason},
    {node, nodekey:node_name()}
  ]),
  
  {noreply, State#{
    sync_lock => null,
    lookaround_timer => setup_timer(lookaround_timer)
  }};


% skip round in case we are syncing
handle_info(lookaround_timer, #{lookaround_timer := Timer, sync_lock := Pid} = State)
  when is_pid(Pid) ->
    catch erlang:cancel_timer(Timer),
  
    stout:log(ck_fork, [
      {node, nodekey:node_name()},
      {action, lookaround_timer_locked}
    ]),
  
    {noreply, State#{
      lookaround_timer => setup_timer(lookaround_timer)
    }};


handle_info(lookaround_timer, #{lookaround_timer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
%%  lager:debug("lookaround_timer"),
  
  Options = #{
    theirnode => nodekey:node_name(),
    mynode => nodekey:node_name()
  },
  chain_lookaround(?TPIC, Options),
  
  {noreply, State#{
    lookaround_timer => setup_timer(lookaround_timer)
  }};

handle_info(_Info, State) ->
  lager:notice("Unknown info  ~p", [_Info]),
  {noreply, State}.


terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

setup_timer(Name) ->
  erlang:send_after(
    ?CHAIN_CHECKOUT_TIMER_FACTOR * 1000 * chainsettings:get_val(blocktime,3),
    self(),
    Name
  ).


%% ------------------------------------------------------------------

%%check_block(#{header := #{height := TheirHeight}} = Blk, Options)
%%  when is_map(Blk) ->
%%    #{hash:=_MyHash, header:=MyHeader} = MyMeta = blockchain:last_meta(),
%%    MyHeight = maps:get(height, MyHeader, 0),
%%    MyTmp = maps:get(temporary, MyMeta, false),
%%    TheirTmp = maps:get(temporary, Blk, false),
%%    TheirHash = get_permanent_hash(Blk),
%%    if
%%      ?isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp) ->
%%        case blockvote:ets_lookup(TheirHash) of
%%          error ->
%%            % hash not found
%%            % todo: detect forks here
%%            % if we can't find _MyHash in the net, fork happened :(
%%            lager:info("Need sync, hash ~p not found in blockvote", [blockchain:blkid(TheirHash)]),
%%            stout:log(ck_sync,
%%              [
%%                {options, Options},
%%                {action, runsync},
%%                {myheight, MyHeight},
%%                {mytmp, MyTmp},
%%                {theirheight, TheirHeight},
%%                {theirhash, TheirHash},
%%                {theirtmp, TheirTmp}
%%              ]),
%%            stout:log(runsync, [ {node, nodekey:node_name()}, {where, chain_keeper} ]),
%%            runsync(),
%%            ok;
%%          _ ->
%%            % hash exist in blockvote
%%            stout:log(ck_sync,
%%              [
%%                {options, Options},
%%                {action, found_in_blockvote},
%%                {myheight, MyHeight},
%%                {mytmp, MyTmp},
%%                {theirheight, TheirHeight},
%%                {theirhash, TheirHash},
%%                {theirtmp, TheirTmp}
%%              ]),
%%            ok
%%        end;
%%      true ->
%%        stout:log(ck_sync,
%%          [sync_needed,
%%            {options, Options},
%%            {action, height_ok},
%%            {myheight, MyHeight},
%%            {mytmp, MyTmp},
%%            {theirheight, TheirHeight},
%%            {theirhash, TheirHash},
%%            {theirtmp, TheirTmp}
%%          ]),
%%%%        check_fork(#{
%%%%          mymeta => MyMeta,
%%%%          theirheight => TheirHeight,
%%%%          theirhash => TheirHash,
%%%%          theirtmp => TheirTmp
%%%%        }, Options),
%%        ok
%%    end,
%%    ok;
%%
%%check_block(Blk, Options) ->
%%  lager:error("invalid block: ~p, extra data: ~p", [Blk, Options]).

%% ------------------------------------------------------------------


%%check_fork2(TPIC, MyMeta, Options) ->
%%  MyPermanentHash = get_permanent_hash(MyMeta),
%%  MyHeader = maps:get(header, MyMeta, #{}),
%%  MyHeight = maps:get(height, MyHeader, 0),
%%  MyTmp = maps:get(temporary, MyMeta, false),
%%
%%  % if MyTmp == false try to find MyPermanentHash in the net
%%  ChainState =
%%    if
%%      MyTmp =:= false ->
%%        case check_block_exist(TPIC, MyPermanentHash) of
%%          {_, 0, _} -> % NotFound, Found, Errors
%%            {fork, hash_not_found_in_the_net2};
%%          _ ->
%%            ok
%%        end;
%%      true ->
%%        ok
%%    end,
%%
%%  stout:log(forkstate, [
%%    {state, ChainState},
%%    {theirnode, maps:get(theirnode, Options, unknown)},
%%    {mynode, maps:get(mynode, Options, unknown)},
%%    {mymeta, MyMeta},
%%    {myheight, MyHeight},
%%    {tmp, MyTmp}
%%  ]),
%%  ChainState.

%% ------------------------------------------------------------------
rollback_block(LoggerOptions) ->
  rollback_block(LoggerOptions, []).

rollback_block(LoggerOptions, RollbackOptions) ->
  case catch gen_server:call(blockchain_updater, rollback) of
    {ok, NewHash} ->
      stout:log(rollback,
        [
          {options, LoggerOptions},
          {action, ok},
          {newhash, NewHash}
        ]),
      lager:notice("rollback new hash ~p", [NewHash]),
      
      case proplists:get_value(no_runsync, RollbackOptions, false) of
        false ->
          stout:log(rollback,
            [
              {options, LoggerOptions},
              {action, runsync},
              {newhash, NewHash}
            ]),
          
          runsync();
        _ ->
          ok
      end,
      {ok, NewHash};
    Err ->
      stout:log(rollback,
        [
          {options, LoggerOptions},
          {action, {error, Err}}
        ]),
      lager:error("rollback error ~p", [Err]),
      
      {error, Err}
  end.


%% ------------------------------------------------------------------

check_fork(
  #{mymeta := MyMeta, theirheight := TheirHeight, theirtmp:= TheirTmp, theirhash := TheirHash},
  Options) ->
  
  #{hash:=MyHash, header:=MyHeader} = MyMeta,
  MyHeight = maps:get(height, MyHeader, 0),
  MyTmp = maps:get(temporary, MyMeta, false),
  MyPermanentHash = get_permanent_hash(MyMeta),
  
  ChainState =
    if
      MyHeight =:= TheirHeight andalso
        MyTmp =:= false andalso
        MyHash =/= TheirHash ->
        case check_block_exist(?TPIC, MyHash) of
          {_, 0, _} -> % NotFound, Found, Errors
            {fork, hash_not_found_in_the_net3};
          _ ->
            {fork, their_hash_possible_fork}
        end;
      MyHeight =:= TheirHeight ->
        ok;
      MyHeight > TheirHeight ->
        case catch blockchain:exists(TheirHash) of
          true ->
            ok;
          timeout ->
            {fork, timeout};
          _ ->
            {fork, hash_not_exists}
        end;
      ?isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp) ->
        case check_block_exist(?TPIC, MyPermanentHash) of
          {_, 0, _} -> % NotFound, Found, Errors
            {fork, hash_not_found_in_the_net};
          _ ->
            ok
        end;
      true ->
        ok
    end,
  
  
  stout:log(forkstate, [
    {state, ChainState},
    {theirnode, maps:get(theirnode, Options, unknown)},
    {mynode, maps:get(mynode, Options, unknown)},
    {mymeta, MyMeta},
    {theirheight, TheirHeight},
    {theirhash, TheirHash},
    {myheight, MyHeight},
    {tmp, MyTmp}
  ]),
  
  % do rollback block after these statuses
  RollBackStatuses = [
    {fork, hash_not_found_in_the_net},
    {fork, hash_not_found_in_the_net3}
  ],
  
  case lists:member(ChainState, RollBackStatuses) of
    true ->
      rollback_block(Options);
    _ ->
      ok
  end,
  
  ChainState.

%% ------------------------------------------------------------------
runsync() ->
  stout:log(ck_fork, [
    {action, runsync_no_list},
    {node, nodekey:node_name()}
  ]),
  
  blockchain_sync ! runsync.

runsync([]) ->
  runsync();

runsync(AssocList) when is_list(AssocList) ->
  stout:log(ck_fork, [
    {action, runsync_assoc_list},
    {assoc_list, resolve_tpic_assoc(AssocList)},
    {node, nodekey:node_name()}
  ]),

  ConvertedAssocList =
    lists:map(
      fun(Assoc) ->
        {Assoc, undefined}
      end,
      AssocList
    ),
  blockchain_sync ! {runsync, ConvertedAssocList}.


%% ------------------------------------------------------------------
get_permanent_hash(Meta) ->
  case maps:get(temporary, Meta, false) of
    Wei when is_number(Wei) ->
      Header = maps:get(header, Meta, #{}),
      maps:get(parent, Header, <<>>);
    _ ->
      maps:get(hash, Meta, <<>>)
end.

%% ------------------------------------------------------------------

is_block_valid(Blk, MinSigns) ->
  CheckFun =
    fun(PubKey, _) ->
      chainsettings:is_our_node(PubKey) =/= false
    end,

  case block:verify(Blk, [hdronly, {checksig, CheckFun}]) of
    {true, {Signs,_}} when length(Signs) >= MinSigns ->
      % valid block, enough signs
      true;
    _ ->
      false
  end.

%% ------------------------------------------------------------------

check_and_sync_runner(TPIC, Options) ->
  stout:log(ck_fork, [
    {action, start_check_n_sync},
    {node, maps:get(mynode, Options, nodekey:node_name())}
  ]),
  
  Pid = erlang:spawn(?MODULE, check_and_sync, [TPIC, Options]),
  erlang:monitor(process, Pid),
  Pid.

%% ------------------------------------------------------------------

check_and_sync(TPIC, Options) ->
  try
    MinSig = maps:get(minsig, Options, chainsettings:get_val(minsig)),
    
    #{hash := MyHash,
      header := #{parent := ParentHash}
    } = MyMeta = blockchain:last_meta(),

    case maps:get(temporary, MyMeta, false) of
      Wei when is_number(Wei) ->
        % Last our block is temporary
        stout:log(ck_fork, [
            {action, have_temporary},
            {node, maps:get(mynode, Options, nodekey:node_name())}
          ]);

%%          throw(finish);
      _ ->
        % we have permanent block
        stout:log(ck_fork, [
          {action, have_permanent},
          {node, maps:get(mynode, Options, nodekey:node_name())},
          {parent, ParentHash}
        ])
    end,

    % In both cases rather we have tmp or permanent block we need look up child of parent
    % Please note, parent hash of tmp block is hash of the last permanent block.
    % Parent hash of permanent block is hash of the previous permanent block.
    Answers =
      tpiccall(
        TPIC,
        <<"blockchain">>,
        #{null => <<"pick_block">>, <<"hash">> => ParentHash, <<"rel">> => child},
        [block, error]
      ),
      
    PushAssoc =
      fun(Hash, Assoc, HashToAssocMap) ->
        Old = maps:get(Hash, HashToAssocMap, []),
        maps:put(Hash, [Assoc | Old], HashToAssocMap)
      end,
    
    FFun =
      fun
        ({Assoc, #{block:=BlkPart}}, {PermHashes, TmpWeis} = Acc) ->
          try
            BinBlock = blockchain:receive_block(Assoc, BlkPart),
            Blk = block:unpack(BinBlock),
            
            case is_block_valid(Blk, MinSig) of
              true ->  % valid block
                Hash = maps:get(hash, Blk, <<>>),
                case maps:get(temporary, Blk, false) of
                  TmpWei when is_number(TmpWei) -> % tmp block
                    {PermHashes, PushAssoc(TmpWei, Assoc, TmpWeis)};
                  _ -> % permanent block
                    {PushAssoc(Hash, Assoc, PermHashes), TmpWeis}
                end;

              _ -> % skip invalid block
                Acc
            end
          catch
            throw:broken ->
              lager:notice("chainkeeper broken block 1"),
              stout:log(ck_fork, [
                {action, broken_block_1},
                {node, maps:get(mynode, Options, nodekey:node_name())},
                {their_node, resolve_tpic_assoc(Assoc)}
              ]),
              Acc;
              
            throw:broken_sync ->
              lager:notice("chainkeeper broken sync 1"),
              stout:log(ck_fork, [
                {action, broken_sync_1},
                {node, maps:get(mynode, Options, nodekey:node_name())},
                {their_node, resolve_tpic_assoc(Assoc)}
              ]),
              Acc
          end;
        ({Assoc, #{error := Error} = Answer}, Acc) ->
          stout:log(ck_fork, [
            {action, sync_error_1},
            {node, maps:get(mynode, Options, nodekey:node_name())},
            {their_node, resolve_tpic_assoc(Assoc)},
            {error, Error},
            {answer, Answer}
          ]),

          lager:info("error from ~p : ~p", [resolve_tpic_assoc(Assoc), Error]),
          Acc;
          
        ({Assoc, Answer}, Acc) ->
          stout:log(ck_fork, [
            {action, unknown_answer_1},
            {node, nodekey:node_name()},
            {their_node, resolve_tpic_assoc(Assoc)},
            {answer, Answer}
          ]),

          lager:info("unexpected answer from ~p : ~p", [resolve_tpic_assoc(Assoc), Answer]),
          Acc
      end,
    
    {PermAssoc, TmpAssoc} = lists:foldl(FFun, {#{}, #{}}, Answers),
    
    PermSize = maps:size(PermAssoc), TmpSize = maps:size(TmpAssoc),
    PermAssocResolved = resolve_assoc_map(PermAssoc),
    TmpAssocResolved = resolve_assoc_map(TmpAssoc),


    SyncPeers =
      if
        PermSize > 0 -> % choose sync peers from permanent hashes
          HashToSync = choose_hash_to_sync(TPIC, maps:keys(PermAssoc), MinSig),

          stout:log(ck_fork, [
            {action, permanent_chosen},
            {node, maps:get(mynode, Options, nodekey:node_name())},
            {hash, HashToSync},
            {perm_assoc, PermAssocResolved},
            {tmp_assoc, TmpAssocResolved}
          ]),
          
          {HashToSync, maps:get(HashToSync, PermAssoc, [])};
        
        TmpSize > 0 -> % choose node with highest temporary
          WidestTmp = lists:max(maps:keys(TmpAssoc)),

          stout:log(ck_fork, [
            {action, tmp_chosen},
            {node, maps:get(mynode, Options, nodekey:node_name())},
            {tmp, WidestTmp},
            {perm_assoc, PermAssocResolved},
            {tmp_assoc, TmpAssocResolved}
          ]),
          
          {WidestTmp, maps:get(WidestTmp, TmpAssoc, [])};

        true ->
          stout:log(ck_fork, [
            {action, cant_find_nodes},
            {node, maps:get(mynode, Options, nodekey:node_name())},
            {perm_assoc, PermAssocResolved},
            {tmp_assoc, TmpAssocResolved}
          ]),
          
          throw(finish)
      end,
    
    case SyncPeers of
      {_, []} -> % can't find associations to sync, give up
        stout:log(ck_fork, [
          {action, empty_list_of_assoc},
          {node, maps:get(mynode, Options, nodekey:node_name())},
          {perm_assoc, PermAssocResolved},
          {tmp_assoc, TmpAssocResolved}
        ]),
        false;
      {TmpWei, AssocToSync} when is_number(TmpWei) -> % sync to higest(widest) tmp block
        stout:log(ck_fork, [
          {action, sync_to_tmp},
          {node, maps:get(mynode, Options, nodekey:node_name())},
          {tmp_wei, TmpWei},
          {assoc_list, resolve_tpic_assoc(AssocToSync)}
        ]),
        runsync(AssocToSync);
  
      {PermHash, AssocToSync} when is_binary(PermHash) -> % sync to permanent block
        if
          PermHash =/= MyHash -> % do rollback because of switching to another branch
            case rollback_block(#{}, [no_runsync]) of
              {error, Err} ->
                lager:error("FIXME: can't rollback block: ~p", [Err]),
                throw(finish);
              {ok, _NewHash} ->
                ok
            end;
          true ->
            ok
        end,
    
        stout:log(ck_fork, [
          {action, sync_to_permanent},
          {node, maps:get(mynode, Options, nodekey:node_name())},
          {myhash, MyHash},
          {their_hash, PermHash},
          {assoc_list, resolve_tpic_assoc(AssocToSync)}
        ]),
  
      runsync(AssocToSync)
    end
  
  catch
    throw:finish ->
      stout:log(ck_fork, [
        {action, stop_ck_fork},
        {node, maps:get(mynode, Options, nodekey:node_name())}
      ]),

      false
  end.


%% ------------------------------------------------------------------

choose_hash_to_sync(_TPIC, [], _MinSig) ->
  <<>>;
  
choose_hash_to_sync(TPIC, Hashes, MinSig) when is_list(Hashes) ->
  SortedHashes = lists:sort(Hashes),
  FFun =
    fun
      (_Hash, Acc) when size(Acc) > 0 ->
        Acc;
      (Hash, Acc) ->
        Answers =
          tpiccall(
            TPIC,
            <<"blockchain">>,
            #{null => <<"pick_block">>, <<"hash">> => Hash, <<"rel">> => child},
            [block, error]
          ),
  
        FindChild =
          fun
            ({_, _}, found = FindChildAcc) -> % don't send requests when found at least one child
              FindChildAcc;
            
            ({_, #{error := _}}, FindChildAcc) -> % skip errors
              FindChildAcc;
            
            ({Assoc, #{block := BlkPart}}, FindChildAcc) -> % receive and check block
              try
                BinBlock = blockchain:receive_block(Assoc, BlkPart),
                Blk = block:unpack(BinBlock),
                  case is_block_valid(Blk, MinSig) of
                    true ->
                      found;
                    _ ->
                      FindChildAcc
                  end

                catch
                  throw:broken ->
                    lager:notice("chainkeeper broken block 1"),
                    stout:log(ck_fork, [
                      {action, broken_block_2},
                      {node, nodekey:node_name()},
                      {their_node, resolve_tpic_assoc(Assoc)}
                    ]),
                    FindChildAcc;
                
                  throw:broken_sync ->
                    stout:log(ck_fork, [
                      {action, broken_sync_2},
                      {node, nodekey:node_name()},
                      {their_node, resolve_tpic_assoc(Assoc)}
                    ]),
                    FindChildAcc
              end
          end,
          case lists:foldl(FindChild, not_found, Answers) of
            found ->
              Hash;
            _ ->
              Acc
          end
    end,

  case lists:foldl(FFun, not_found, SortedHashes) of
    not_found ->
      hd(SortedHashes);
    FoundHashToSync ->
      FoundHashToSync
  end;

choose_hash_to_sync(_, _, _) ->
  <<>>.


%% ------------------------------------------------------------------

chain_lookaround(TPIC, Options) ->
  
  #{hash:=_MyHash,
    header:=MyHeader} = MyMeta = blockchain:last_meta(),

  MyHeight = maps:get(height, MyHeader, 0),
  Tallest = find_tallest(TPIC, chainsettings:get_val(mychain),
              [{minsig, chainsettings:get_val(minsig)}]),
  MyTmp = maps:get(temporary, MyMeta, false),
  
  case Tallest of
    [] ->
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_not_found},
          {myheight, MyHeight},
          {mytmp, MyTmp}
        ]),
  
%%      check_fork2(TPIC, MyMeta, Options),
      check_and_sync_runner(TPIC, Options),
      ok;
    [{Assoc, #{
      last_hash:=Hash,
      last_height:=TheirHeight,
      last_temp := TheirTmp,
      prev_hash := TheirParent
    }} | _]
      when ?isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp) ->
  
      TheirPermanentHash =
        case TheirTmp of
          _ when is_number(TheirTmp) ->
            TheirParent;
          _ ->
            Hash
        end,
      
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_runsync},
          {myheight, MyHeight},
          {mytmp, MyTmp},
          {theirheight, TheirHeight},
          {theirtmp, TheirTmp},
          {theirhash, Hash},
          {theirpermhash, TheirPermanentHash}
        ]),
  
      check_fork(
        #{
          mymeta => MyMeta,
          theirheight => TheirHeight,
          theirhash => TheirPermanentHash,
          theirtmp => TheirTmp
        },
        Options#{
          theirnode => chainkeeper:resolve_tpic_assoc(Assoc)
        }
      ),
      
      runsync(),
      ok;
    _ ->
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_ok},
          {myheight, MyHeight},
          {mytmp, MyTmp}
        ]),
      ok
  end.

%% ------------------------------------------------------------------

discovery(TPIC) ->
  tpiccall(TPIC,
    <<"blockchain">>,
    #{null=><<"sync_request">>},
    [last_hash, last_height, chain, prev_hash, last_temp, lastblk, tempblk]
  ).

%% ------------------------------------------------------------------

find_tallest(TPIC, Chain, Opts) ->
  MinSig = proplists:get_value(minsig, Opts, 3),
  Candidates = discovery(TPIC),
  
  stout:log(sync_candidates, [{candidates, Candidates}]),
  
  CheckedOnly = lists:foldl(
    fun
      ({_Handle, #{last_height:=Hei,
        chain:=C,
        null:=<<"sync_available">>,
        lastblk:=LB} = Info} = E, Acc) when C == Chain andalso Hei > 0 ->
      
        case block:verify(block:unpack(LB), [hdronly]) of
          false ->
            Acc;
          {true, {Valid, _}} when length(Valid) >= MinSig ->
            Tall = case maps:get(last_temp, Info, undefined) of
                     Wid when is_integer(Wid) ->
                       Hei bsl 64 bor Wid;
                     _ ->
                       Hei bsl 64 bor ((1 bsl 64) - 1)
                   end,
            maps:put(Tall, [E | maps:get(Tall, Acc, [])], Acc);
          {true, {_, _}} ->
            Acc
        end;
      (_, Acc) ->
        Acc
    end,
    #{},
    Candidates),
  case maps:size(CheckedOnly) of
    0 ->
      [];
    _ ->
      [HighPri | _] = lists:reverse(lists:sort(maps:keys(CheckedOnly))),
      maps:get(HighPri, CheckedOnly)
  end.

%% ------------------------------------------------------------------

%%tpiccall(Handler, Object, Atoms) ->
%%  tpiccall(tpic, Handler, Object, Atoms).

tpiccall(TPIC, Handler, Object, Atoms) ->
  Res=tpic:call(TPIC, Handler, msgpack:pack(Object)),
  lists:filtermap(
    fun({Peer, Bin}) ->
      case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
        {ok, Decode} ->
          {true, {Peer, Decode}};
        _ -> false
      end
    end, Res).

%% ------------------------------------------------------------------

%%(test_c4n1@pwr)12> TpicCall( <<"blockchain">>, #{null=><<"pick_block">>, <<"hash">>=>LH, <<"rel">>=>self}, [block] ).
%%[{{12,2,<<4,66,196,134,0,0,23,242>>},
%%#{null => block,<<"error">> => <<"noblock">>,
%%<<"req">> =>
%%#{<<"hash">> =>
%%<<212,231,148,165,203,186,209,97,199,164,245,111,18,46,58,
%%183,93,96,176,234,219,229,...>>,
%%<<"rel">> => <<"self">>}}},
%%{{10,2,<<4,66,196,134,0,0,23,242>>},
%%#{null => block,<<"error">> => <<"noblock">>,
%%<<"req">> =>
%%#{<<"hash">> =>
%%<<212,231,148,165,203,186,209,97,199,164,245,111,18,46,58,
%%183,93,96,176,234,219,...>>,
%%<<"rel">> => <<"self">>}}}]
%%

check_block_exist(TPIC, Hash) ->
  Answers =
    tpiccall(
      TPIC,
      <<"blockchain">>,
      #{null=><<"pick_block">>, <<"hash">>=>Hash, <<"rel">>=>self},
      [block]
    ),
  
  Checker =
    fun
      ({_Peer, #{null := block, <<"error">> := <<"noblock">>}}, {NotFound, Found, Errors}) ->
        {NotFound+1, Found, Errors};
      ({_Peer, #{null := block, <<"error">> := _}}, {NotFound, Found, Errors}) ->
        {NotFound, Found, Errors+1};
      (_, {NotFound, Found, Errors}) ->
        {NotFound, Found+1, Errors}
    end,
  
  %% count nodes where this block is absent (answers contains <<"error">> => <<"noblock">>)
  %% Acc = {NotFound, Found, Errors}
  lists:foldl(Checker, {0, 0, 0}, Answers).


%% ------------------------------------------------------------------
resolve_assoc_map(AssocMap) when is_map(AssocMap) ->
  maps:map(
    fun(_Hash, ListOfAssoc) ->
      resolve_tpic_assoc(ListOfAssoc)
    end,
    AssocMap
  ).

%% ------------------------------------------------------------------

resolve_tpic_assoc(AssocList) when is_list(AssocList) ->
  resolve_tpic_assoc(?TPIC, AssocList);

resolve_tpic_assoc({_,_,_} = Assoc) ->
  resolve_tpic_assoc(?TPIC, {_,_,_} = Assoc).


resolve_tpic_assoc(_TPIC, []) ->
  [];

resolve_tpic_assoc(TPIC, [{_,_,_} = H | T ] = _AssocList) ->
  [resolve_tpic_assoc(TPIC, H)] ++ resolve_tpic_assoc(TPIC, T);

resolve_tpic_assoc(TPIC, {_,_,_} = Assoc) ->
  try
    case tpic:peer(TPIC, Assoc) of
      #{authdata:=AuthData} ->
        PubKey =
          case proplists:get_value(pubkey, AuthData, undefined) of
            undefined -> throw(finish);
            ValidPubKey -> ValidPubKey
          end,
        
        case chainsettings:get_setting(chainnodes) of
          {ok, Nodes} ->
            maps:get(PubKey, Nodes, undefined);
          _ -> throw(finish)
        
        end;
        _ ->
          undefined
    end
  catch
      throw:finish  ->
        undefined
  end.
