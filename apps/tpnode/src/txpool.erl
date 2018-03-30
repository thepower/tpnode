-module(txpool).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([new_tx/1,get_pack/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

new_tx(BinTX) ->
    gen_server:call(txpool,{new_tx,BinTX}).

get_pack() ->
    gen_server:call(txpool, get_pack).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    {ok, #{
       queue=>queue:new(),
       nodeid=>nodekey:node_id(),
       inprocess=>hashqueue:new()
      }}.

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
            }, _From, #{nodeid:=Node,queue:=Queue}=State) ->
    lager:notice("TODO: Check keys"),
    TxID=generate_txid(Node),
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
                        },Queue)
      }
    };

handle_call({register, #{
               register:=_
              }=Patch}, _From, #{nodeid:=Node,queue:=Queue}=State) ->
    TxID=generate_txid(Node),
    {reply,
     {ok, TxID},
     State#{
       queue=>queue:in({TxID, Patch},Queue)
      }
    };


handle_call({patch, #{
               patch:=_,
               sig:=_
              }=Patch}, _From, #{nodeid:=Node,queue:=Queue}=State) ->
    case settings:verify(Patch) of
        {ok, #{ sigverify:=#{valid:=[_|_]} }} ->
            TxID=generate_txid(Node),
            {reply,
             {ok, TxID},
             State#{
               queue=>queue:in({TxID, Patch},Queue)
              }
            };
        bad_sig ->
            {reply, {error, bad_sig}, State};
        _ ->
            {reply, {error, verify}, State}
    end;


handle_call({new_tx, BinTx}, _From, #{nodeid:=Node,queue:=Queue}=State) ->
    try
        case tx:verify(BinTx) of
            {ok, Tx} ->
                TxID=generate_txid(Node),
                {reply, {ok, TxID}, State#{
                                      queue=>queue:in({TxID,Tx},Queue)
                                     }};
            Err ->
                {reply, {error, Err}, State}
        end
    catch Ec:Ee ->
              Stack=erlang:get_stacktrace(),
              lists:foreach(
                fun(Where) ->
                        lager:info("error at ~p",[Where])
                end, Stack),
              {reply, {error, {Ec,Ee}}, State}
    end;

handle_call(status, _From, #{nodeid:=Node,queue:=Queue}=State) ->
	{reply, {Node, queue:len(Queue)}, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(settings, State) ->
    {noreply,load_settings(State)};

handle_cast({inbound_block, #{hash:=Hash}=Block}, #{queue:=Queue}=State) ->
    BlId=bin2hex:dbin2hex(Hash),
    lager:info("Inbound block ~p",[{BlId,Block}]),
    {noreply, State#{
                queue=>queue:in({BlId,Block},Queue)
               }
    };

handle_cast(prepare, #{mychain:=MyChain,inprocess:=InProc0,queue:=Queue,nodeid:=Node}=State) ->
    %case hashqueue:head(InProc0) of
    %    empty -> ok;
    %    _ -> lager:info("Still in process ~p",[InProc0])
    %end,

    {Queue1,Res}=pullx(2048,Queue,[]),
	try
		PreSig=maps:merge(
				 gen_server:call(blockchain, lastsig),
				 #{null=><<"mkblock">>,
				   chain=>MyChain
				  }),
		MResX=msgpack:pack(PreSig),
		gen_server:cast(mkblock, {tpic, self(), MResX}),
		tpic:cast(tpic,<<"mkblock">>,MResX)
    catch _:_ ->
              Stack1=erlang:get_stacktrace(),
              lager:error("Can't send xsig ~p",[Stack1])
	end,

    try

        MRes=msgpack:pack(#{null=><<"mkblock">>,
                            chain=>MyChain,
                            origin=>Node,
                            txs=>maps:from_list(
                                   lists:map(
                                     fun({TxID,T}) ->
                                             {TxID,tx:pack(T)}
                                     end, Res)
                                  )
                           }),
        tpic:cast(tpic,<<"mkblock">>,MRes)
        %lager:info("Cast ~p ~p",[MKb,msgpack:unpack(MRes)])
    catch _:_ ->
              Stack2=erlang:get_stacktrace(),
              lager:error("Can't encode at ~p",[Stack2])
    end,

    %lists:foreach(
    %  fun(Pid)->
    %          %lager:info("Prepare to ~p",[Pid]),
    %          gen_server:cast(Pid, {prepare, Node, Res})
    %  end,
    %  pg2:get_members({mkblock,MyChain})
    % ),
    gen_server:cast(mkblock, {prepare, Node, Res}),
    Time=erlang:system_time(seconds),
    {InProc1,Queue2}=recovery_lost(InProc0,Queue1,Time),
    ETime=Time+20,
    {noreply, State#{
                queue=>Queue2,
                inprocess=>lists:foldl(
                             fun({TxId,TxBody},Acc) ->
                                     hashqueue:add(TxId,ETime,TxBody,Acc)
                             end,
                             InProc1,
                             Res
                            )
               }
    };

handle_cast(prepare, State) ->
    lager:notice("TXPOOL Blocktime, but I not ready"),
    {noreply,load_settings(State)};

handle_cast({done, Txs}, #{inprocess:=InProc0}=State) ->
    InProc1=lists:foldl(
      fun({Tx,_},Acc) ->
              lager:info("TX pool ext tx done ~p",[Tx]),
              hashqueue:remove(Tx,Acc);
		 (Tx,Acc) ->
			  lager:debug("TX pool tx done ~p",[Tx]),
              hashqueue:remove(Tx,Acc)
      end,
      InProc0,
      Txs),
	gen_server:cast(tpnode_ws_dispatcher,{done, true, Txs}),
    {noreply, State#{
                inprocess=>InProc1
               }
    };

handle_cast({failed, Txs}, #{inprocess:=InProc0}=State) ->
	InProc1=lists:foldl(
			  fun({_,{overdue,Parent}}, Acc) ->
					  lager:info("TX pool inbound block overdue ~p",[Parent]),
					  hashqueue:remove(Parent,Acc);
				 ({TxID,Reason},Acc) ->
					  lager:info("TX pool tx failed ~s ~p",[TxID,Reason]),
					  hashqueue:remove(TxID,Acc)
			  end,
			  InProc0,
			  Txs),
	gen_server:cast(tpnode_ws_dispatcher,{done, false, Txs}),
	{noreply, State#{
				inprocess=>InProc1
			   }
	};


handle_cast(_Msg, State) ->
    lager:info("Unkown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

generate_txid(Node) ->
    Timestamp=bin2hex:dbin2hex(binary:encode_unsigned(os:system_time())),
    Number=bin2hex:dbin2hex(binary:encode_unsigned(erlang:unique_integer([positive]))),
    iolist_to_binary([Timestamp,"-",Node,"-",Number]).

pullx(0,Q,Acc) ->
    {Q,Acc};

pullx(N,Q,Acc) ->
    {Element,Q1}=queue:out(Q),
    case Element of
        {value, E1} ->
			%lager:debug("Pull tx ~p",[E1]),
			pullx(N-1, Q1, [E1|Acc]);
        empty ->
            {Q,Acc}
    end.

recovery_lost(InProc,Queue,Now) ->
    case hashqueue:head(InProc) of
        empty ->
            {InProc, Queue};
        I when is_integer(I) andalso I>=Now ->
            {InProc, Queue};
        I when is_integer(I) ->
            case hashqueue:pop(InProc) of
                {InProc1,empty} ->
                    {InProc1, Queue};
                {InProc1,{TxID,Tx}} ->
                    recovery_lost(InProc1,queue:in({TxID,Tx},Queue),Now)
            end
    end.

load_settings(State) ->
    MyChain=blockchain:get_settings(chain,0),
    case maps:get(mychain, State, undefined) of
        undefined -> %join new pg2
            pg2:create({?MODULE,MyChain}),
            pg2:join({?MODULE,MyChain},self());
        MyChain -> ok; %nothing changed
        OldChain -> %leave old, join new
            pg2:leave({?MODULE,OldChain},self()),
            pg2:create({?MODULE,MyChain}),
            pg2:join({?MODULE,MyChain},self())
    end,
    State#{
      mychain=>MyChain
     }.

