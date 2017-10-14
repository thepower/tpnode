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
    Addrs1=lists:foldl(
            fun({_,#{from:=F,cur:=Cur}},Acc) ->
                    case maps:get(F,Acc,undefined) of
                        undefined ->
                            AddrInfo=gen_server:call(blockchain,{get_addr,F,Cur}),
                            maps:put({F,Cur},AddrInfo,Acc);
                        _ ->
                            Acc
                    end
            end, #{}, TXL),
    Addrs=lists:foldl(
            fun({_,#{to:=T,cur:=Cur}},Acc) ->
                    case maps:get(T,Acc,undefined) of
                        undefined ->
                            AddrInfo=gen_server:call(blockchain,{get_addr,T,Cur}),
                            maps:put({T,Cur},AddrInfo,Acc);
                        _ ->
                            Acc
                    end
            end, Addrs1, TXL),
    %lager:info("Tx addrs ~p",[Addrs]),
    {Success,Failed,NewBal}=try_process(TXL,Addrs,[],[]),
    maps:fold(
      fun(Adr,Se,_) ->
              lager:info("NewBal ~p: ~p",[Adr,Se])
      end, [], NewBal),
    %lager:info("Failed ~p",[Failed]),
    gen_server:cast(txpool,{failed,Failed}),
    #{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
    Blk=sign(
          mkblock(#{
            txs=>Success, 
            parent=>Last_Hash,
            height=>Last_Height+1,
            bals=>NewBal
           })
         ),
    lists:foreach(
      fun(Pid)-> 
              gen_server:cast(Pid, {new_block, Blk}) 
      end, 
      pg2:get_members(blockchain)
     ),
    lager:info("New block ~p",[maps:without([header,sign],Blk)]),
    %{noreply, State#{preptxl=>[]}};
    {noreply, State};


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
    lager:error("FC ~p",[Addresses]),
    FCurrency=maps:get({From,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    #{amount:=CurFAmount,
      seq:=CurFSeq,
      t:=CurFTime
     }=FCurrency,
    #{amount:=CurTAmount
     }=TCurrency=maps:get({To,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    try
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
        NewF=FCurrency#{
               amount=>NewFAmount,
               seq=>NewSeq,
               t=>NewTime
              },
        NewT=TCurrency#{
               amount=>NewTAmount
              },
        NewAddresses=maps:put({From,Cur},NewF,maps:put({To,Cur},NewT,Addresses)),
        try_process(Rest,NewAddresses,[{TxID,Tx}|Success],Failed)
    catch throw:X ->
              try_process(Rest,Addresses,Success,[{TxID,X}|Failed])
    end.

mkblock(#{ txs:=Txs, parent:=Parent, height:=H, bals:=Bals }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsHash=crypto:hash(sha256,BalsBin),
    BHeader = <<H:64/integer, %8
               TxHash/binary, %32
               Parent/binary,
               BalsHash/binary
             >>,
    #{header=>#{parent=>Parent,height=>H,txs=>TxHash},
      hash=>crypto:hash(sha256,BHeader),
      txs=>Txs,
      bals=>Bals,
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

verify(#{ txs:=Txs, header:=#{parent:=Parent, height:=H}, hash:=HdrHash, sign:=Sigs, bals:=Bals }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsHash=crypto:hash(sha256,BalsBin),
    BHeader = <<H:64/integer, %8
               TxHash/binary, %32
               Parent/binary,
               BalsHash/binary
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

bals2bin(NewBal) ->
    lists:foldl(
      fun({{Addr,Cur},
           #{amount:=Amount,
             seq:=Seq,
             t:=T
            }
          },Acc) ->
              <<Acc/binary,Addr/binary,":",Cur/binary,":",
                (integer_to_binary(trunc(Amount*1000000000)))/binary,":",
                (integer_to_binary(Seq))/binary,":",
                (integer_to_binary(T))/binary,"\n">>
      end, <<>>,
      lists:keysort(1,maps:to_list(NewBal))
     ).

