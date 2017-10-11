-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,binarize/1,sign/1,verify/2,extract/1]).

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
    lager:info("Success ~p",[Success]),
    %lager:info("Failed ~p",[Failed]),
    gen_server:cast(txpool,{failed,Failed}),
    {noreply, State};

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



binarize(#{ txs:=Txs, parent:=Parent, height:=H, timestamp:=T  }) ->
    BTxs=binarizetx(Txs),
    TxHash=crypto:hash(sha256,BTxs),
    Header = <<(size(Parent)+8+8+32):8/integer,
               H:64/integer, %8
               T:64/integer, %8
               TxHash/binary, %32
               Parent/binary,
               BTxs/binary
             >>,
    %<<Header/binary,BTxs/binary>>,
    Header.


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

sign(TX) when is_map(TX) ->
    sign(binarize(TX));

sign(TXBin) when is_binary(TXBin) ->
    Hash=crypto:hash(sha256,TXBin),
    signhash(Hash).


verify(<<HdrSize:8/integer,Rest/binary>>,_Signature) ->
    ParentSize=HdrSize-8-8-32,
    <<H:64/integer, %8
      T:64/integer, %8
      TxHash:32/binary, %32
      Parent:ParentSize/binary
    >>=Rest,
    {H,T,TxHash,Parent,Txs}.


signhash(MsgHash) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    {secp256k1:secp256k1_ec_pubkey_create(hex:parse(K1), true),
     secp256k1:secp256k1_ecdsa_sign(MsgHash, hex:parse(K1), default, <<>>)}.


