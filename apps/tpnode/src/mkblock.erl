-module(mkblock).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([generate_block/4,test/0]).

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
    AE=maps:get(ae,MySet,1),
    if(AE==0 andalso PreTXL==[]) ->
          lager:debug("Skip empty block"),
          {noreply, State};
      true ->
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
          SignedBlock=sign(Block),
          if Failed==[] ->
                 ok;
             true ->
                 gen_server:cast(txpool,{failed,Failed})
          end,
          %cast whole block to local blockvote
          gen_server:cast(blockvote, {new_block, SignedBlock, self()}),
          lists:foreach(
            fun(Pid)-> %cast signature for all blockvotes
                    gen_server:cast(Pid, {signature, 
                                          maps:get(hash,SignedBlock),
                                          maps:get(sign,SignedBlock)}) 
            end, 
            pg2:get_members({blockvote,MyChain})
           ),
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

try_process([{TxID, 
              #{patch:=_Patch,
                signatures:=_Signatures
               }=Tx}|Rest], SetState, Addresses, GetFun, 
            #{failed:=Failed,
              settings:=Settings}=Acc) ->
    try 
        lager:error("Check signatures of patch "),
        SS1=settings:patch({TxID,Tx},SetState),
        lager:info("Success Patch ~p against settings ~p",[_Patch,SetState]),
        try_process(Rest,SS1,Addresses,GetFun,
                    Acc#{
                      settings=>[{TxID,Tx}|Settings]
                     }
                   )
    catch Ec:Ee ->
              S=erlang:get_stacktrace(),
              lager:info("Fail to Patch ~p ~p:~p against settings ~p",
                         [_Patch,Ec,Ee,SetState]),
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
    case {address:check(From),address:check(To)} of
        {{true,{chain,MyChain}},{true,{chain,MyChain}}} ->
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{chain,MyChain}}, {true,{chain,OtherChain}}} ->
            try_process_outbound([{TxID,Tx#{
                                          outbound=>OtherChain
                                         }}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{chain,OtherChain}}, {true,{chain,MyChain}}} ->
            try_process_inbound([{TxID,Tx#{
                                         inbound=>OtherChain
                                        }}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{ver,_}},{true,{chain,MyChain}}}  -> %local
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,{ver,_}},{true,{ver,_}}}  -> %pure local
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        _ ->
            try_process(Rest,SetState,Addresses,GetFun,
                        Acc#{failed=>[{TxID,'bad_src_or_dst_addr'}|Failed]})
    end.

try_process_inbound([{TxID,
                    #{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,to:=To,from:=From}=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success, failed:=Failed}=Acc) ->
    lager:error("Check signature once again"),
    FCurrency=maps:get({From,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    #{amount:=CurFAmount,
      seq:=CurFSeq,
      t:=CurFTime
     }=FCurrency,
    #{amount:=CurTAmount
     }=TCurrency=maps:get({To,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    try
        throw(unimplemented),
        if Amount >= 0 -> ok;
           true -> throw ('bad_amount')
        end,
        NewFAmount=if CurFAmount >= Amount -> CurFAmount - Amount;
                      true -> throw ('insufficient_fund')
                   end,
        NewTAmount=CurTAmount + Amount,
        NewSeq=if CurFSeq < Seq -> Seq;
                  true -> throw ('bad_seq')
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
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success]})
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
    FCurrency=maps:get({From,Cur},Addresses,#{amount =>0,seq => 1,t=>0}),
    #{amount:=CurFAmount,
      seq:=CurFSeq,
      t:=CurFTime
     }=FCurrency,
    try
        if Amount >= 0 -> 
               ok;
           true ->
               throw ('bad_amount')
        end,
        NewFAmount=if CurFAmount >= Amount ->
                          CurFAmount - Amount;
                      true ->
                          throw ('insufficient_fund')
                   end,
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
        NewAddresses=maps:put({From,Cur},NewF,Addresses),
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
                          case GetFun({endless,From,Cur}) of
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
        try_process(Rest,SetState,NewAddresses,GetFun,
                    Acc#{success=>[{TxID,Tx}|Success]})
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.


    
sign(Blk) when is_map(Blk) ->
    {ok,K1}=application:get_env(tpnode,privkey),
    PrivKey=hex:parse(K1),
    block:sign(Blk,PrivKey).

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
    TXL=lists:keysort(1,PreTXL),
    {Addrs,XSettings}=lists:foldl(
                        fun({_,#{patch:=_}},{AAcc,undefined}) ->
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
                                A1=case maps:get({F,Cur},AAcc,undefined) of
                                       undefined ->
                                           AddrInfo1=GetAddr({F,Cur}),
                                           maps:put({F,Cur},AddrInfo1#{keep=>false},AAcc);
                                       _ ->
                                           AAcc
                                   end,
                                A2=case maps:get({T,Cur},A1,undefined) of
                                       undefined ->
                                           AddrInfo2=GetAddr({T,Cur}),
                                           maps:put({T,Cur},AddrInfo2#{keep=>false},A1);
                                       _ ->
                                           A1
                                   end,
                                {A2,SAcc}
                        end, {#{},undefined}, TXL),
    #{success:=Success,
      failed:=Failed,
      settings:=Settings,
      %export:=Export,
      table:=NewBal0,
      outbound:=Outbound
     }=try_process(TXL,XSettings,Addrs,GetSettings,
                   #{success=>[],
                     failed=>[],
                     settings=>[],
                     export=>[],
                     outbound=>[]
                    }
                  ),
    NewBal=maps:filter(
             fun(_,V) ->
                     maps:get(keep,V,true)
             end, NewBal0),
    Blk=block:mkblock(#{
          txs=>Success, 
          parent=>Parent_Hash,
          height=>Parent_Height+1,
          bals=>NewBal,
          settings=>Settings,
          tx_proof=>[ TxID || {TxID,_ToChain} <- Outbound ]
         }),
    lager:info("Created block ~w ~s: txs: ~w, bals: ~w chain ~p",
               [
                Parent_Height+1,
                block:blkid(maps:get(hash,Blk)),
                length(Success),
                maps:size(NewBal),
                GetSettings(mychain)
               ]),
    #{block=>Blk#{outbound=>Outbound},
      failed=>Failed
     }.


test() ->
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


    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    Pvt2= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,6>>,
    Pvt3= <<30,1,172,151,224,97,198,186,132,106,120,141,156,0,13,156,178,193,56,24,180,178,60,235,66,194,121,0,4,220,214,7>>,
    ParentHash=crypto:hash(sha256,<<"parent">>),
    Pub1=secp256k1:secp256k1_ec_pubkey_create(Pvt1, false),
    Pub2=secp256k1:secp256k1_ec_pubkey_create(Pvt2, false),
    Pub3=secp256k1:secp256k1_ec_pubkey_create(Pvt3, false),

    TX0=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>10,
                     cur=><<"FTT">>,
                     seq=>1,
                     timestamp=>os:system_time()
                    },Pvt1)
                 ),
    TX1=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(0,Pub2),
                     amount=>9000,
                     cur=><<"BAD">>,
                     seq=>2,
                     timestamp=>os:system_time()
                    },Pvt1)
                 ),

    TX2=tx:unpack( tx:sign(
                     #{
                     from=>address:pub2caddr(0,Pub1),
                     to=>address:pub2caddr(1,Pub3),
                     amount=>9,
                     cur=><<"FTT">>,
                     seq=>3,
                     timestamp=>os:system_time()
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
    [{<<"2invalid">>,insufficient_fund}]=Failed,
    [<<"3crosschain">>]=proplists:get_keys(maps:get(tx_proof,Block)),
    [{<<"3crosschain">>,1}]=maps:get(outbound,Block),
    SignedBlock=block:sign(Block,<<1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1>>),
    maps:get(1,block:outward_mk(maps:get(outbound,Block),SignedBlock)).

