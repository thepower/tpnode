-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_link/0]).
-export([generate_block/4,benchmark/1,decode_tpic_txs/1]).


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
            lager:info("Can't decode TPIC ~p",[_Any]),
            {noreply, State}
    end;

handle_cast({tpic, _From, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"origin">>:=Origin,
                     <<"txs">>:=TPICTXs
                    }}, State)  ->
    TXs=decode_tpic_txs(TPICTXs),
    lager:info("Got txs from ~s: ~p",[Origin, TXs]),
    handle_cast({prepare, Origin, TXs}, State);
    
handle_cast({prepare, _Node, Txs}, #{preptxl:=PreTXL}=State) ->
    {noreply, 
     case maps:get(parent, State, undefined) of
         undefined ->
             #{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
             State#{
               preptxl=>PreTXL++Txs,
               parent=>{Last_Height,Last_Hash}
              };
         _ ->
             State#{ preptxl=>PreTXL++Txs }
     end
    };

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(process, #{settings:=#{mychain:=MyChain}=MySet,preptxl:=PreTXL}=State) ->
    lager:info("-------[MAKE BLOCK]-------"),
    AE=maps:get(ae,MySet,1),
    try
        if(AE==0 andalso PreTXL==[]) -> throw(empty);
          true -> ok
        end,
        T1=erlang:system_time(),
        Parent=case maps:get(parent,State,undefined) of
                   undefined ->
                       #{header:=#{height:=Last_Height1},hash:=Last_Hash1}=gen_server:call(blockchain,last_block),
                       {Last_Height1,Last_Hash1};
                   {A,B} -> {A,B}
               end,

        PropsFun=fun(mychain) -> 
                         MyChain;
                    (settings) ->
                         blockchain:get_settings();
                    ({endless,From,_Cur}) ->
                         lists:member(
                           From,
                           application:get_env(tpnode,endless,[])
                          ) 
                 end,
        AddrFun=fun({Addr,Cur}) ->
                        gen_server:call(blockchain,{get_addr,Addr,Cur});
                   (Addr) ->
                        gen_server:call(blockchain,{get_addr,Addr})
                end,

        #{block:=Block,
          failed:=Failed}=generate_block(PreTXL, Parent, PropsFun, AddrFun),
        T2=erlang:system_time(),
        if Failed==[] ->
               ok;
           true ->
               %there was failed tx. Block empty?
               gen_server:cast(txpool,{failed,Failed}),
               if(AE==0) ->
                     case maps:get(txs,Block,[]) of
                         [] -> throw(empty);
                         _ -> ok
                     end;
                 true ->
                     ok
               end
        end,
        Timestamp=os:system_time(millisecond),
        ED=[
            {timestamp,Timestamp},
            {createduration,T2-T1}
           ],
        SignedBlock=sign(Block,ED),
        %cast whole block for my local blockvote
        gen_server:cast(blockvote, {new_block, SignedBlock, self()}),
        %Block signature for each other
        lager:info("MB My sign ~p",[maps:get(sign,SignedBlock)]),
        HBlk=msgpack:pack(
               #{null=><<"blockvote">>,
                 <<"n">>=>node(),
                 <<"hash">>=>maps:get(hash,SignedBlock),
                 <<"sign">>=>maps:get(sign,SignedBlock),
                 <<"chain">>=>MyChain
                }
              ),
        tpic:cast(tpic,<<"blockvote">>, HBlk),
        {noreply, State#{preptxl=>[],parent=>undefined}}
    catch throw:empty ->
              lager:info("Skip empty block"),
              {noreply, State#{preptxl=>[],parent=>undefined}}
    end;

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

try_process([],_SetState,Addresses,_GetFun,Acc) ->
    Acc#{table=>Addresses};

%process inbound block
try_process([{BlID, #{ hash:=_, txs:=TxList }}|Rest], 
            SetState, Addresses, GetFun, Acc) ->
    try_process([ {TxID,maps:put(origin_block,BlID,Tx)} || {TxID,Tx} <- TxList ]++Rest,
                SetState,Addresses,GetFun, Acc);

%process settings
try_process([{TxID, 
              #{patch:=_LPatch,
                sig:=_
               }=Tx}|Rest], SetState, Addresses, GetFun, 
            #{failed:=Failed,
              settings:=Settings}=Acc) ->
    try 
        lager:error("Check signatures of patch "),
        SS1=settings:patch({TxID,Tx},SetState),
        lager:info("Success Patch ~p against settings ~p",[_LPatch,SetState]),
        try_process(Rest,SS1,Addresses,GetFun,
                    Acc#{
                      settings=>[{TxID,Tx}|Settings]
                     }
                   )
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                         [_LPatch,Ec,Ee,SetState]),
              lager:info("at ~p", [S]),
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{
                            failed=>[{TxID,Tx}|Failed]
                           })
    end;

try_process([{TxID,
              #{seq:=_Seq,timestamp:=_Timestamp,to:=To,portin:=PortInBlock}=Tx}
             |Rest],
            SetState, Addresses, GetFun, 
            #{success:=Success, failed:=Failed}=Acc) ->
    lager:notice("TODO:Check signature once again and check seq"),
    try
        Bals=maps:get(To,Addresses),
        case Bals of
            #{} -> 
                ok;
            #{chain:=_} ->
                ok;
            _ ->
                throw('address_exists')
        end,
        lager:notice("TODO:check block before porting in"),
        NewAddrBal=maps:get(To,maps:get(bals,PortInBlock)),

        NewAddresses=maps:fold(
                       fun(Cur,Info,FAcc) ->
                               maps:put({To,Cur},Info,FAcc)
                       end, Addresses, maps:remove(To,NewAddrBal)),
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success]})
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end;

try_process([{TxID,
              #{seq:=_Seq,timestamp:=_Timestamp,from:=From,portout:=PortTo}=Tx}
             |Rest],
            SetState, Addresses, GetFun,
            #{success:=Success, failed:=Failed}=Acc) ->
    lager:error("Check signature once again and check seq"),
    try
        Bals=maps:get(From,Addresses),
        A1=maps:remove(keep,Bals),
        Empty=maps:size(A1)==0,
        OffChain=maps:is_key(chain,A1),
        if Empty -> throw('badaddress');
           OffChain -> throw('offchain');
           true -> ok
        end,
        ValidChains=blockchain:get_settings([chains]),
        case lists:member(PortTo,ValidChains) of
            true -> 
                ok;
            false ->
                throw ('bad_chain')
        end,
        NewAddresses=maps:put(From,#{chain=>PortTo},Addresses),
        lager:info("Portout ok"),
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success]})
    catch throw:X ->
              lager:info("Portout fail ~p",[X]),
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end;


try_process([{TxID, #{from:=From,to:=To}=Tx} |Rest],
            SetState, Addresses, GetFun, 
            #{failed:=Failed}=Acc) ->
    MyChain=GetFun(mychain),
    FAddr=address:check(From),
    TAddr=address:check(To),
    case {FAddr,TAddr} of
        {{true,{chain,MyChain}},{true,{chain,MyChain}}} ->
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{chain,MyChain}}, {true,{chain,OtherChain}}} ->
            try_process_outbound([{TxID,Tx#{
                                          outbound=>OtherChain
                                         }}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{chain,_OtherChain}}, {true,{chain,MyChain}}} ->
            try_process_inbound([{TxID,
                                  maps:remove(outbound,
                                              Tx
                                             )}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{ver,_}},{true,{chain,MyChain}}}  -> %local
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{ver,_}},{true,{ver,_}}}  -> %pure local
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        _ ->
            lager:info("TX ~s addr error ~p -> ~p",[TxID,FAddr,TAddr]),
            try_process(Rest,SetState,Addresses,GetFun,
                        Acc#{failed=>[{TxID,'bad_src_or_dst_addr'}|Failed]})
    end;

try_process([{TxID, UnknownTx} |Rest],
            SetState, Addresses, GetFun, 
            #{failed:=Failed}=Acc) ->
    lager:info("Unknown TX ~p type ~p",[TxID,UnknownTx]),
    try_process(Rest,SetState,Addresses,GetFun,
                Acc#{failed=>[{TxID,'unknown_type'}|Failed]}).


try_process_inbound([{TxID,
                    #{cur:=Cur,amount:=Amount,to:=To,
                      origin_block:=OriginBlk
                     }=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success, 
                    failed:=Failed,
                    pick_block:=PickBlock}=Acc) ->
    lager:error("Check signature once again"),
    TBal=maps:get(To,Addresses),
    try
        if Amount >= 0 -> ok;
           true -> throw ('bad_amount')
        end,
        NewTAmount=bal:get_cur(Cur,TBal) + Amount,
        NewT=maps:remove(keep,
                         bal:put_cur(
                           Cur,
                           NewTAmount,
                           TBal)
                        ),
        NewAddresses=maps:put(To,NewT,Addresses),
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success],
                         pick_block=>maps:put(OriginBlk, 1, PickBlock)
                        })
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.

try_process_outbound([{TxID,
                       #{outbound:=OutTo,
                         cur:=Cur,seq:=Seq,timestamp:=Timestamp,
                         amount:=Amount,to:=To,from:=From}=Tx}
                      |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success, failed:=Failed, outbound:=Outbound}=Acc) ->
    lager:notice("TODO:Check signature once again"),
    lager:info("outbound to chain ~p ~p",[OutTo,To]),
    FBal=maps:get(From,Addresses),

    try
        if Amount >= 0 -> 
               ok;
           true ->
               throw ('bad_amount')
        end,
        CurFSeq=bal:get(seq,FBal),
        if CurFSeq < Seq -> ok;
           true -> throw ('bad_seq')
        end,
        CurFTime=bal:get(t,FBal),
        if CurFTime < Timestamp -> ok;
           true -> throw ('bad_timestamp')
        end,

        CurFAmount=bal:get_cur(Cur,FBal),
        NewFAmount=if CurFAmount >= Amount ->
                          CurFAmount - Amount;
                      true ->
                          case GetFun({endless,From,Cur}) of
                              true ->
                                  CurFAmount - Amount;
                              false ->
                                  throw ('insufficient_fund')
                          end
                   end,

        NewF=maps:remove(keep,
                         bal:mput(
                           Cur,
                           NewFAmount,
                           Seq,
                           Timestamp,
                           FBal)
                        ),

        NewAddresses=maps:put(From,NewF,Addresses),
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{
                      success=>[{TxID,Tx}|Success],
                      outbound=>[{TxID,OutTo}|Outbound]
                     })
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.

try_process_local([{TxID,
                    #{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,to:=To,from:=From}=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success, failed:=Failed}=Acc) ->
    %lager:error("Check signature once again"),
    FBal=maps:get(From,Addresses),
    TBal=maps:get(To,Addresses),
    try
        if Amount >= 0 -> 
               ok;
           true ->
               throw ('bad_amount')
        end,
        CurFSeq=bal:get(seq,FBal),
        if CurFSeq < Seq -> ok;
           true -> throw ('bad_seq')
        end,
        CurFTime=bal:get(t,FBal),
        if CurFTime < Timestamp -> ok;
           true -> throw ('bad_timestamp')
        end,

        CurFAmount=bal:get_cur(Cur,FBal),
        NewFAmount=if CurFAmount >= Amount ->
                          CurFAmount - Amount;
                      true ->
                          case GetFun({endless,From,Cur}) of
                              true ->
                                  CurFAmount - Amount;
                              false ->
                                  throw ('insufficient_fund')
                          end
                   end,
        NewTAmount=bal:get_cur(Cur,TBal) + Amount,
        NewF=maps:remove(keep,
                         bal:mput(
                           Cur,
                           NewFAmount,
                           Seq,
                           Timestamp,
                           FBal)
                        ),
        NewT=maps:remove(keep,
                         bal:put_cur(
                           Cur,
                           NewTAmount,
                           TBal)
                        ),
        NewAddresses=maps:put(From,NewF,maps:put(To,NewT,Addresses)),

        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success]})
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.


    
sign(Blk,ED) when is_map(Blk) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(K1),
    block:sign(Blk,ED,PrivKey).

load_settings(State) ->
    OldSettings=maps:get(settings,State,#{}),
    MyChain=blockchain:get_settings(chain,0),
    AE=blockchain:get_settings(<<"allowempty">>,1),
    case maps:get(mychain, OldSettings, undefined) of
        undefined -> %join new pg2
            pg2:create({mkblock,MyChain}),
            pg2:join({mkblock,MyChain},self());
        MyChain -> ok; %nothing changed
        OldChain -> %leave old, join new
            pg2:leave({mkblock,OldChain},self()),
            pg2:create({mkblock,MyChain}),
            pg2:join({mkblock,MyChain},self())
    end,
    State#{
      settings=>maps:merge(
                  OldSettings,
                  #{ae=>AE, mychain=>MyChain}
                 )
     }.

generate_block(PreTXL,{Parent_Height,Parent_Hash},GetSettings,GetAddr) ->
    %file:write_file("tx.txt", io_lib:format("~p.~n",[PreTXL])),
    _T1=erlang:system_time(), 
    TXL=lists:usort(PreTXL),
    _T2=erlang:system_time(), 
    {Addrs,XSettings}=lists:foldl(
                        fun({_,#{hash:=_,header:=#{},txs:=Txs}},{AAcc0,SAcc}) ->
                                %lager:info("TXs ~p",[Txs]),
                                {
                                 lists:foldl( 
                                   fun({_,#{to:=T,cur:=Cur}},AAcc) ->
                                           TB=bal:fetch(T, Cur, false, maps:get(T,AAcc,#{}), GetAddr),
                                           maps:put(T,TB,AAcc)
                                   end, AAcc0, Txs)
                                 ,SAcc};
                           ({_,#{patch:=_}},{AAcc,undefined}) ->
                                S1=GetSettings(settings),
                                {AAcc,S1};
                           ({_,#{patch:=_}},{AAcc,SAcc}) ->
                                {AAcc,SAcc};
                           ({_,#{from:=F,portin:=_ToChain}},{AAcc,SAcc}) ->
                                A1=case maps:get(F,AAcc,undefined) of
                                       undefined ->
                                           AddrInfo1=GetAddr(F),
                                           maps:put(F,AddrInfo1#{keep=>false},AAcc);
                                       _ ->
                                           AAcc
                                   end,
                                {A1,SAcc};
                           ({_,#{from:=F,portout:=_ToChain}},{AAcc,SAcc}) ->
                                A1=case maps:get(F,AAcc,undefined) of
                                       undefined ->
                                           AddrInfo1=GetAddr(F),
                                           lager:info("Add address for portout ~p",[AddrInfo1]),
                                           maps:put(F,AddrInfo1#{keep=>false},AAcc);
                                       _ ->
                                           AAcc
                                   end,
                                {A1,SAcc};
                           ({_,#{to:=T,from:=F,cur:=Cur}},{AAcc,SAcc}) ->
                                FB=bal:fetch(F, Cur, true, maps:get(F,AAcc,#{}), GetAddr),
                                TB=bal:fetch(T, Cur, false, maps:get(T,AAcc,#{}), GetAddr),
                                {maps:put(F,FB,maps:put(T,TB,AAcc)),SAcc}
                        end, {#{},undefined}, TXL),
    _T3=erlang:system_time(), 
    #{success:=Success,
      failed:=Failed,
      settings:=Settings,
      table:=NewBal0,
      outbound:=Outbound,
      pick_block:=PickBlocks
     }=try_process(TXL,XSettings,Addrs,GetSettings,
                   #{success=>[],
                     failed=>[],
                     settings=>[],
                     export=>[],
                     outbound=>[],
                     pick_block=>#{}
                    }
                  ),
    lager:info("Must pick blocks ~p",[maps:keys(PickBlocks)]),
    _T4=erlang:system_time(), 
    NewBal=maps:filter(
             fun(_,V) ->
                     maps:get(keep,V,true)
             end, NewBal0),
    lager:info("MB NewBal ~p",[NewBal]),

    LC=ledger_hash(NewBal),
    lager:info("MB LedgerHash ~s",[bin2hex:dbin2hex(LC)]),
    _T5=erlang:system_time(), 
    Blk=block:mkblock(#{
          txs=>Success, 
          parent=>Parent_Hash,
          height=>Parent_Height+1,
          bals=>NewBal,
          ledger_hash=>LC,
          settings=>Settings,
          tx_proof=>[ TxID || {TxID,_ToChain} <- Outbound ],
          inbound_blocks=>lists:foldl(
                            fun(PickID,Acc) ->
                                    [{PickID,
                                      proplists:get_value(PickID,TXL)
                                     }|Acc]
                            end, [], maps:keys(PickBlocks))

         }),
    _T6=erlang:system_time(), 
    lager:info("Created block ~w ~s: txs: ~w, bals: ~w chain ~p",
               [
                Parent_Height+1,
                block:blkid(maps:get(hash,Blk)),
                length(Success),
                maps:size(NewBal),
                GetSettings(mychain)
               ]),
    %lager:info("BENCHMARK txs       ~w~n",[length(TXL)]),
    %lager:info("BENCHMARK sort tx   ~.6f ~n",[(_T2-_T1)/1000000]),
    %lager:info("BENCHMARK pull addr ~.6f ~n",[(_T3-_T2)/1000000]),
    %lager:info("BENCHMARK process   ~.6f ~n",[(_T4-_T3)/1000000]),
    %lager:info("BENCHMARK filter    ~.6f ~n",[(_T5-_T4)/1000000]),
    %lager:info("BENCHMARK mk block  ~.6f ~n",[(_T6-_T5)/1000000]),
    #{block=>Blk#{outbound=>Outbound},
      failed=>Failed
     }.


benchmark(N) ->
    Parent=crypto:hash(sha256,<<"123">>),
    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pub1=tpecdsa:secp256k1_ec_pubkey_create(Pvt1, false),
    From=address:pub2addr(0,Pub1),
    Coin= <<"FTT">>,
    Addresses=lists:map(
                fun(_) ->
                        address:pub2addr(0,crypto:strong_rand_bytes(16))
                end, lists:seq(1, N)),
    GetSettings=fun(mychain) -> 0;
                   (settings) ->
                        #{
                      chains => [0],
                      chain =>
                      #{0 => #{blocktime => 5, minsig => 2, <<"allowempty">> => 0} }
                     };
                   ({endless,Address,_Cur}) when Address==From->
                        true;
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun({_Addr,Cur}) ->
                    #{amount => 54.0,cur => Cur,
                      lastblk => crypto:hash(sha256,<<"parent0">>),
                      seq => 0,t => 0};
               (_Addr) ->
                    #{<<"FTT">> =>
                      #{amount => 54.0,cur => <<"FTT">>,
                        lastblk => crypto:hash(sha256,<<"parent0">>),
                        seq => 0,t => 0}
                     }
            end,

    {_,_Res}=lists:foldl(fun(Address,{Seq,Acc}) ->
                                Tx=#{
                                  amount=>1,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{}),
                                  from=>From,
                                  to=>Address,
                                  seq=>Seq,
                                  timestamp=>os:system_time()
                                 },
                                NewTx=tx:unpack(tx:sign(Tx,Pvt1)),
                                {Seq+1,
                                 [{binary:encode_unsigned(10000+Seq),NewTx}|Acc]
                                }
                        end,{2,[]},Addresses),
    T1=erlang:system_time(),
    _=generate_block(
                                      _Res,
                                      {1,Parent},
                                      GetSettings,
                                      GetAddr),

    T2=erlang:system_time(),
    (T2-T1)/1000000.

decode_tpic_txs(TXs) ->
    lists:map(
      fun({TxID,Tx}) ->
              {TxID, tx:unpack(Tx)}
      end, maps:to_list(TXs)).

-ifdef(TEST).
ledger_hash(NewBal) ->
    {ok,LC}=case whereis(ledger) of 
                undefined ->
                    %there is no ledger. Is it test?
                    {ok,LedgerS1}=ledger:init([test]),
                    {reply,LCResp,_LedgerS2}=ledger:handle_call({check,[]},self(),LedgerS1),
                    LCResp;
                X when is_pid(X) -> 
                    ledger:check(maps:to_list(NewBal))
            end,
    LC.
-else.
ledger_hash(NewBal) ->
    {ok,LC}=ledger:check(maps:to_list(NewBal)),
    LC.
-endif.


-ifdef(TEST).

mkblock_test() ->
    GetSettings=fun(mychain) ->
                        0;
                   (settings) ->
                        #{
                      chains => [0,1],
                      chain =>
                      #{0 =>
                        #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                        1 => 
                        #{blocktime => 10,minsig => 1}
                       },
                      globals => #{<<"patchsigs">> => 2},
                      keys =>
                      #{
                        <<"node1">> => crypto:hash(sha256,<<"node1">>),
                        <<"node2">> => crypto:hash(sha256,<<"node2">>),
                        <<"node3">> => crypto:hash(sha256,<<"node3">>),
                        <<"node4">> => crypto:hash(sha256,<<"node4">>)
                       },
                      nodechain =>
                      #{
                        <<"node1">> => 0,
                        <<"node2">> => 0,
                        <<"node3">> => 0,
                        <<"node4">> => 1
                       }
                     };
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pvt2= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,6>>,
    Pvt3= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,7>>,
    ParentHash=crypto:hash(sha256,<<"parent">>),
    Pub1=tpecdsa:secp256k1_ec_pubkey_create(Pvt1),
    Pub2=tpecdsa:secp256k1_ec_pubkey_create(Pvt2),
    Pub3=tpecdsa:secp256k1_ec_pubkey_create(Pvt3),

    TX0=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>10,
                     cur=><<"FTT">>,
                     seq=>2,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),
    TX1=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>9000,
                     cur=><<"BAD">>,
                     seq=>3,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),

    TX2=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(1,Pub3),
                     amount=>9,
                     cur=><<"FTT">>,
                     seq=>4,
                     timestamp=>os:system_time(millisecond)
                    },Pvt1)
                 ),
    #{block:=Block,
      failed:=Failed}=generate_block(
                        [{<<"1interchain">>,TX0},
                         {<<"2invalid">>,TX1},
                         {<<"3crosschain">>,TX2}
                        ],
                        {1,ParentHash},
                        GetSettings,
                        GetAddr),
    ?assertEqual([{<<"2invalid">>,insufficient_fund}], Failed),
    ?assertEqual([<<"3crosschain">>],proplists:get_keys(maps:get(tx_proof,Block))),
    ?assertEqual([{<<"3crosschain">>,1}],maps:get(outbound,Block)),
    SignedBlock=block:sign(Block,<<1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1>>),
    file:write_file("testblk.txt", io_lib:format("~p.~n",[Block])),
    ?assertMatch({true, {_,_}},block:verify(SignedBlock)),
    maps:get(1,block:outward_mk(maps:get(outbound,Block),SignedBlock)),
    test_xchain_inbound().

%test_getaddr%({_Addr,_Cur}) -> %suitable for inbound tx
test_getaddr(_Addr) ->
    #{amount => #{
        <<"FTT">> => 110,
        <<"TST">> => 26
       },
      seq => 1,
      t => 1512047425350,
      lastblk => <<0:64>>
     }.

test_xchain_inbound() ->
    ParentHash=crypto:hash(sha256,<<"parent2">>),
    GetSettings=fun(mychain) ->
                        1;
                   (settings) ->
                        #{
                      chains => [0,1],
                      chain =>
                      #{0 =>
                        #{blocktime => 5, minsig => 2, <<"allowempty">> => 0},
                        1 => 
                        #{blocktime => 10,minsig => 1}
                       },
                      globals => #{<<"patchsigs">> => 2},
                      keys =>
                      #{
                        <<"node1">> => crypto:hash(sha256,<<"node1">>),
                        <<"node2">> => crypto:hash(sha256,<<"node2">>),
                        <<"node3">> => crypto:hash(sha256,<<"node3">>),
                        <<"node4">> => crypto:hash(sha256,<<"node4">>)
                       },
                      nodechain =>
                      #{
                        <<"node1">> => 0,
                        <<"node2">> => 0,
                        <<"node3">> => 0,
                        <<"node4">> => 1
                       }
                     };
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun test_getaddr/1,
    

    BTX={<<"4F8367774366BC52BFBB1FFD203F815FB2274A871C7EF8F173C23EBA63365DCA">>,
         #{hash =>
           <<79,131,103,119,67,102,188,82,191,187,31,253,32,63,129,95,178,39,74,
             135,28,126,248,241,115,194,62,186,99,54,93,202>>,
           header =>
           #{balroot =>
             <<100,201,127,106,126,195,253,190,51,162,170,35,25,133,55,221,32,
               222,160,173,151,239,240,207,179,63,32,137,115,220,187,86>>,
             height => 125,
             parent =>
             <<18,157,196,134,44,12,188,92,159,126,22,101,109,214,84,157,29,
               48,186,246,102,32,147,74,9,174,152,43,150,227,200,70>>,
             txroot =>
             <<87,147,0,60,61,240,208,56,196,206,139,213,10,57,241,76,147,35,
               10,50,214,139,89,45,91,129,154,192,46,185,136,186>>},
           sign =>
           [#{binextra =>
              <<2,33,3,90,231,223,79,203,91,151,168,111,206,187,16,125,68,8,
                88,221,251,40,199,8,231,14,6,198,37,170,33,14,138,111,22,1,8,
                0,0,1,96,7,149,104,17,3,8,0,0,0,0,0,9,39,21>>,
              extra =>
              [{pubkey,<<3,90,231,223,79,203,91,151,168,111,206,187,16,125,
                         68,8,88,221,251,40,199,8,231,14,6,198,37,170,33,14,
                         138,111,22>>},
               {timestamp,1511955720209},
               {createduration,599829}],
              signature =>
              <<48,68,2,32,83,1,50,58,78,196,138,173,124,198,165,16,113,75,
                112,45,139,139,106,224,185,98,148,117,44,125,221,251,36,200,
                102,44,2,32,121,141,16,243,9,156,46,97,206,213,185,109,58,
                139,77,56,87,243,181,254,188,38,158,6,161,96,20,140,153,236,
                246,127>>},
            #{binextra =>
              <<2,33,2,7,131,239,103,72,81,252,233,190,212,91,73,77,131,140,
                107,95,57,79,23,91,55,221,38,165,17,242,158,31,33,57,75,1,8,0,
                0,1,96,7,149,104,13,3,8,0,0,0,0,0,7,100,47>>,
              extra =>
              [{pubkey,<<2,7,131,239,103,72,81,252,233,190,212,91,73,77,131,
                         140,107,95,57,79,23,91,55,221,38,165,17,242,158,31,
                         33,57,75>>},
               {timestamp,1511955720205},
               {createduration,484399}],
              signature =>
              <<48,69,2,33,0,193,141,201,10,158,9,186,213,138,169,40,46,147,
                87,86,95,168,105,38,14,234,0,34,175,197,245,6,179,108,247,
                66,185,2,32,66,161,36,73,11,127,38,157,73,224,110,16,206,
                248,16,93,229,161,135,160,224,96,132,45,107,198,204,205,109,
                39,117,75>>}],
           tx_proof =>
           [{<<"14FB8BB66EE28CCF-noded57D9KidJHaHxyKBqyM8T8eBRjDxRGWhZC-2944">>,
             {<<180,136,203,147,25,47,21,127,67,78,244,67,34,4,125,164,112,88,63,
                92,178,186,180,59,96,16,142,139,149,133,239,216>>,
              <<52,182,4,40,176,139,124,238,6,254,144,173,117,149,6,86,177,70,
                135,10,106,127,22,211,235,68,133,193,231,110,230,16>>}}],
           txs =>
           [{<<"14FB8BB66EE28CCF-noded57D9KidJHaHxyKBqyM8T8eBRjDxRGWhZC-2944">>,
             #{amount => 1.0,cur => <<"FTT">>,
               extradata => <<"{\"message\":\"preved from gentx\"}">>,
               from => <<"73VoBpU8Rtkyx1moAPJBgAZGcouhGXWVpD6PVjm5">>,
               outbound => 1,
               sig => #{  %incorrect signature for new format
                 <<"043E9FD2BBA07359FAA4EDC9AC53046EE530418F97ECDEA77E0E98288E6",
                   "E56178D79D6A023323B0047886DAFEAEDA1F9C05633A536C70C513AB847",
                   "99B32F20E2DD">>
                 =>
                 <<"30450221009B3E4E72F4DBD2A79762C2BE732CFB0D36B7EE3A4C4AC361E",
                 "B935EFE701BB757022033CD9752D6AB71C939F9C70C56185F7C0FDC9E79E2"
                 "6BB824B2F1722EFC687A4E">>
                },
               seq => 12,
               timestamp => 1511955715572989476,
               to => <<"75dF2XsYc5rLgovnekw7DobT7mubTQNN2M6E1kRr">>}}]}},
    #{block:=Block,
      failed:=Failed}=generate_block(
                        [BTX],
                        {1,ParentHash},
                        GetSettings,
                        GetAddr),
    ?assertEqual([], Failed),
    #{block=>Block, failed=>Failed}.

-endif.
