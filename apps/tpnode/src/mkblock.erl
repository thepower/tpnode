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
       timer=>undefined
      }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({prepare, _Node, Txs}, #{preptxl:=PreTXL,timer:=T1}=State) ->
    T2=case catch erlang:read_timer(T1) of 
           I when is_integer(I) ->
               T1;
           _ -> erlang:send_after(5000,self(),process)
       end,
    
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



handle_cast(testtx, State) ->
    PreTXL=[{<<"14ED4436D1F3FAAB-noded57D9KidJHaHxyKBqyM8T8eBRjDxRGWhZC-43">>,
             #{amount => 0.5,cur => <<"FTT">>,extradata => <<"{}">>,
               from => <<"13hFFWeBsJYuAYU8wTLPo6LL1wvGrTHPYC">>,
               public_key =>
               <<"043E9FD2BBA07359FAA4EDC9AC53046EE530418F97ECDEA77E0E98288E6E56178D79D6A023323B0047886DAFEAEDA1F9C05633A536C70C513AB84799B32F20E2DD">>,
               seq => 11,
               signature =>
               <<"30440220249519BA3EE863A6F1AA8526C91DAC9614E871199289035F0078DCC0827406C302201340585DE6A8B847E718F4E10395A46C31E4E9CB8EBA344402B23C7AB2ECC374">>,
               timestamp => 1507843268,to => <<"12m93G3sVaa8oyvAYenRsvE1qy4DFgL71o">>}}],
    handle_cast(process, State#{preptxl=>PreTXL});


handle_cast(_Msg, State) ->
    lager:info("unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(process, #{preptxl:=PreTXL}=State) ->
    TXL=lists:keysort(1,PreTXL),
    Addrs1=lists:foldl(
            fun({_,#{from:=F,cur:=Cur}},Acc) ->
                    case maps:get(F,Acc,undefined) of
                        undefined ->
                            AddrInfo=gen_server:call(blockchain,{get_addr,F,Cur}),
                            maps:put({F,Cur},AddrInfo#{keep=>false},Acc);
                        _ ->
                            Acc
                    end
            end, #{}, TXL),
    Addrs=lists:foldl(
            fun({_,#{to:=T,cur:=Cur}},Acc) ->
                    case maps:get(T,Acc,undefined) of
                        undefined ->
                            AddrInfo=gen_server:call(blockchain,{get_addr,T,Cur}),
                            maps:put({T,Cur},AddrInfo#{keep=>false},Acc);
                        _ ->
                            Acc
                    end
            end, Addrs1, TXL),
    {Success,Failed,NewBal0}=try_process(TXL,Addrs,[],[]),
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
            settings=>[]
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
    {noreply, State#{preptxl=>[],parent=>undefined}};


handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

try_process([],Addresses,Success,Failed) ->
    {Success, Failed, Addresses};

try_process([{TxID,#{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,to:=To,from:=From}=Tx}|Rest],Addresses,Success,Failed) ->
%    lager:error("FC ~p",[Addresses]),
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
        try_process(Rest,NewAddresses,[{TxID,Tx}|Success],Failed)
    catch throw:X ->
              try_process(Rest,Addresses,Success,[{TxID,X}|Failed])
    end.


    
sign(Blk) when is_map(Blk) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(K1),
    block:sign(Blk,PrivKey).

