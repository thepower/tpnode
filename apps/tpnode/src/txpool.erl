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
       nodeid=>tpnode_tools:node_id()
      }}.

handle_call(state, _Form, State) ->
    {reply, State, State};

handle_call({new_tx, BinTx}, _From, #{nodeid:=Node,queue:=Queue}=State) ->
    try
    case tx:verify(BinTx) of
        {ok, Tx} -> 
            TxID=generate_txid(Node),
            lager:info("TX ~p: ~p",[TxID,Tx]),
            {reply, {ok, TxID}, State#{
                                  queue=>queue:in({TxID,Tx},Queue)
                                 }};
        Err ->
            {reply, {error, Err}, State}
    end
    catch Ec:Ee ->
              {reply, {error, {Ec,Ee}}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(prepare, #{queue:=Queue,nodeid:=Node}=State) ->
    {Queue1,Res}=lists:foldl(
      fun(_,{Q,Acc}) ->
              {Element,Q1}=queue:out(Q),
              case Element of 
                  {value, E1} ->
                      {Q1, [E1|Acc]};
                  empty ->
                      {Q1, Acc}
              end
      end, {Queue, []}, [1,2]),
    lists:foreach(
      fun(Pid)-> 
              lager:info("Prepare to ~p",[Pid]),
              gen_server:cast(Pid, {prepare, Node, Res}) 
      end, 
      pg2:get_members(mkblock)
     ),
    {noreply, State#{queue=>Queue1}}; 

handle_cast({failed, Txs}, State) ->
    lists:foreach(
      fun(Tx) ->
              lager:info("TX failed ~p",[Tx])
      end, Txs),
    {noreply, State};

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
    

