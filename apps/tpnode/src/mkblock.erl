-module(mkblock).
-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-compile(nowarn_export_all).
%-compile(export_all).
-endif.

-export([start_link/0, hei_and_has/1, decode_tpic_txs/1]).


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
  gen_server:cast(self(), settings),
    {ok, #{
       nodeid=>nodekey:node_id(),
       preptxm=>#{},
       mean_time=>[],
       entropy=>[],
       settings=>#{}
      }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({tpic, From, Bin}, State) when is_binary(Bin) ->
    case msgpack:unpack(Bin) of
        {ok, Struct} ->
            handle_cast({tpic, From, Struct}, State);
        _Any ->
            ?LOG_INFO("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, FromKey, #{
                     null:=<<"lag">>,
                     <<"lbh">>:=LBH
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  ?LOG_DEBUG("MB Node ~s tells I lagging, his h=~w", [Origin, LBH]),
  {noreply, State};


handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
                     <<"hash">> := ParentHash,
                     <<"signed">> := SignedBy
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  ?LOG_DEBUG("MB presig got ~s ~p", [Origin, SignedBy]),
  if Origin==false ->
       {noreply, State};
     true ->
       PreSig=maps:get(presig, State, #{}),
       {noreply,
      State#{
        presig=>maps:put(Origin, {ParentHash, SignedBy}, PreSig)
       }}
  end;

handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"txs">>:=TPICTXs
                    }=Msg}, State)  ->
  TXs=decode_tpic_txs(maps:to_list(TPICTXs)),
  if TXs==[] -> ok;
     true ->
       ?LOG_INFO("Got ~w txs from ~s",
            [
             length(TXs),
             chainsettings:is_our_node(FromKey)
            ])
  end,
  Entropy=maps:get(<<"entropy">>,Msg,undefined),
  Timestamp=maps:get(<<"timestamp">>,Msg,undefined),
  case maps:find(<<"lastblk">>,Msg) of
    error ->
      handle_cast({prepare, FromKey, TXs, undefined, Entropy, Timestamp}, State);
    {ok, Bin} ->
      PreBlk=block:unpack(Bin),
      MS=chainsettings:get_val(minsig),

      {_, _, HeiHas}=hei_and_has(PreBlk),
      CheckFun=fun(PubKey,_) ->
                   chainsettings:is_our_node(PubKey) =/= false
               end,
      case block:verify(PreBlk, [hdronly, {checksig, CheckFun}]) of
        {true, {Sigs,_}} when length(Sigs) >= MS ->
          % valid block, enough sigs
          ?LOG_DEBUG("Got blk from peer ~p",[PreBlk]),
          handle_cast({prepare, FromKey, TXs, HeiHas, Entropy, Timestamp}, State);
        {true, _ } ->
          % valid block, not enough sigs
          {noreply, State};
        false ->
          % invalid block
          {noreply, State}
      end
  end;

handle_cast({prepare, Node, Txs, HeiHash, Entropy, Timestamp},
            #{mean_time:=MT,
              entropy:=Ent,
              preptxm:=PreTXM}=State) ->
  Origin=chainsettings:is_our_node(Node),
  if Origin==false ->
       ?LOG_ERROR("Got txs from bad node ~s",
             [bin2hex:dbin2hex(Node)]),
       {noreply, State};
     true ->
       if Txs==[] -> ok;
        true ->
          ?LOG_INFO("Prepare TXs from node ~s: ~p time ~p hh ~p entropy ~p",
               [ Origin, length(Txs), Timestamp, HeiHash, Entropy])
       end,
       MarkTx =
         fun({TxID, TxBody}) ->
           TxBody1 =
             try
               case TxBody of
%                 #{patch:=_} -> %legacy patch
%                   VerFun =
%                     fun(PubKey) ->
%                       NodeID = chainsettings:is_our_node(PubKey),
%                       is_binary(NodeID)
%                     end,
%                   {ok, Tx1} = settings:verify(TxBody, VerFun),
%                   tx:set_ext(origin, Origin, Tx1);
                 #{hash:=_,
                   header:=_,
                   sign:=_} ->

                   %do nothing with inbound block
                   TxBody;
                 _ ->
                   case tx:verify(TxBody, [{maxsize, txpool:get_max_tx_size()}]) of
                     bad_sig ->
                       throw('bad_sig');
                     {ok, Tx1} ->
                       ?LOG_INFO("TX ok ~p",[TxID]),
                       tx:set_ext(origin, Origin, Tx1)
                   end
               end
             catch
               throw:no_transaction ->
                 ?LOG_INFO("TX absend ~p",[TxID]),
                 null;
               throw:bad_sig ->
                 ?LOG_INFO("TX bad_sig ~p",[TxID]),
                 null;
               _Ec:_Ee:S ->
                 ?LOG_INFO("TX error ~p",[TxID]),
                 %S=erlang:get_stacktrace(),
                 utils:print_error("Error", _Ec, _Ee, S),
                 file:write_file(
                   "tmp/mkblk_badsig_" ++ binary_to_list(nodekey:node_id()),
                   io_lib:format("~p.~n", [TxBody])
                 ),
                 TxBody
             end,
           case TxBody1 of
             null ->
               false;
             _ ->
               {true, {TxID, TxBody1}}
           end
         end,

         Tx2Put=lists:filtermap(MarkTx, Txs),
         MT1=if is_integer(Timestamp) ->
                  [Timestamp|MT];
                true ->
                  MT
             end,
         Ent1=if Txs==[] -> Ent;
                is_binary(Entropy) ->
                  [crypto:hash(sha256,Entropy)|Ent];
                true ->
                   Ent
             end,
       {noreply,
        State#{
          entropy=> Ent1,
          mean_time=> MT1,
          preptxm=> maps:put(HeiHash,
                             maps:get(HeiHash,PreTXM, []) ++ Tx2Put,
                            PreTXM)
         }
       }
  end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    ?LOG_INFO("MB unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(process, #{preptxm := PreTxMap, presig := PreSig, gbpid:=PID}=State) ->
  case is_process_alive(PID) of
    true ->
      ?LOG_INFO("skip PreSig ~p, PreTxMap ~p", [PreSig, PreTxMap]),
      {noreply, State#{preptxm=>#{},
                       presig=>#{}
                      }};
    false ->
      handle_info(process, maps:remove(gbpid, State))
  end;

handle_info(process,
            #{settings:=MySet,
              preptxm:=PreTXM,
              mean_time:=MT,
              entropy:=Ent}=State) ->
  PreSig=maps:get(presig, State, #{}),
  GBPID=mkblock_genblk:spawn_generate(MySet, PreTXM, PreSig, MT, Ent),
  {noreply, State#{preptxm=>#{},
    presig=>#{},
    mean_time=>[],
    entropy=>[],
    gbpid=>GBPID
  }};

handle_info(process, State) ->
    ?LOG_NOTICE("MKBLOCK Blocktime, but I not ready"),
    {noreply, load_settings(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

load_settings(State) ->
    OldSettings=maps:get(settings, State, #{}),
    MyChain=blockchain:chain(),
    AE=chainsettings:get_val(<<"allowempty">>),
    NodeName=nodekey:node_name(),
    State#{
      settings=>
      maps:merge(
        OldSettings,
        #{ae=>AE, mychain=>MyChain, nodename=>NodeName}
      )
    }.

%% ------------------------------------------------------------------

%% Function gets list of tuples with TX IDs and bodies ({TXID, TXBody}).
%% Body can be null, in such case this function tries to retrive it from
%% tx strorage.
-spec decode_tpic_txs(TXs :: [{binary(), 'null' | binary()}]) -> [{binary(), map()}].
decode_tpic_txs(TXs) ->
  lists:map(
    fun
      % get pre synced transaction body from txstorage
      ({TxID, null}) ->
        TxBody =
          case tpnode_txstorage:get_unpacked(TxID) of
            {TxID, Tx} when is_map(Tx) ->
              Tx;
            error ->
              ?LOG_ERROR("can't get body for tx ~p", [TxID]),
              null;
            _Any ->
              ?LOG_ERROR("can't get body for tx ~p unknown response ~p", [TxID, _Any]),
              null
          end,
        {TxID, TxBody};
      
      % unpack transaction body
      ({TxID, Tx}) when is_binary(Tx) ->
        try
        Unpacked = tx:unpack(Tx),
%%      ?LOG_INFO("debug tx unpack: ~p", [Unpacked]),
        {TxID, Unpacked}
        catch Ec:Ee ->
                ?LOG_ERROR("TX ~p decode error ~p:~p",[TxID,Ec,Ee]),
                {TxID, null}
        end;
      ({TxID, Tx}) when is_map(Tx) ->
        {TxID, Tx}
    end,
    TXs
  ).

hei_and_has(B) ->
  PTmp=maps:get(temporary,B,false),

  case PTmp of false ->
                 ?LOG_DEBUG("Prev block is permanent, make child"),
                 #{header:=#{height:=Last_Height1}, hash:=Last_Hash1}=B,
                 {Last_Height1,
                  Last_Hash1,
                  <<(bnot Last_Height1):64/big,Last_Hash1/binary>>};
               X when is_integer(X) ->
                 ?LOG_DEBUG("Prev block is temporary, make replacement"),
                 #{header:=#{height:=Last_Height1, parent:=Last_Hash1}}=B,
                 {Last_Height1-1,
                  Last_Hash1,
                  <<(bnot Last_Height1-1):64/big,Last_Hash1/binary>>}
  end.

