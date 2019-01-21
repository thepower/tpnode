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

-export([check_fork2/3, get_permanent_hash/1, discovery/1, find_tallest/3]).

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
    ?CHAIN_CHECKOUT_TIMER_FACTOR * 1000 * chainsettings:get_val(blocktime),
    self(),
    Name
  ).


%% ------------------------------------------------------------------

check_block(#{header := #{height := TheirHeight}} = Blk, Options)
  when is_map(Blk) ->
    #{hash:=_MyHash, header:=MyHeader} = MyMeta = blockchain:last_meta(),
    MyHeight = maps:get(height, MyHeader, 0),
    MyTmp = maps:get(temporary, MyMeta, false),
    TheirTmp = maps:get(temporary, Blk, false),
    TheirHash = get_permanent_hash(Blk),
    if
      ?isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp) ->
        case blockvote:ets_lookup(TheirHash) of
          error ->
            % hash not found
            % todo: detect forks here
            % if we can't find _MyHash in the net, fork happened :(
            lager:info("Need sync, hash ~p not found in blockvote", [blockchain:blkid(TheirHash)]),
            stout:log(ck_sync,
              [
                {options, Options},
                {action, runsync},
                {myheight, MyHeight},
                {mytmp, MyTmp},
                {theirheight, TheirHeight},
                {theirhash, TheirHash},
                {theirtmp, TheirTmp}
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
                {mytmp, MyTmp},
                {theirheight, TheirHeight},
                {theirhash, TheirHash},
                {theirtmp, TheirTmp}
              ]),
            ok
        end;
      true ->
        stout:log(ck_sync,
          [sync_needed,
            {options, Options},
            {action, height_ok},
            {myheight, MyHeight},
            {mytmp, MyTmp},
            {theirheight, TheirHeight},
            {theirhash, TheirHash},
            {theirtmp, TheirTmp}
          ]),
        check_fork(#{
          mymeta => MyMeta,
          theirheight => TheirHeight,
          theirhash => TheirHash,
          theirtmp => TheirTmp
        }, Options),
        ok
    end,
    ok;

check_block(Blk, Options) ->
  lager:error("invalid block: ~p, extra data: ~p", [Blk, Options]).

%% ------------------------------------------------------------------


check_fork2(TPIC, MyMeta, Options) ->
  MyPermanentHash = get_permanent_hash(MyMeta),
  MyHeader = maps:get(header, MyMeta, #{}),
  MyHeight = maps:get(height, MyHeader, 0),
  MyTmp = maps:get(temporary, MyMeta, false),
  
  % if MyTmp == false try to find MyPermanentHash in the net
  ChainState =
    if
      MyTmp =:= false ->
        case check_block_exist(TPIC, MyPermanentHash) of
          fork ->
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
    {myheight, MyHeight},
    {tmp, MyTmp}
  ]),
  ChainState.

%% ------------------------------------------------------------------

check_fork(#{mymeta := MyMeta, theirheight := TheirHeight, theirhash := TheirHash}, Options) ->
  #{hash:=MyHash, header:=MyHeader} = MyMeta,
  MyHeight = maps:get(height, MyHeader, 0),
  MyTmp = maps:get(temporary, MyMeta, false),
  
  ChainState =
    if
      MyHeight =:= TheirHeight andalso
        MyTmp =:= false andalso
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
    {tmp, MyTmp}
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
get_permanent_hash(Meta) ->
  case maps:get(temporary, Meta, false) of
    false ->
      maps:get(hash, Meta, <<>>);
    _ ->
      Header = maps:get(header, Meta, #{}),
      maps:get(parent, Header, <<>>)
  end.

%% ------------------------------------------------------------------

chain_lookaround(TPIC, Options) ->
  
  #{hash:=_MyHash,
    header:=MyHeader} = MyMeta = blockchain:last_meta(),
  
  MyHeight = maps:get(height, MyHeader, 0),
  Tallest = find_tallest(TPIC, chainsettings:get_val(mychain), []),
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
  
      check_fork2(TPIC, MyMeta, Options),
      ok;
    [{_, #{
      last_hash:=Hash,
      last_height:=TheirHeight,
      last_temp := TheirTmp,
      prev_hash := TheirParent
    }} | _]
      when ?isTheirHigher(TheirHeight, MyHeight, TheirTmp, MyTmp) ->
  
      TheirPermanentHash =
        case TheirTmp of
          false ->
            Hash;
          _ ->
            TheirParent
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
      
      check_fork(#{
        mymeta => MyMeta,
        theirheight => TheirHeight,
        theirhash => TheirPermanentHash,
        theirtmp => TheirTmp
      }, Options),
      
      blockchain ! runsync,
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
      (_, exists) ->
        exists;
      ({_Peer, #{null := block, <<"error">> := <<"noblock">>}}, Acc) ->
        Acc;
      (_, _) ->
        exists
    end,
  
  %% it's fork if all answers contains <<"error">> => <<"noblock">>
  lists:foldl(Checker, fork, Answers).


%% ------------------------------------------------------------------
