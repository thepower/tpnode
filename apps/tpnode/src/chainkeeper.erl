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


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

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
      lookaround_timer => chainsettings:get_val(lookaround_timer)
    }
  }.

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast({possible_fork, #{mymeta := LastMeta, hash := MissingHash}}, State) ->
  
  stout:log(forkstate, [
    {state, possible_fork},
    {last_meta, LastMeta},
    {hash, MissingHash},
    {mynode, nodekey:node_name()}
  ]),
  
  {noreply, State};


handle_cast({tpic, NodeName, _From, Payload}, #{lookaround_timer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
  Blk =
    try
      case msgpack:unpack(Payload, [{known_atoms, []}]) of
        {ok, Decode} when is_map(Decode) ->
          case Decode of
            #{null := <<"block_installed">>,<<"blk">> := ReceivedBlk} ->
              lager:info("got ck_beacon from ~s, block: ~p", [NodeName, Payload]),
              block:unpack(ReceivedBlk);
            _ ->
              lager:info("got ck_beacon from ~s, unpacked payload: ~p", [NodeName, Decode]),
              #{}
          end;
        _ ->
          lager:error("can't decode msgpack: ~p", [Payload]),
          #{}
      end
    catch
      Ec:Ee ->
        utils:print_error(
          "msgpack decode error/can't unpack block", Ec, Ee, erlang:get_stacktrace()),
        #{}
    end,
  
  lager:info("Blk: ~p", [Blk]),
  
  stout:log(ck_beacon,
    [
      {node, NodeName},
      {block, Blk}
    ]
  ),
  
  check_block(
    Blk,
    #{
      theirnode => NodeName,
      mynode => nodekey:node_name()
    }
  ),
  
  {noreply, State#{
    lookaround_timer => setup_timer(lookaround_timer)
  }};

handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(lookaround_timer, #{lookaround_timer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
  lager:debug("lookaround_timer"),
  
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
    ?CHAIN_CHECKOUT_TIMER_FACTOR * 1000 * chainsettings:get_val(blocktime),
    self(),
    Name
  ).


%% ------------------------------------------------------------------

check_block(#{hash:=Hash, header := #{height := TheirHeight}} = Blk, Options)
  when is_map(Blk) ->
    #{hash:=_MyHash,
      header:=MyHeader} = MyMeta = blockchain:last_meta(),
    MyHeight = maps:get(height, MyHeader, 0),
    if
      TheirHeight > MyHeight ->
        case blockvote:ets_lookup(Hash) of
          error ->
            % hash not found
            % todo: detect forks here
            % if we can't find _MyHash in the net, fork happened :(
            lager:info("Need sync, hash ~p not found in blockvote", [blockchain:blkid(Hash)]),
            stout:log(ck_sync,
              [
                {options, Options},
                {action, runsync},
                {myheight, MyHeight},
                {theirheight, TheirHeight},
                {theirhash, Hash}
                
              ]),
            stout:log(runsync, [ {node, nodekey:node_name()}, {where, chain_keeper} ]),
            blockchain ! runsync,
            ok;
          _ ->
            % hash exist in blockvote
            stout:log(ck_sync,
              [
                {options, Options},
                {action, found_in_blockvote},
                {myheight, MyHeight},
                {theirheight, TheirHeight},
                {theirhash, Hash}
    
              ]),
            ok
        end;
      true ->
        stout:log(ck_sync,
          [sync_needed,
            {options, Options},
            {action, height_ok},
            {myheight, MyHeight},
            {theirheight, TheirHeight},
            {theirhash, Hash}
          ]),
        check_fork(#{
          mymeta => MyMeta,
          theirheight => TheirHeight,
          theirhash => Hash
        }, Options),
        ok
    end,
    ok;

check_block(Blk, Options) ->
  lager:error("invalid block: ~p, extra data: ~p", [Blk, Options]).

%% ------------------------------------------------------------------

check_fork(#{mymeta := MyMeta, theirheight := TheirHeight, theirhash := TheirHash}, Options) ->
  #{hash:=MyHash, header:=MyHeader} = MyMeta,
  MyHeight = maps:get(height, MyHeader, 0),
  Tmp = maps:get(temporary, MyMeta, false),
  
  ChainState =
    if
      MyHeight =:= TheirHeight andalso
        Tmp =:= false andalso
        MyHash =/= TheirHash ->
        {fork, hash_not_equal};
      MyHeight =:= TheirHeight ->
        ok;
      MyHeight < TheirHeight ->
        case blockchain:exists(TheirHash) of
          true ->
            ok;
          _ ->
            {fork, hash_not_exists}
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
    {tmp, Tmp}
  ]),
  
  ChainState.
  
  
  



%% ------------------------------------------------------------------


%%tpiccall(Handler, Object, Atoms) ->
%%  Res = tpic:call(tpic, Handler, msgpack:pack(Object)),
%%  lists:filtermap(
%%    fun({Peer, Bin}) ->
%%      case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
%%        {ok, Decode} ->
%%          {true, {Peer, Decode}};
%%        _ -> false
%%      end
%%    end, Res).
%%

%% ------------------------------------------------------------------

chain_lookaround(TPIC, Options) ->
  
  #{hash:=_MyHash,
    header:=MyHeader} = MyMeta = blockchain:last_meta(),
  
  MyHeight = maps:get(height, MyHeader, 0),
  Tallest = find_tallest(TPIC, chainsettings:get_val(mychain), []),
  
  case Tallest of
    [] ->
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_not_found},
          {myheight, MyHeight}
        ]),
      ok;
    [{_, #{
      last_hash:=Hash,
      last_height:=TheirHeight
    }} | _] when TheirHeight > MyHeight ->
      
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_runsync},
          {myheight, MyHeight},
          {theirheight, TheirHeight},
          {theirhash, Hash}
        ]),
      
      check_fork(#{
        mymeta => MyMeta,
        theirheight => TheirHeight,
        theirhash => Hash
      }, Options),
      
      blockchain ! runsync,
      ok;
    _ ->
      stout:log(ck_sync,
        [
          {options, Options},
          {action, lookaround_ok},
          {myheight, MyHeight}
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
  
  stout:log(sync_candidates, {candidates, Candidates}),
  
  CheckedOnly = lists:foldl(
    fun({_Handle, #{last_height:=Hei,
      chain:=C,
      null:=<<"sync_available">>,
      lastblk:=LB} = Info} = E, Acc) when C == Chain ->
      case block:verify(block:unpack(LB), [hdronly]) of
        false ->
          Acc;
        {true, {Valid, _}} when length(Valid) >= MinSig ->
          Tall = case maps:get(last_temp, Info, undefined) of
                   Wid when is_integer(Wid) ->
                     Hei bsl 64 bor Wid;
                   _ ->
                     Hei bsl 64
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
      [HighPri | _] = lists:reverse(lists:keysort(1, maps:keys(CheckedOnly))),
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

