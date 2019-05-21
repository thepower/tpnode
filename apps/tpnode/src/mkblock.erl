-module(mkblock).
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

-export([start_link/0, hei_and_has/1]).


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
    {ok, #{
       nodeid=>nodekey:node_id(),
       preptxm=>#{},
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
            lager:info("Can't decode TPIC ~p", [_Any]),
            {noreply, State}
    end;

handle_cast({tpic, FromKey, #{
                     null:=<<"lag">>,
                     <<"lbh">>:=LBH
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  lager:debug("MB Node ~s tells I lagging, his h=~w", [Origin, LBH]),
  {noreply, State};


handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
                     <<"hash">> := ParentHash,
                     <<"signed">> := SignedBy
                    }}, State)  ->
  Origin=chainsettings:is_our_node(FromKey),
  lager:debug("MB presig got ~s ~p", [Origin, SignedBy]),
  if Origin==false ->
       {noreply, State};
     true ->
       PreSig=maps:get(presig, State, #{}),
       {noreply,
      State#{
        presig=>maps:put(Origin, {ParentHash, SignedBy}, PreSig)
       }}
  end;

handle_cast({tpic, Origin, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"txs">>:=TPICTXs
                    }=Msg}, State)  ->
  TXs=decode_tpic_txs(TPICTXs),
  if TXs==[] -> ok;
     true ->
       lager:info("Got txs from ~s: ~p",
            [
             chainsettings:is_our_node(Origin),
             TXs
            ])
  end,
  case maps:find(<<"lastblk">>,Msg) of
    error ->
      handle_cast({prepare, Origin, TXs, undefined}, State);
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
          lager:info("Got blk from peer ~p",[PreBlk]),
          handle_cast({prepare, Origin, TXs, HeiHas}, State);
        {true, _ } ->
          % valid block, not enough sigs
          {noreply, State};
        false ->
          % invalid block
          {noreply, State}
      end
  end;

handle_cast({prepare, Node, Txs, HeiHash}, #{preptxm:=PreTXM}=State) ->
  Origin=chainsettings:is_our_node(Node),
  if Origin==false ->
       lager:error("Got txs from bad node ~s",
             [bin2hex:dbin2hex(Node)]),
       {noreply, State};
     true ->
       if Txs==[] -> ok;
        true ->
          lager:info("TXs from node ~s: ~p",
               [ Origin, length(Txs) ])
       end,
       MarkTx =
         fun({TxID, TxB0}) ->
           % get transaction body from storage
           TxB =
             try
               case TxB0 of
                 {TxID, null} ->
                   case txstorage:get_tx(TxID) of
                     {ok, {TxID, TxBody, _Nodes}} ->
                       {TxID, TxBody}; % got tx body from txstorage
                     _ ->
                       {TxID, null} % error
                   end;
                 _OtherTx ->
                   _OtherTx  % transaction with body or invalid transaction
               end
             catch _Ec0:_Ee0 ->
               utils:print_error("Error", _Ec0, _Ee0, erlang:get_stacktrace()),
               TxB0
             end,

           TxB1 =
             try
               case TxB of
                 #{patch:=_} ->
                   VerFun =
                     fun(PubKey) ->
                       NodeID = chainsettings:is_our_node(PubKey),
                       is_binary(NodeID)
                     end,
                   {ok, Tx1} = settings:verify(TxB, VerFun),
                   tx:set_ext(origin, Origin, Tx1);

                 #{hash:=_,
                   header:=_,
                   sign:=_} ->

                   %do nothing with inbound block
                   TxB;

                 _ ->
                   {ok, Tx1} = tx:verify(TxB, [{maxsize, txpool:get_max_tx_size()}]),
                   tx:set_ext(origin, Origin, Tx1)
               end
             catch
               throw:no_transaction ->
                 null;
               _Ec:_Ee ->
                 utils:print_error("Error", _Ec, _Ee, erlang:get_stacktrace()),
                 file:write_file(
                   "tmp/mkblk_badsig_" ++ binary_to_list(nodekey:node_id()),
                   io_lib:format("~p.~n", [TxB])
                 ),
                 TxB
             end,
           case TxB1 of
             null ->
               false;
             _ ->
               {true, {TxID, TxB1}}
           end
         end,

         Tx2Put=lists:filtermap(MarkTx, Txs),
       {noreply,
        State#{
          preptxm=> maps:put(HeiHash,
                             maps:get(HeiHash,PreTXM, []) ++ Tx2Put,
                            PreTXM)
         }
       }
  end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("MB unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(process, #{gbpid:=PID}=State) ->
  case is_process_alive(PID) of
    true ->
      {noreply, State#{preptxm=>#{},
                       presig=>#{}
                      }};
    false ->
      handle_info(process, maps:remove(gbpid, State))
  end;

handle_info(process,
            #{settings:=MySet, preptxm:=PreTXM}=State) ->
  PreSig=maps:get(presig, State, #{}),
  GBPID=mkblock_genblk:spawn_generate(MySet, PreTXM, PreSig),
  {noreply, State#{preptxm=>#{},
                   presig=>#{},
                   gbpid=>GBPID
                  }};

handle_info(process, State) ->
    lager:notice("MKBLOCK Blocktime, but I not ready"),
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

decode_tpic_txs(TXs) ->
  lists:map(
    fun
      % get pre synced transaction body from txstorage
      ({TxID, null}) ->
        TxBody =
          case txstorage:get_tx(TxID) of
            {ok, {TxID, Tx, _Nodes}} ->
              Tx;
            error ->
              lager:error("can't get body for tx ~p", [TxID]),
              null
          end,
        {TxID, TxBody};
      
      % unpack transaction body
      ({TxID, Tx}) ->
        Unpacked = tx:unpack(Tx),
%%      lager:info("debug tx unpack: ~p", [Unpacked]),
        {TxID, Unpacked}
    end,
    maps:to_list(TXs)
  ).

hei_and_has(B) ->
  PTmp=maps:get(temporary,B,false),

  case PTmp of false ->
                 lager:info("Prev block is permanent, make child"),
                 #{header:=#{height:=Last_Height1}, hash:=Last_Hash1}=B,
                 {Last_Height1,
                  Last_Hash1,
                  <<(bnot Last_Height1):64/big,Last_Hash1/binary>>};
               X when is_integer(X) ->
                 lager:info("Prev block is temporary, make replacement"),
                 #{header:=#{height:=Last_Height1, parent:=Last_Hash1}}=B,
                 {Last_Height1-1,
                  Last_Hash1,
                  <<(bnot Last_Height1-1):64/big,Last_Hash1/binary>>}
  end.


