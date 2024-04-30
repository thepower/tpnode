-module(blockvote).
-include("include/tplog.hrl").

-compile([{parse_transform, stout_pt}]).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% cleanup blockvote state in 5 blocktime interval
-define(BV_CLEANUP_TIMER_FACTOR, 5).


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, get_state/0]).
-export([ets_init/1, ets_cleanup/2, ets_lookup/2, ets_lookup/1, ets_put/2]).

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
    ets_init(),
    self() ! init,
    {ok, undefined}.

handle_call(_, _From, undefined) ->
    {reply, notready, undefined};

handle_call(status, _From, #{candidatesig:=Candidatesig, candidates:=Candidates}=State) ->
  {reply, #{
     sig=>maps:size(Candidatesig),
     block=>maps:size(Candidates),
     candidates =>[ hex:encode(K) || K<-maps:keys(Candidates) ],
     signatures => lists:reverse(
                     maps:fold(
                       fun(K,V,A) ->
                           [
                            [block:blkid(K),
                             [chainsettings:is_our_node(N) || N<- maps:keys(V) ]
                            ]
                            |A]
                       end,
                       [],
                       Candidatesig))
    }, State};

handle_call({candidate, Hash}, _From, #{candidates:=Cand}=State) ->
    {reply, maps:get(Hash,Cand,undefined), State};

handle_call({signatures, Hash}, _From, #{candidatesig:=Cand}=State) ->
    {reply, maps:get(Hash,Cand,#{}), State};

handle_call(candidates, _From, #{candidates:=Cand}=State) ->
    {reply, Cand, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_, undefined) ->
    {noreply, undefined};

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin) of
        {ok, Struct} ->
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            ?LOG_INFO("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, _From, #{
                     null:=<<"blockvote">>,
                     <<"chain">>:=MsgChain,
                     <<"hash">> := BlockHash,
                     %<<"n">> := _OriginNode,
                     <<"sign">> := Sigs
                    }},
            #{mychain:=MyChain}=State) when MyChain==MsgChain ->
    LD = << 64 , (os:system_time(microsecond)):64/big >>,
    Sigs2 = [ bsig:set_localdata(E, LD) || E <- Sigs ],
    handle_cast({signature, BlockHash, Sigs2}, State);

handle_cast({tpic, _From, #{
                     null:=<<"blockvote">>,
                     <<"chain">>:=MsgChain,
                     <<"hash">> := BlockHash,
                     %<<"n">> := _OriginNode,
                     <<"sign">> := _Sigs
                    }=Msg},
            #{mychain:=MyChain}=State) when MyChain=/=MsgChain ->
    ?LOG_INFO("BV ~p",[Msg]),
    ?LOG_INFO("BV sig for blk ~s from other chain ~p, my ~p origin ~s",
              [blockchain:blkid(BlockHash),MsgChain, MyChain, maps:get(<<"n">>,Msg,<<"unkn0wn">>)]),
    {noreply, State};

handle_cast({signature, BlockHash, Sigs}=WholeSig,
            #{lastblock:=#{hash:=LBH}}=State) when LBH==BlockHash->
    ?LOG_DEBUG("BV Got extra sig for ~s ~p", [blkid(BlockHash), WholeSig]),
    %?LOG_DEBUG("BV Got extra sig for ~s", [blkid(BlockHash)]),

    stout:log(
      bv_gotsig,
      [{hash, BlockHash}, {sig, Sigs}, {extra, true}, {node_name, nodekey:node_name()}]
     ),

    blockchain_updater:new_sig(BlockHash, Sigs),
    {noreply, State};


handle_cast({signature, BlockHash, Sigs},
    #{candidatesig:=Candidatesig, candidatets:=CandidateTS}=State) ->
    ?LOG_DEBUG("BV Got sig for ~s", [blkid(BlockHash)]),
    CSig0=maps:get(BlockHash, Candidatesig, #{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    %?LOG_DEBUG("BV S CS2 ~p", [maps:keys(CSig)]),

    stout:log(bv_gotsig,
      [{hash, BlockHash}, {sig, Sigs}, {candsig, Candidatesig}, {extra, false}, {node_name, nodekey:node_name()}]),

    State2=State#{
      candidatesig=>maps:put(BlockHash, CSig, Candidatesig),
      candidatets => maps:put(os:system_time(microsecond), BlockHash, CandidateTS)
    },
    {noreply, is_block_ready(BlockHash, State2)};

handle_cast({new_block, Blk, PID}, State) ->
  handle_cast({new_block, Blk, PID, #{}}, State);

handle_cast({new_block, #{hash:=BlockHash, header:=#{chain:=Chain}, sign:=Sigs, txs:=Txs}=Blk, _PID, Extra},
            #{ candidates:=Candidates,
               candidatesig:=Candidatesig,
               candidatets := CandidateTS,
               extras := Extras
             }=State) ->

    #{hash:=LBlockHash}=LastBlock=blockchain:last_meta(),
    Height=maps:get(height, maps:get(header, Blk)),
    ?LOG_INFO("BV New block (~p/~p) arrived (~s/~s)",
               [
                Height,
                maps:get(height, maps:get(header, LastBlock)),
                blkid(BlockHash),
                blkid(LBlockHash)
               ]),
    CSig0=maps:get(BlockHash, Candidatesig, #{}),
    CSig=checksig(BlockHash, Sigs, CSig0),
    %?LOG_DEBUG("BV N CS2 ~p", [maps:keys(CSig)]),

    stout:log(
      bv_gotblock,
      [
        {hash, BlockHash},
        {sig, Sigs},
        {node_name, nodekey:node_name()},
        {height, Height},
        {txs_cnt, length(Txs)},
        {tmp, maps:get(temporary, Blk, -1)}
      ]),

    ets_put([BlockHash]),

    State2=
      State#{
        candidatesig=>maps:put(BlockHash, CSig, Candidatesig),
        candidates => maps:put(BlockHash, Blk, Candidates),
        mychain => Chain,
        candidatets => maps:put(os:system_time(microsecond), BlockHash, CandidateTS),
        extras => maps:put(BlockHash, Extra, Extras)
      },
    {noreply, is_block_ready(BlockHash, State2)};

handle_cast(_Msg, State) ->
    ?LOG_INFO("BV Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info({check,BlockHash},
            #{lastblock:=#{hash:=LBH}}=State) when LBH==BlockHash->
  {noreply, State};

handle_info({check,BlockHash}, State) ->
  case maps:is_key(BlockHash, maps:get(candidates, State)) of
    false ->
      ?LOG_INFO("Probably peers went ahead, block ~s not found. checksync",[blkid(BlockHash)]),
      blockchain_sync ! checksync;
    true ->
      ignore
  end,
  {noreply, State};

handle_info(cleanup, State) ->
    ets_cleanup(0),
    {noreply, State};

handle_info(cleanup_timer,
  #{candidatets := CandTS,
    candidates := Candidates,
    candidatesig := CandidateSig,
    extras := Extras,
    blocktime := BlockTime,
    cleanup_timer := Timer} = State) ->

  catch erlang:cancel_timer(Timer),

  TimeoutSec = BlockTime + ?BV_CLEANUP_TIMER_FACTOR,

  {NewCandTS, NewCandidates, NewCandidateSig, NewExtras} =
    remove_expired_candidates(CandTS, Candidates, CandidateSig, Extras, TimeoutSec),

%%  ?LOG_INFO("BV cleaned ~p expired candidates", [
%%    maps:size(CandidateSig) - maps:size(NewCandidateSig)
%%  ]),

  {noreply, State#{
    candidatets => NewCandTS,
    candidates => NewCandidates,
    candidatesig => NewCandidateSig,
    extras => NewExtras,
    cleanup_timer => setup_timer(cleanup_timer, BlockTime)
  }};


handle_info(init, undefined) ->
    #{hash:=LBlockHash}=LastBlock=blockchain:last_meta(),
    ?LOG_INFO("BV My last block hash ~s",
               [bin2hex:dbin2hex(LBlockHash)]),
    Res = #{
      candidatesig => #{},
      candidates=>#{},
      candidatets=>#{},
      extras=>#{},
      cleanup_timer => setup_timer(cleanup_timer, 5),
      lastblock=>LastBlock
    },
    {noreply, load_settings(Res)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ?LOG_ERROR("Terminate blockvote ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

blkid(<<X:8/binary, _/binary>>) ->
    bin2hex:dbin2hex(X).

%% ------------------------------------------------------------------

checksig(BlockHash, Sigs, Acc0) ->
    lists:foldl(
      fun(Signature, Acc) ->
              case bsig:checksig1(BlockHash, Signature) of
                  {true, #{extra:=Xtra}=US} ->
                      Pub=proplists:get_value(pubkey, Xtra),
                      ?LOG_DEBUG("BV ~s Check sig ~s", [
                                      blkid(BlockHash),
                                      bin2hex:dbin2hex(Pub)
                                     ]),
            case maps:is_key(Pub, Acc) of
              true -> Acc;
              false ->
                maps:put(Pub, US, Acc)
            end;
                  false ->
                      Acc
              end
      end, Acc0, Sigs).

%% ------------------------------------------------------------------

is_block_ready(BlockHash, #{extras:=Extras}=State) ->
  try
    MinSig=maps:get(minsig, State, 2),
    T0=erlang:system_time(),
    Sigs=try
         maps:get(BlockHash, maps:get(candidatesig, State))
       catch _:_ ->
             throw({notready, nosig})
       end,
      case maps:is_key(BlockHash, maps:get(candidates, State)) of
      false ->
        case maps:size(Sigs) >= MinSig of
          true ->
            erlang:send_after(300,self(),{check,BlockHash}),
            throw({notready, nocand1});
          false ->
            throw({notready, {nocand, maps:size(Sigs), MinSig}})
        end;
      true ->
        Blk0=maps:get(BlockHash, maps:get(candidates, State)),
        Blk1=Blk0#{sign=>maps:values(Sigs)},
        {true, {Success, _}}=block:verify(Blk1),
        T1=erlang:system_time(),
        Txs=maps:get(txs, Blk0, []),
        ?LOG_DEBUG("TODO: Check keys ~p of ~p", [length(Success), MinSig]),
        if length(Success)<MinSig ->
             ?LOG_INFO("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)",
                  [maps:get(height, maps:get(header, Blk0)),
                   blkid(BlockHash),
                   length(Txs),
                   length(Success),
                   (T1-T0)/1000000]),
             throw({notready, minsig});
           true ->
             ?LOG_DEBUG("BV New block ~w arrived ~s, txs ~b, verify ~w (~.3f ms)",
                  [maps:get(height, maps:get(header, Blk0)),
                   blkid(BlockHash),
                   length(Txs),
                   length(Success),
                   (T1-T0)/1000000])
        end,
        Blk=Blk0#{sign=>Success},
        %enough signs. use block
        T3=erlang:system_time(),
        Height=maps:get(height, maps:get(header, Blk)),

        stout:log(bv_ready,
          [
            {hash, BlockHash},
            {height, Height},
            {node, nodekey:node_name()},
            {header, maps:get(header, Blk)}
          ]),

        ?LOG_INFO("BV enough confirmations. Installing new block ~s h= ~b (~.3f ms)",
                   [blkid(BlockHash),
                    Height,
                    (T3-T0)/1000000
                   ]),

        blockchain_updater:new_block(Blk),
        Extra=maps:get(BlockHash, Extras, #{}),
        if Extra =/= #{} andalso Extra =/= #{log=>[]} ->
             ?LOG_INFO("Extra for blk ~w ~s: ~p",[Height, blkid(BlockHash), maps:keys(Extra)]);
           true -> ok
        end,
        case maps:is_key(log, Extra) of
          false -> ok;
          true ->
            case maps:is_key(temporary, Blk) of
              true ->
                ignore;
              false ->
                ?LOG_INFO("Store log for block ~w:~s",[Height, hex:encode(BlockHash)]),
                Logs=maps:get(log, Extra),
                logs_db:put(BlockHash, Height, Logs),
                if Logs==[] -> ok;
                   true ->
                     gen_server:cast(tpnode_ws_dispatcher,
                                {new_logs,
                                 BlockHash,
                                 Height,
                                 Logs
                                })
                end
            end
        end,

        self() ! cleanup,

        State#{
          lastblock=> Blk,
          candidates=>#{},
          candidatesig=>#{},
          candidatets => #{},
          extras => #{}
         }
    end
  catch throw:{notready, Where} ->
        ?LOG_INFO("Not ready ~s ~p", [blkid(BlockHash), Where]),
        State;
      Ec:Ee:S ->
        ?LOG_ERROR("BV New_block error ~p:~p", [Ec, Ee]),
        lists:foreach(
        fun(Se) ->
            ?LOG_ERROR("at ~p", [Se])
        end, S),
        State
  end.

%% ------------------------------------------------------------------

load_settings(State) ->
  {ok, MyChain} = chainsettings:get_setting(mychain),
  MinSig=chainsettings:get_val(minsig,1000),
  LastBlock=blockchain:last_meta(),
  ?LOG_INFO("BV My last block hash ~s",
    [bin2hex:dbin2hex(maps:get(hash, LastBlock))]),

  State#{
    mychain=>MyChain,
    minsig=>MinSig,
    lastblock=>LastBlock,
    blocktime => chainsettings:get_val(blocktime, 3)
  }.

%% ------------------------------------------------------------------

get_state() ->
  gen_server:call(?MODULE, state).


%% ------------------------------------------------------------------

ets_init() ->
  ets_init(?MODULE).

ets_init(EtsTableName) ->
  Table = ets:new(EtsTableName, [named_table, protected, set, {read_concurrency, true}]),
  ?LOG_INFO("created ets table ~p", [Table]).

%% ------------------------------------------------------------------

ets_put(Keys) ->
  ets_put(?MODULE, Keys).

ets_put(EtsTableName, Keys) when is_list(Keys) ->
  Now = os:system_time(seconds),
  ets:insert(EtsTableName, [{Key, Now} || Key <- Keys]),
  ok.

%% ------------------------------------------------------------------

ets_cleanup(TimeoutSec) ->
  ets_cleanup(?MODULE, TimeoutSec).

ets_cleanup(EtsTableName, TimeoutSec) when is_integer(TimeoutSec) ->
  Expiration = os:system_time(seconds) - TimeoutSec,
  _Deleted = ets:select_delete(
    EtsTableName,
    [{{'_', '$1'}, [{'<', '$1', Expiration}], [true]}]
  ),
  ok.

%% ------------------------------------------------------------------
ets_lookup(Key) ->
  ets_lookup(?MODULE, Key).

ets_lookup(EtsTableName, Key) ->
  case ets:lookup(EtsTableName, Key) of
    [{Key, Timestamp}] ->
      {ok, Timestamp};
    [] ->
      error
  end.

%% ------------------------------------------------------------------

setup_timer(Name, Blocktime) ->
  erlang:send_after(
    ?BV_CLEANUP_TIMER_FACTOR * 1000 * Blocktime,
    self(),
    Name
  ).


%% ------------------------------------------------------------------

remove_expired_candidates(CandTS, Candidates, CandidateSig, Extras, TimeoutSec) ->
  Timeout = os:system_time(microsecond) - TimeoutSec * 1000000,

  maps:fold(
    fun
      (SavedTS, Hash, {TS, Cand, Sigs, Ex} = _Acc) when SavedTS < Timeout ->
        {
          maps:remove(SavedTS, TS),
          maps:remove(Hash, Cand),
          maps:remove(Hash, Sigs),
          maps:remove(Hash, Ex)
        };

      (_K, _V, Acc) ->
        Acc
    end,
    {CandTS, Candidates, CandidateSig, Extras},
    CandTS
  ).
