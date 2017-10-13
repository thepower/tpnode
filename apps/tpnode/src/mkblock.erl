-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,sign/1,verify/1,extract/1,mkblock/1]).

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
    lager:info("Prepare from node ~p ~b",[_Node,length(Txs)]),
    T2=case catch erlang:read_timer(T1) of 
           I when is_integer(I) ->
               T1;
           _ -> erlang:send_after(5000,self(),process)
       end,

    {noreply, State#{
                preptxl=>PreTXL++Txs,
                timer=>T2
               }
    };


handle_cast(process, #{preptxl:=PreTXL}=State) ->
    TXL=lists:keysort(1,PreTXL),
    Addrs=lists:foldl(
            fun({_,#{from:=F}},Acc) ->
                    case maps:get(F,Acc,undefined) of
                        undefined ->
                            AddrInfo=gen_server:call(blockchain,{get_addr,F}),
                            maps:put(F,AddrInfo,Acc);
                        _ ->
                            Acc
                    end
            end, #{}, TXL),
    %lager:info("Tx addrs ~p",[Addrs]),
    {Success,Failed}=try_process(TXL,Addrs,[],[]),
%    lists:foreach(
%      fun(Se) ->
%              lager:info("Success ~p",[Se])
%      end, Success),
    %lager:info("Failed ~p",[Failed]),
    gen_server:cast(txpool,{failed,Failed}),
    #{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
    Blk=sign(
          mkblock(#{
            txs=>Success, 
            parent=>Last_Hash,
            height=>Last_Height+1
           })
         ),
    lists:foreach(
      fun(Pid)-> 
              gen_server:cast(Pid, {new_block, Blk}) 
      end, 
      pg2:get_members(blockchain)
     ),
    lager:info("New block ~p",[Blk]),
    {noreply, State#{preptxl=>[]}};

handle_cast(_Msg, State) ->
    lager:info("unknown cast ~p",[_Msg]),
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

try_process([],_Addresses,Success,Failed) ->
    {Success, Failed};

try_process([{TxID,#{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,from:=From}=Tx}|Rest],Addresses,Success,Failed) ->
    Address=maps:get(From,Addresses,#{}),
    #{amount:=CurAmount,
      seq:=CurSeq,
      t:=CurT
     }=Currency=maps:get(Cur,Address,#{amount =>0,seq => 1,t=>0}),
    try
        NewAmount=if CurAmount >= Amount ->
                         CurAmount - Amount;
                     true ->
                         throw ('insufficient_fund')
                  end,
        NewSeq=if CurSeq < Seq ->
                      Seq;
                  true ->
                      throw ('bad_seq')
               end,
        NewT=if CurT < Timestamp ->
                    Timestamp;
                true ->
                    throw ('bad_timestamp')
             end,
        NewAddresses=maps:put(From,maps:put(Cur,Currency#{
                                                amount=>NewAmount,
                                                seq=>NewSeq,
                                                t=>NewT
                                               },Address),Addresses),
        try_process(Rest,NewAddresses,[{TxID,Tx}|Success],Failed)
    catch throw:X ->
              try_process(Rest,Addresses,Success,[{TxID,X}|Failed])
    end.



mkblock(#{ txs:=Txs, parent:=Parent, height:=H }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    BHeader = <<H:64/integer, %8
               TxHash/binary, %32
               Parent/binary
             >>,
    #{header=>#{parent=>Parent,height=>H,txs=>TxHash},
      hash=>crypto:hash(sha256,BHeader),
      txs=>Txs,
      sign=>[]}.


binarizetx([]) ->
    <<>>;

binarizetx([{TxID,Tx}|Rest]) ->
    BTx=tx:pack(Tx),
    TxIDLen=size(TxID),
    TxLen=size(BTx),
    <<TxIDLen:8/integer,TxLen:16/integer,TxID/binary,BTx/binary,(binarizetx(Rest))/binary>>.

extract(<<>>) ->
    [];

extract(<<TxIDLen:8/integer,TxLen:16/integer,Body/binary>>) ->
    <<TxID:TxIDLen/binary,Tx:TxLen/binary,Rest/binary>> = Body,
    [{TxID,tx:unpack(Tx)}|extract(Rest)].

sign(Blk) when is_map(Blk) ->
    %Blk=mkblock(TX),
    Hash=maps:get(hash,Blk),
    Sign=signhash(Hash),
    Blk#{
      sign=>[Sign|maps:get(sign,Blk,[])]
     }.

verify(#{ txs:=Txs, header:=#{parent:=Parent, height:=H}, hash:=HdrHash, sign:=Sigs }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    BHeader = <<H:64/integer, %8
               TxHash/binary, %32
               Parent/binary
             >>,
    Hash=crypto:hash(sha256,BHeader),
    if Hash =/= HdrHash ->
           false;
       true ->
           {ok, TK}=application:get_env(tpnode,trusted_keys),
           Trusted=lists:map(
                     fun(K) ->
                             hex:parse(K)
                     end,
                     TK),
           {true,lists:foldl(
             fun({PubKey,Sig},{Succ,Fail}) ->
                     case lists:member(PubKey,Trusted) of
                         false ->
                             {Succ, Fail+1};
                         true ->
                             case secp256k1:secp256k1_ecdsa_verify(Hash, Sig, PubKey) of
                                 correct ->
                                     {[{PubKey,Sig}|Succ], Fail};
                                 _ ->
                                     {Succ, Fail+1}
                             end
                     end
             end, {[],0}, Sigs)}
    end.

    
signhash(MsgHash) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    {secp256k1:secp256k1_ec_pubkey_create(hex:parse(K1), true),
     secp256k1:secp256k1_ecdsa_sign(MsgHash, hex:parse(K1), default, <<>>)}.


