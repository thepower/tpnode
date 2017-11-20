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
       nodeid=>tpnode_tools:node_id(),
       inprocess=>hashqueue:new()
      }}.

handle_call(state, _Form, State) ->
    {reply, State, State};

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
              lager:info("error at ~p",[hd(Stack)]),
              {reply, {error, {Ec,Ee}}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(prepare, #{inprocess:=InProc0,queue:=Queue,nodeid:=Node}=State) ->
    %case hashqueue:head(InProc0) of
    %    empty -> ok;
    %    _ -> lager:info("Still in process ~p",[InProc0])
    %end,
    {Queue1,Res}=pullx(1000,Queue,[]),
    lists:foreach(
      fun(Pid)-> 
              %lager:info("Prepare to ~p",[Pid]),
              gen_server:cast(Pid, {prepare, Node, Res}) 
      end, 
      pg2:get_members(mkblock)
     ),
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

handle_cast({done, Txs}, #{inprocess:=InProc0}=State) ->
    InProc1=lists:foldl(
      fun(Tx,Acc) ->
              lager:info("TX pool tx done ~p",[Tx]),
              hashqueue:remove(Tx,Acc)
      end, 
      InProc0,
      Txs),
    {noreply, State#{
                inprocess=>InProc1
               }
    };

handle_cast({failed, Txs}, #{inprocess:=InProc0}=State) ->
    InProc1=lists:foldl(
              fun({TxID,Reason},Acc) ->
                      lager:info("TX pool tx failed ~p ~p",[TxID,Reason]),
                      hashqueue:remove(TxID,Acc)
              end, 
              InProc0,
              Txs),
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
            lager:info("Pull tx ~p",[E1]),
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





