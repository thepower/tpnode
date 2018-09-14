-module(txpool).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([new_tx/1, get_pack/0, inbound_block/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([encode_int/1,decode_ints/1]).
-export([decode_txid/1]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

new_tx(BinTX) ->
    gen_server:call(txpool, {new_tx, BinTX}).

inbound_block(Blk) ->
  gen_server:cast(txpool, {inbound_block, Blk}).

get_pack() ->
    gen_server:call(txpool, get_pack).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok,
   #{
     queue=>queue:new(),
     nodeid=>nodekey:node_id(),
     pubkey=>nodekey:get_pub(),
     inprocess=>hashqueue:new()
    }
  }.

handle_call(state, _Form, State) ->
    {reply, State, State};

handle_call({portout, #{
               from:=Address,
               portout:=PortTo,
               seq:=Seq,
               timestamp:=Timestamp,
               public_key:=HPub,
               signature:=HSig
              }
            }, _From, #{queue:=Queue}=State) ->
    lager:notice("TODO: Check keys"),
    case generate_txid(State) of
      error ->
        {reply, {error,cant_gen_txid}, State};
      {ok, TxID} ->
        {reply,
         {ok, TxID},
         State#{
           queue=>queue:in({TxID,
                            #{
                              from=>Address,
                              portout=>PortTo,
                              seq=>Seq,
                              timestamp=>Timestamp,
                              public_key=>HPub,
                              signature=>HSig
                             }
                           }, Queue)
          }
        }
    end;

handle_call({register, #{
               register:=_
              }=Patch}, _From, #{queue:=Queue}=State) ->
  case generate_txid(State) of
    error ->
      {reply, {error,cant_gen_txid}, State};
    {ok, TxID} ->
      {reply,
       {ok, TxID},
       State#{
         queue=>queue:in({TxID, Patch}, Queue)
        }
      }
  end;


handle_call({patch, #{
               patch:=_,
               sig:=_
              }=Patch}, _From, #{queue:=Queue}=State) ->
  case settings:verify(Patch) of
    {ok, #{ sigverify:=#{valid:=[_|_]} }} ->
      case generate_txid(State) of
        error ->
          {reply, {error, cant_gen_txid}, State};
        {ok, TxID} ->
          {reply,
           {ok, TxID},
           State#{
             queue=>queue:in({TxID, Patch}, Queue)
            }
          }
      end;
    bad_sig ->
      {reply, {error, bad_sig}, State};
    _ ->
      {reply, {error, verify}, State}
  end;

handle_call({push_etx, [{_, _}|_]=Lst}, _From, #{queue:=Queue}=State) ->
  {reply, ok,
   State#{
     queue=>lists:foldl( fun queue:in_r/2, Queue, Lst)
    }};

handle_call({new_tx, BinTx}, _From, #{queue:=Queue}=State) ->
    try
        case tx:verify(BinTx) of
            {ok, Tx} ->
            case generate_txid(State) of
              error ->
                {reply, {error, cant_gen_txid}, State};
              {ok, TxID} ->
                {reply, {ok, TxID}, State#{
                                      queue=>queue:in({TxID, Tx}, Queue)
                                     }}
            end;
            Err ->
                {reply, {error, Err}, State}
        end
    catch Ec:Ee ->
              Stack=erlang:get_stacktrace(),
              lists:foreach(
                fun(Where) ->
                        lager:info("error at ~p", [Where])
                end, Stack),
              {reply, {error, {Ec, Ee}}, State}
    end;

handle_call(txid, _From, State) ->
  {reply, generate_txid(State), State};

handle_call(status, _From, #{nodeid:=Node, queue:=Queue}=State) ->
  {reply, {Node, queue:len(Queue)}, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast({new_height, H}, State) ->
    {noreply, State#{height=>H}};

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast({inbound_block, #{hash:=Hash}=Block}, #{queue:=Queue}=State) ->
    BlId=bin2hex:dbin2hex(Hash),
    lager:info("Inbound block ~p", [{BlId, Block}]),
    {noreply, State#{
                queue=>queue:in({BlId, Block}, Queue)
               }
    };

handle_cast(prepare, #{mychain:=MyChain, inprocess:=InProc0, queue:=Queue}=State) ->
  {Queue1, Res}=pullx(2048, Queue, []),
  PK=case maps:get(pubkey, State, undefined) of
       undefined -> nodekey:get_pub();
       FoundKey -> FoundKey
     end,

  try
    PreSig=maps:merge(
             gen_server:call(blockchain, lastsig),
             #{null=><<"mkblock">>,
               chain=>MyChain
              }),
    MResX=msgpack:pack(PreSig),
    gen_server:cast(mkblock, {tpic, PK, MResX}),
    tpic:cast(tpic, <<"mkblock">>, MResX)
  catch _:_ ->
        Stack1=erlang:get_stacktrace(),
        lager:error("Can't send xsig ~p", [Stack1])
  end,

  try
    LBH=get_lbh(State),
    MRes=msgpack:pack(#{null=><<"mkblock">>,
              chain=>MyChain,
              lbh=>LBH,
              txs=>maps:from_list(
                   lists:map(
                   fun({TxID, T}) ->
                       {TxID, tx:pack(T)}
                   end, Res)
                  )
               }),
    gen_server:cast(mkblock, {tpic, PK, MRes}),
    tpic:cast(tpic, <<"mkblock">>, MRes)
  catch _:_ ->
        Stack2=erlang:get_stacktrace(),
        lager:error("Can't encode at ~p", [Stack2])
  end,

  Time=erlang:system_time(seconds),
  {InProc1, Queue2}=recovery_lost(InProc0, Queue1, Time),
  ETime=Time+20,
  {noreply, State#{
        queue=>Queue2,
        inprocess=>lists:foldl(
               fun({TxId, TxBody}, Acc) ->
                   hashqueue:add(TxId, ETime, TxBody, Acc)
               end,
               InProc1,
               Res
              )
         }
  };

handle_cast(prepare, State) ->
    lager:notice("TXPOOL Blocktime, but I not ready"),
    {noreply, load_settings(State)};

handle_cast({done, Txs}, #{inprocess:=InProc0}=State) ->
    InProc1=lists:foldl(
      fun({Tx, _}, Acc) ->
              lager:info("TX pool ext tx done ~p", [Tx]),
              hashqueue:remove(Tx, Acc);
     (Tx, Acc) ->
        lager:debug("TX pool tx done ~p", [Tx]),
              hashqueue:remove(Tx, Acc)
      end,
      InProc0,
      Txs),
  gen_server:cast(txstatus, {done, true, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, true, Txs}),
    {noreply, State#{
                inprocess=>InProc1
               }
    };

handle_cast({failed, Txs}, #{inprocess:=InProc0}=State) ->
  InProc1=lists:foldl(
        fun({_, {overdue, Parent}}, Acc) ->
            lager:info("TX pool inbound block overdue ~p", [Parent]),
            hashqueue:remove(Parent, Acc);
         ({TxID, Reason}, Acc) ->
            lager:info("TX pool tx failed ~s ~p", [TxID, Reason]),
            hashqueue:remove(TxID, Acc)
        end,
        InProc0,
        Txs),
  gen_server:cast(txstatus, {done, false, Txs}),
  gen_server:cast(tpnode_ws_dispatcher, {done, false, Txs}),
  {noreply, State#{
        inprocess=>InProc1
         }
  };


handle_cast(_Msg, State) ->
    lager:info("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(prepare, State) ->
  handle_cast(prepare, State);

handle_info(getlb, State) ->
  {_Chain,Height}=gen_server:call(blockchain,last_block_height),
  {noreply, State#{height=>Height}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

decode_int(<<0:1/big,X:7/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<2:2/big,X:14/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<6:3/big,X:29/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<14:4/big,X:60/big,Rest/binary>>) ->
  {X,Rest};
decode_int(<<15:4/big,S:4/big,BX:S/binary,Rest/binary>>) ->
  {binary:decode_unsigned(BX),Rest}.

encode_int(X) when X<128 ->
  <<X:8/integer>>;
encode_int(X) when X<16384 ->
  <<2:2/big,X:14/big>>;
encode_int(X) when X<536870912 ->
  <<6:3/big,X:29/big>>;
encode_int(X) when X<1152921504606846977 ->
  <<14:4/big,X:60/big>>;
encode_int(X) ->
  B=binary:encode_unsigned(X),
  true=(size(B)<15),
  <<15:4/big,(size(B)):4/big,B/binary>>.


decode_ints(Bin) ->
  case decode_int(Bin) of
    {Int, <<>>} ->
      [Int];
    {Int, Rest} ->
     [Int|decode_ints(Rest)]
  end.

decode_txid(Txta) ->
  [N0,N1]=binary:split(Txta,<<"-">>),
  Bin=base58:decode(N0),
  {N1, decode_ints(Bin)}.

generate_txid(#{mychain:=MyChain}=State) ->
  LBH=get_lbh(State),
  T=os:system_time(),
%  N=erlang:unique_integer([positive]),
  P=nodekey:node_name(),
  %  Timestamp=base58:encode(binary:encode_unsigned(os:system_time())),
  %  Number=base58:encode(binary:encode_unsigned(erlang:unique_integer([positive]))),
  %  iolist_to_binary([Timestamp, "-", Node, "-", Number]).
  I=base58:encode(
      iolist_to_binary(
        [encode_int(MyChain),
         encode_int(LBH),
         encode_int(T) ])),
  {ok,<<I/binary,"-",P/binary>>};
%<<MyChain:32/big,T:64/big,P/binary>>.

generate_txid(#{}) ->
  error.

get_lbh(State) ->
  case maps:find(height, State) of
    error ->
      {_Chain,H1}=gen_server:call(blockchain,last_block_height),
      H1;
    {ok, H1} ->
      H1
  end.

pullx(0, Q, Acc) ->
    {Q, Acc};

pullx(N, Q, Acc) ->
    {Element, Q1}=queue:out(Q),
    case Element of
        {value, E1} ->
      %lager:debug("Pull tx ~p", [E1]),
      pullx(N-1, Q1, [E1|Acc]);
        empty ->
            {Q, Acc}
    end.

recovery_lost(InProc, Queue, Now) ->
    case hashqueue:head(InProc) of
        empty ->
            {InProc, Queue};
        I when is_integer(I) andalso I>=Now ->
            {InProc, Queue};
        I when is_integer(I) ->
            case hashqueue:pop(InProc) of
                {InProc1, empty} ->
                    {InProc1, Queue};
                {InProc1, {TxID, Tx}} ->
                    recovery_lost(InProc1, queue:in({TxID, Tx}, Queue), Now)
            end
    end.

load_settings(State) ->
    MyChain=blockchain:chain(),
    {_Chain,Height}=gen_server:call(blockchain,last_block_height),
    State#{
      mychain=>MyChain,
      height=>Height
     }.

