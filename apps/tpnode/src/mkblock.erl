-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

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
    pg2:create(mkblock),
    pg2:join(mkblock,self()),
    {ok, #{
       nodeid=>tpnode_tools:node_id(),
       preptxl=>[],
       timer=>undefined,
       settings=>#{}
      }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({prepare, _Node, Txs}, #{preptxl:=PreTXL,timer:=T1}=State) ->
    %T2=case catch erlang:read_timer(T1) of 
    %       I when is_integer(I) ->
    %           T1;
    %       _ -> erlang:send_after(5000,self(),process)
    %   end,
    T2=T1,
    {noreply, 
     case maps:get(parent, State, undefined) of
         undefined ->
             #{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
             State#{
               preptxl=>PreTXL++Txs,
               timer=>T2,
               parent=>{Last_Height,Last_Hash}
              };
         _ ->
             State#{
               preptxl=>PreTXL++Txs,
               timer=>T2
              }
     end
    };

handle_cast(settings, State) ->
    AE=blockchain:get_settings(<<"allowempty">>,1),
    {noreply, State#{
                settings=>maps:put(ae,AE,maps:get(settings,State,#{}))
               }};

handle_cast(_Msg, State) ->
    lager:info("unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(process, #{preptxl:=PreTXL}=State) ->
    AE=maps:get(ae,maps:get(settings,State,#{}),1),
    if(AE==0 andalso PreTXL==[]) ->
          lager:info("Skip empty block"),
          {noreply, State};
      true ->
          TXL=lists:keysort(1,PreTXL),
          {Addrs,XSettings}=lists:foldl(
                              fun({_,#{patch:=_}},{AAcc,undefined}) ->
                                      S1=blockchain:get_settings(),
                                      {AAcc,S1};
                                 ({_,#{patch:=_}},{AAcc,SAcc}) ->
                                      {AAcc,SAcc};
                                 ({_,#{to:=T,from:=F,cur:=Cur}},{AAcc,SAcc}) ->
                                      A1=case maps:get(F,AAcc,undefined) of
                                             undefined ->
                                                 AddrInfo1=gen_server:call(blockchain,{get_addr,F,Cur}),
                                                 maps:put({F,Cur},AddrInfo1#{keep=>false},AAcc);
                                             _ ->
                                                 AAcc
                                         end,
                                      A2=case maps:get(T,A1,undefined) of
                                             undefined ->
                                                 AddrInfo2=gen_server:call(blockchain,{get_addr,T,Cur}),
                                                 maps:put({T,Cur},AddrInfo2#{keep=>false},A1);
                                             _ ->
                                                 A1
                                         end,
                                      {A2,SAcc}
                              end, {#{},undefined}, TXL),
          lager:info("XS ~p",[XSettings]),
          {Success,Failed,NewBal0,Settings}=try_process(TXL,XSettings,Addrs,[],[],[]),
          NewBal=maps:filter(
                   fun(_,V) ->
                           maps:get(keep,V,true)
                   end, NewBal0),
          %    maps:fold(
          %      fun(Adr,Se,_) ->
          %              lager:info("NewBal ~p: ~p",[Adr,Se])
          %      end, [], NewBal),
          %lager:info("Failed ~p",[Failed]),
          gen_server:cast(txpool,{failed,Failed}),
          %#{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
          {Last_Height,Last_Hash}=case maps:get(parent,State,undefined) of
                                      undefined ->
                                          #{header:=#{height:=Last_Height1},hash:=Last_Hash1}=gen_server:call(blockchain,last_block),
                                          {Last_Height1,Last_Hash1};
                                      {A,B} -> {A,B}
                                  end,
          Blk=sign(
                block:mkblock(#{
                  txs=>Success, 
                  parent=>Last_Hash,
                  height=>Last_Height+1,
                  bals=>NewBal,
                  settings=>Settings
                 })
               ),
          lager:debug("Prepare block ~B txs ~p",[Last_Height+1,Success]),
          lager:info("Created block ~w ~s: txs: ~w, bals: ~w",[
                                                               Last_Height+1,
                                                               block:blkid(maps:get(hash,Blk)),
                                                               length(Success),
                                                               maps:size(NewBal)
                                                              ]),
          %cast whole block to local blockvote
          gen_server:cast(blockvote, {new_block, Blk, self()}),
          lists:foreach(
            fun(Pid)-> 
                    %cast signature for all blockvotes
                    gen_server:cast(Pid, {signature, maps:get(hash,Blk), maps:get(sign,Blk)}) 
            end, 
            pg2:get_members(blockvote)
           ),
          {noreply, State#{preptxl=>[],parent=>undefined}}
    end;


handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

try_process([],_SetState,Addresses,Success,Failed,Settings) ->
    {Success, Failed, Addresses, Settings};

try_process([{TxID, 
              #{patch:=_Patch,
                signatures:=_Signatures
               }=Tx}|Rest],
            SetState,
            Addresses,
            Success,
            Failed,
            Settings) ->
    try 
        lager:error("Check signatures of patch "),
        SS1=settings:patch({TxID,Tx},SetState),
        lager:info("Success Patch ~p against settings ~p",[_Patch,SetState]),
        try_process(Rest,SS1,Addresses,Success,Failed,[{TxID,Tx}|Settings])
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                         [_Patch,Ec,Ee,SetState]),
              lager:info("at ~p", [S]),
              try_process(Rest,SetState,Addresses,Success,Failed,Settings)
    end;

try_process([{TxID,
              #{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,to:=To,from:=From}=Tx}
             |Rest],
            SetState,
            Addresses,
            Success,
            Failed,
            Settings) ->
    lager:error("Check signature once again"),
    FCurrency=maps:get({From,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    #{amount:=CurFAmount,
      seq:=CurFSeq,
      t:=CurFTime
     }=FCurrency,
    #{amount:=CurTAmount
     }=TCurrency=maps:get({To,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    try
        if Amount >= 0 -> 
               ok;
           true ->
               throw ('bad_amount')
        end,
        NewFAmount=if CurFAmount >= Amount ->
                         CurFAmount - Amount;
                     true ->
                         case lists:member(
                                From,
                                application:get_env(tpnode,endless,[])
                               ) of
                             true ->
                                 CurFAmount - Amount;
                             false ->
                                 throw ('insufficient_fund')
                         end
                  end,
        NewTAmount=CurTAmount + Amount,
        NewSeq=if CurFSeq < Seq ->
                      Seq;
                  true ->
                      throw ('bad_seq')
               end,
        NewTime=if CurFTime < Timestamp ->
                    Timestamp;
                true ->
                    throw ('bad_timestamp')
             end,
        NewF=maps:remove(keep,FCurrency#{
               amount=>NewFAmount,
               seq=>NewSeq,
               t=>NewTime
              }),
        NewT=maps:remove(keep,TCurrency#{
               amount=>NewTAmount
              }),
        NewAddresses=maps:put({From,Cur},NewF,maps:put({To,Cur},NewT,Addresses)),
        try_process(Rest,SetState,NewAddresses,[{TxID,Tx}|Success],Failed,Settings)
    catch throw:X ->
              try_process(Rest,SetState,Addresses,Success,[{TxID,X}|Failed],Settings)
    end.


    
sign(Blk) when is_map(Blk) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(K1),
    block:sign(Blk,PrivKey).

