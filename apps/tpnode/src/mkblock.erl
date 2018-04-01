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
-export([generate_block/5,benchmark/1,decode_tpic_txs/1]).


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
    {ok, #{
       nodeid=>nodekey:node_id(),
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

handle_cast({tpic, FromKey, #{
                     null:=<<"mkblock">>,
					 <<"hash">> := ParentHash,
					 <<"signed">> := SignedBy
                    }}, State)  ->
	Origin=gen_server:call(blockchain,{is_our_node,FromKey}),
	lager:debug("MB presig got ~s ~p",[Origin,SignedBy]),
	if Origin==false ->
		   {noreply, State};
	   true ->
		   PreSig=maps:get(presig,State,#{}),
		   {noreply,
			State#{
			  presig=>maps:put(Origin, {ParentHash, SignedBy}, PreSig)
			 }}
	end;

handle_cast({tpic, Origin, #{
                     null:=<<"mkblock">>,
                     <<"chain">>:=_MsgChain,
                     <<"txs">>:=TPICTXs
                    }}, State)  ->
	TXs=decode_tpic_txs(TPICTXs),
	if TXs==[] -> ok;
	   true ->
		   lager:info("Got txs from ~s: ~p",[Origin, TXs])
	end,
	handle_cast({prepare, Origin, TXs}, State);

handle_cast({prepare, Node, Txs}, #{preptxl:=PreTXL}=State) ->
	Origin=gen_server:call(blockchain,{is_our_node,Node}),
	if Origin==false ->
		   lager:error("Got txs from bad node ~s",
					   [bin2hex:dbin2hex(Node)]),
		   {noreply, State};
	   true ->
		   if Txs==[] -> ok;
			  true ->
				  lager:info("TXs from node ~s: ~p",
							 [
							  Origin,
							  length(Txs)
							 ])
		   end,
		   MarkTx=fun({TxID, TxB}) ->
						  {TxID, tx:set_ext(origin,Origin,TxB)}
				  end,
		   {noreply,
			case maps:get(parent, State, undefined) of
				undefined ->
					#{header:=#{height:=Last_Height},hash:=Last_Hash}=gen_server:call(blockchain,last_block),
					State#{
					  preptxl=>PreTXL++lists:map(MarkTx, Txs),
					  parent=>{Last_Height,Last_Hash}
					 };
				_ ->
					State#{ preptxl=>PreTXL++lists:map(MarkTx, Txs) }
			end
		   }
	end;

handle_cast(settings, State) ->
    {noreply, load_settings(State)};

handle_cast(_Msg, State) ->
    lager:info("MB unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(process, #{settings:=#{mychain:=MyChain}=MySet,preptxl:=PreTXL}=State) ->
    lager:info("-------[MAKE BLOCK]-------"),
    AE=maps:get(ae,MySet,1),

	{_,ParentHash}=Parent=case maps:get(parent,State,undefined) of
			   undefined ->
				   lager:info("Fetching last block from blockchain"),
				   #{header:=#{height:=Last_Height1},hash:=Last_Hash1}=gen_server:call(blockchain,last_block),
				   {Last_Height1,Last_Hash1};
			   {A,B} -> {A,B}
		   end,

	PreNodes=try
		PreSig=maps:get(presig, State),
		BK=maps:fold(
			 fun(_,{BH,_},Acc) when BH =/= ParentHash ->
					 Acc;
				(Node1,{_BH,Nodes2},Acc) ->
					 [{Node1, Nodes2}|Acc]
			 end,[], PreSig),
		bron_kerbosch:max_clique(BK)
	catch Ec:Ee ->
			  Stack1=erlang:get_stacktrace(),
			  lager:error("Can't calc xsig ~p:~p ~p",[Ec,Ee,Stack1]),
			  []
	end,

	try
        if(AE==0 andalso PreTXL==[]) -> throw(empty);
          true -> ok
        end,
        T1=erlang:system_time(),
		lager:notice("MB pre nodes ~p",[PreNodes]),

        PropsFun=fun(mychain) ->
                         MyChain;
                    (settings) ->
                         blockchain:get_settings();
                    ({valid_timestamp,TS}) ->
						 abs(os:system_time(millisecond)-TS)<3600000;
					({endless,From,Cur}) ->
						 EndlessPath=[<<"current">>,<<"endless">>,From,Cur],
						 case blockchain:get_settings(EndlessPath) of
							 true -> true;
							 _ ->
								 % TODO 2018-05-01: Replace this code with false
								 Endless=lists:member(
										   From,
										   application:get_env(tpnode,endless,[])
										  ),
								 if Endless ->
										lager:notice("Deprecated: issue tokens by address in config");
									true ->
										ok
								 end,
								 Endless
						 end
				 end,
		AddrFun=fun({Addr,Cur}) ->
                        gen_server:call(blockchain,{get_addr,Addr,Cur});
                   (Addr) ->
                        gen_server:call(blockchain,{get_addr,Addr})
                end,

        #{block:=Block,
          failed:=Failed}=generate_block(PreTXL, Parent, PropsFun, AddrFun,
										[{prevnodes, PreNodes}]),
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
        {noreply, State#{preptxl=>[],parent=>undefined,presig=>#{}}}
    catch throw:empty ->
              lager:info("Skip empty block"),
              {noreply, State#{preptxl=>[],parent=>undefined,presig=>#{}}}
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

deposit_fee(#{amount:=Amounts}, Addr, Addresses, TXL) ->
	TBal=maps:get(Addr,Addresses,bal:new()),
	TBal2=maps:fold(
			fun(Cur, Summ, Acc) ->
					bal:put_cur(Cur,
								bal:get_cur(Cur,Acc) + Summ,
								Acc)
			end,
			TBal,
			Amounts),
	if TBal==TBal2 ->
		   {Addresses,TXL};
	   true ->
		   {maps:put(Addr,
					 maps:remove(keep, TBal2),
					 Addresses),TXL}
	end.

getaddr([], _GetFun, Fallback) ->
	Fallback;

getaddr([E|Rest], GetFun, Fallback) ->
	case GetFun(E) of
		B when is_binary(B) ->
			B;
		_ ->
			getaddr(Rest,GetFun,Fallback)
	end.


try_process([], Settings, Addresses, GetFun, 
			#{fee:=FeeBal,tip:=TipBal}=Acc) ->
	try
		GetFeeFun=fun (Parameter) ->
						  settings:get([<<"current">>,<<"fee">>,params,Parameter],Settings)
				  end,
		lager:info("fee ~p tip ~p",[FeeBal,TipBal]),
		{Addresses2,NewTXL}=lists:foldl(
							  fun({CType,CBal},{FAcc,TXL}) ->
									  Addr=case CType of
											   fee -> 
												   getaddr([<<"feeaddr">>],
														   GetFeeFun,
														   naddress:construct_private(0,0));
											   tip -> 
												   getaddr([<<"tipaddr">>,
															<<"feeaddr">>],
														   GetFeeFun,
														   naddress:construct_private(0,0)
														  );
											   _ ->
												   naddress:construct_private(0,0)
										   end,
									  lager:info("fee ~s ~p to ~p",[CType,CBal,Addr]),
									  deposit_fee(CBal, Addr, FAcc, TXL)
							  end,
							  {Addresses,[]},
							  [ {tip,TipBal}, {fee,FeeBal} ]
							 ),
		case length(NewTXL) of 
			0 ->
				Acc#{table=>Addresses2};
			_ ->
				try_process(NewTXL, Settings, Addresses2, GetFun, 
							Acc#{
							  fee:=bal:new(),
							  tip:=bal:new()
							 }
						   )
		end
	catch _Ec:_Ee ->
			  S=erlang:get_stacktrace(),
			  lager:error("Can't save fees: ~p:~p",[_Ec,_Ee]),
			  lists:foreach(fun(E) ->
								  lager:info("Can't save fee at ~p",[E])
						  end, S),
			  Acc#{table=>Addresses}
	end;

%process inbound block
try_process([{BlID, #{ hash:=BHash, txs:=TxList, header:=#{height:=BHeight} }}|Rest],
            SetState, Addresses, GetFun, Acc) ->
    try_process([ {TxID,
                   Tx#{
                     origin_block_hash=>BHash,
                     origin_block_height=>BHeight,
                     origin_block=>BlID
                    }
                  } || {TxID,Tx} <- TxList ]++Rest,
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
    catch throw:Ee ->
              lager:info("Fail to Patch ~p ~p",
                         [_LPatch,Ee]),
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{
                            failed=>[{TxID,Ee}|Failed]
                           });
          Ec:Ee ->
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
		throw('fixme'),
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
		throw('fixme'),
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
    FAddr=addrcheck(From),
    TAddr=addrcheck(To),
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
        {{true,private},{true,{chain,MyChain}}}  -> %local from pvt
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        {{true,MyChain},{true,private}}  -> %local to pvt
            try_process_local([{TxID,Tx}|Rest],
                  SetState, Addresses, GetFun, Acc);
        _ ->
            lager:info("TX ~s addr error ~p -> ~p",[TxID,FAddr,TAddr]),
            try_process(Rest,SetState,Addresses,GetFun,
                        Acc#{failed=>[{TxID,'bad_src_or_dst_addr'}|Failed]})
    end;

try_process([{TxID, #{register:=PubKey}=Tx} |Rest],
            SetState, Addresses, GetFun,
            #{failed:=Failed,
              success:=Success,
              settings:=Settings }=Acc) ->
    try
        {CG,CB,CA}=case settings:get([<<"current">>,<<"allocblock">>],SetState) of
                       #{<<"block">> := CurBlk,
                         <<"group">> := CurGrp,
                         <<"last">> := CurAddr} ->
                           {CurGrp,CurBlk,CurAddr+1};
                       _ ->
                           throw(unallocable)
                   end,

        NewBAddr=naddress:construct_public(CG, CB, CA),

        IncAddr=#{<<"t">> => <<"set">>,
                  <<"p">> => [<<"current">>,<<"allocblock">>,<<"last">>],
                  <<"v">> => CA},
        AAlloc={<<"aalloc">>,#{sig=>[],patch=>[IncAddr]}},
        SS1=settings:patch(AAlloc,SetState),
        lager:info("Alloc address ~p ~s for key ~s",
                   [NewBAddr,
                    naddress:encode(NewBAddr),
                    bin2hex:dbin2hex(PubKey)
                   ]),

        NewF=bal:put(pubkey, PubKey, bal:new()),
        NewAddresses=maps:put(NewBAddr,NewF,Addresses),

        try_process(Rest,SS1,NewAddresses,GetFun,
                    Acc#{success=> [{TxID,Tx#{address=>NewBAddr}}|Success],
                         settings=>[AAlloc|lists:keydelete(<<"aalloc">>,1,Settings)]
                        })
    catch throw:X ->
              lager:info("Address alloc fail ~p",[X]),
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end;

try_process([{TxID, UnknownTx} |Rest],
			SetState, Addresses, GetFun,
			#{failed:=Failed}=Acc) ->
	lager:info("Unknown TX ~p type ~p",[TxID,UnknownTx]),
	try_process(Rest,SetState,Addresses,GetFun,
				Acc#{failed=>[{TxID,'unknown_type'}|Failed]}).

try_process_inbound([{TxID,
                    #{cur:=Cur,amount:=Amount,to:=To,
                      origin_block:=OriginBlock,
                      origin_block_height:=OriginHeight,
                      origin_block_hash:=OriginHash
                     }=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success,
                    failed:=Failed,
                    settings:=Settings,
                    pick_block:=PickBlock}=Acc) ->
    lager:error("Check signature once again"),
    TBal=maps:get(To,Addresses),
    try
        ChID=2,
        lager:info("Orig Block ~p",[OriginBlock]),
        lager:notice("Change chain number to actual ~p",[SetState]),
        ChainPath=[<<"current">>,<<"sync_status">>,xchain:pack_chid(ChID)],
        {_,ChainLastH}=case settings:get(ChainPath,SetState) of
                           #{<<"block">> := LastBlk,
                             <<"height">> := LastHeight} ->
                               if(OriginHeight>LastHeight) -> ok;
                                 true -> throw({overdue,OriginBlock})
                               end,
                               {LastBlk,LastHeight};
                           _ ->
                               {<<0:64/big>>, 0}
                       end,
        lager:info("SyncState ~p",[ChainLastH]),

        IncPtr=[#{<<"t">> => <<"set">>,
                  <<"p">> => ChainPath++[<<"block">>],
                  <<"v">> => OriginHash
                 },
                #{<<"t">> => <<"set">>,
                  <<"p">> => ChainPath++[<<"height">>],
                  <<"v">> => OriginHeight
                 }
               ],
        PatchTxID= <<"sync",(xchain:pack_chid(ChID))/binary>>,
        SyncPatch={PatchTxID, #{sig=>[],patch=>IncPtr}},
%        SS1=settings:patch(AAlloc,SetState),
%        try_process(Rest,SS1,NewAddresses,GetFun,
%                    Acc#{success=> [{TxID,Tx#{address=>NewBAddr}}|Success],
%                         settings=>[AAlloc|lists:keydelete(<<"aalloc">>,1,Settings)]
%                        })

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
                         pick_block=>maps:put(OriginBlock, 1, PickBlock),
                         settings=>[SyncPatch|lists:keydelete(PatchTxID,1,Settings)]
                        })
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.

try_process_outbound([{TxID,
					   #{outbound:=OutTo,to:=To,from:=From}=Tx}
					  |Rest],
					 SetState, Addresses, GetFun,
					 #{failed:=Failed, 
					   success:=Success,
					   settings:=Settings,
					   outbound:=Outbound,
					   parent:=ParentHash,
					   height:=MyHeight
					  }=Acc) ->
	lager:notice("TODO:Check signature once again"),
	lager:info("outbound to chain ~p ~p",[OutTo,To]),
	FBal=maps:get(From,Addresses),
	EnsureSettings=fun(undefined) -> GetFun(settings);
					  (SettingsReady) -> SettingsReady
				   end,

	try
		RealSettings=EnsureSettings(SetState),
		{NewF,GotFee}=withdraw(FBal,Tx,GetFun,RealSettings),

		PatchTxID= <<"out",(xchain:pack_chid(OutTo))/binary>>,
		{SS2,Set2}=case lists:keymember(PatchTxID,1, Settings) of
					   true ->
						   {SetState, Settings};
					   false ->
						   ChainPath=[<<"current">>,<<"outward">>,
									  xchain:pack_chid(OutTo)],
						   PCP=case settings:get(ChainPath,RealSettings) of
								   #{<<"parent">>:=PP,
									 <<"height">>:=HH} ->
									   [
										#{<<"t">> =><<"set">>,
										  <<"p">> => ChainPath++[<<"pre_parent">>],
										  <<"v">> => PP
										 },
										#{<<"t">> =><<"set">>,
										  <<"p">> => ChainPath++[<<"pre_height">>],
										  <<"v">> => HH
										 }];
								   _ ->
									   []
							   end,
						   IncPtr=[#{<<"t">> => <<"set">>,
									 <<"p">> => ChainPath++[<<"parent">>],
									 <<"v">> => ParentHash
									},
								   #{<<"t">> => <<"set">>,
									 <<"p">> => ChainPath++[<<"height">>],
									 <<"v">> => MyHeight
									}
								   |PCP ],
						   SyncPatch={PatchTxID, #{sig=>[],patch=>IncPtr}},
						   {
							settings:patch(SyncPatch,RealSettings),
							[SyncPatch|Settings]
						   }
				   end,
		NewAddresses=maps:put(From,NewF,Addresses),
		try_process(Rest,SS2,NewAddresses,GetFun,
					savefee(GotFee,
							Acc#{
							  settings=>Set2,
							  success=>[{TxID,Tx}|Success],
							  outbound=>[{TxID,OutTo}|Outbound]
							 })
				   )
	catch throw:X ->
			  try_process(Rest,SetState,Addresses,GetFun,
						  Acc#{failed=>[{TxID,X}|Failed]})
	end.

try_process_local([{TxID,
                    #{cur:=Cur,amount:=Amount,to:=To,from:=From}=Tx}
                   |Rest],
                  SetState, Addresses, GetFun,
                  #{success:=Success, failed:=Failed}=Acc) ->
    %lager:error("Check signature once again"),
    FBal=maps:get(From,Addresses),
    TBal=maps:get(To,Addresses),
	EnsureSettings=fun(undefined) -> GetFun(settings);
					  (SettingsReady) -> SettingsReady
				   end,

    try
		RealSettings=EnsureSettings(SetState),
		{NewF,GotFee}=withdraw(FBal,Tx,GetFun,RealSettings),
        NewTAmount=bal:get_cur(Cur,TBal) + Amount,
        NewT=maps:remove(keep,
                         bal:put_cur(
                           Cur,
                           NewTAmount,
                           TBal)
                        ),
        NewAddresses=maps:put(From,NewF,maps:put(To,NewT,Addresses)),

        try_process(Rest,SetState,NewAddresses,GetFun,
					savefee(GotFee,
							Acc#{success=>[{TxID,Tx}|Success]}
						   )
				   )
    catch throw:X ->
              try_process(Rest,SetState,Addresses,GetFun,
                          Acc#{failed=>[{TxID,X}|Failed]})
    end.

savefee({Cur, Fee, Tip}, #{fee:=FeeBal, tip:=TipBal}=Acc) ->
	Acc#{
	  fee=>bal:put_cur(Cur,Fee+bal:get_cur(Cur, FeeBal),FeeBal),
	  tip=>bal:put_cur(Cur,Tip+bal:get_cur(Cur, TipBal),TipBal)
	 }.

withdraw(FBal,
		 #{cur:=Cur,seq:=Seq,timestamp:=Timestamp,amount:=Amount,from:=From}=Tx,
		 GetFun, 
		 Settings
		) ->
	if Amount >= 0 ->
		   ok;
	   true ->
		   throw ('bad_amount')
	end,
	if is_integer(Timestamp) -> 
		   case GetFun({valid_timestamp,Timestamp}) of
			   true ->
				   ok;
			   false ->
				   throw ('invalid_timestamp')
		   end;
	   true -> throw ('non_int_timestamp')
	end,
	FSK=bal:get_cur(<<"SK">>,FBal),
	LD=bal:get(t,FBal) div 86400000,
	CD=Timestamp div 86400000,
	FSKUsed=if CD>LD ->
				   0;
			   true ->
				   bal:get(usk,FBal)
			end,
	if FSK < 1 -> 
		   case GetFun({endless,From,<<"SK">>}) of
			   true -> ok;
			   false -> throw('no_sk')
		   end;
	   FSKUsed >= FSK -> throw('sk_limit');
	   true -> ok
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
	NewBal=maps:remove(keep,
				bal:mput(
				  Cur,
				  NewFAmount,
				  Seq,
				  Timestamp,
				  FBal,
				  if CD>LD -> reset;
					 true -> true
				  end
				 )
			   ),
	GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
					  settings:get([<<"current">>,<<"fee">>,FeeCur],Settings);
				  ({params, Parameter}) ->
					  settings:get([<<"current">>,<<"fee">>,params,Parameter],Settings)
			  end,
	{FeeOK,#{cost:=MinCost}=Fee}=Rate=tx:rate(Tx, GetFeeFun),
	lager:info("Rate ~p",[Rate]),
	if FeeOK -> ok;
	   true -> throw ({'insufficient_fee',MinCost})
	end,
	#{cost:=FeeCost,tip:=Tip0,cur:=FeeCur}=Fee,
	if FeeCost == 0 ->
		   {NewBal, {Cur, 0, 0}};
	   true ->
		   Tip=case GetFeeFun({params,<<"notip">>}) of
				   1 -> 0;
				   _ -> Tip0
			   end,
		   FeeAmount=FeeCost+Tip,
		   CurFFeeAmount=bal:get_cur(FeeCur,NewBal),
		   NewFFeeAmount=if CurFFeeAmount >= FeeAmount ->
							 CurFFeeAmount - FeeAmount;
						 true ->
							 case GetFun({endless,From,FeeCur}) of
								 true ->
									 CurFFeeAmount - FeeAmount;
								 false ->
									 throw ('insufficient_fund_for_fee')
							 end
					  end,
		   NewBal2=bal:put_cur(FeeCur,
							   NewFFeeAmount,
							   NewBal
							  ),
		   {NewBal2, {FeeCur, FeeCost, Tip}}
	end.

sign(Blk,ED) when is_map(Blk) ->
    PrivKey=nodekey:get_priv(),
    block:sign(Blk,ED,PrivKey).

load_settings(State) ->
    OldSettings=maps:get(settings,State,#{}),
    MyChain=blockchain:get_settings(chain,0),
    AE=blockchain:get_settings(<<"allowempty">>,1),
    State#{
      settings=>maps:merge(
                  OldSettings,
                  #{ae=>AE, mychain=>MyChain}
                 )
     }.

generate_block(PreTXL,{Parent_Height,Parent_Hash},GetSettings,GetAddr,ExtraData) ->
	%file:write_file("tmp/tx.txt", io_lib:format("~p.~n",[PreTXL])),
	_T1=erlang:system_time(),
	TXL=lists:usort(PreTXL),
	_T2=erlang:system_time(),
	XSettings=GetSettings(settings),
	Addrs0=lists:foldl(
	  fun(default, Acc) ->
			  BinAddr=naddress:construct_private(0,0),
			  maps:put(BinAddr,
					   bal:fetch(BinAddr, <<"ANY">>, true, #{}, GetAddr),
					   Acc);
		 (Type, Acc) ->
			  case settings:get([<<"current">>,<<"fee">>,params,Type],XSettings) of
				  BinAddr when is_binary(BinAddr) ->
					  maps:put(BinAddr,
							   bal:fetch(BinAddr, <<"ANY">>, true, #{}, GetAddr),
							   Acc);
				  _ ->
					  Acc
			  end
	  end, #{}, [<<"feeaddr">>, <<"tipaddr">>, default]),

	Load=fun({_,#{hash:=_,header:=#{},txs:=Txs}},{AAcc0,SAcc}) ->
				 lager:info("TXs ~p",[Txs]),
				 {
				  lists:foldl(
					fun({_,#{to:=T,cur:=Cur}},AAcc) ->
							TB=bal:fetch(T, Cur, false, maps:get(T,AAcc,#{}), GetAddr),
							maps:put(T,TB,AAcc)
					end, AAcc0, Txs),
				  SAcc};
			({_,#{patch:=_}},{AAcc,SAcc}) ->
				 {AAcc,SAcc};
			({_,#{register:=_}},{AAcc,SAcc}) ->
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
				 {maps:put(F,FB,maps:put(T,TB,AAcc)),SAcc};
			(_,{AAcc,SAcc}) ->
				 {AAcc,SAcc}
		 end,
	{Addrs,_}=lists:foldl(Load, {Addrs0,undefined}, TXL),
	lager:info("MB Pre Setting ~p",[XSettings]),
	_T3=erlang:system_time(),
	#{failed:=Failed,
	  table:=NewBal0,
	  success:=Success,
	  settings:=Settings,
	  outbound:=Outbound,
	  pick_block:=PickBlocks,
	  fee:=_FeeCollected,
	  tip:=_TipCollected
	 }=try_process(TXL,XSettings,Addrs,GetSettings,
				   #{export=>[],
					 failed=>[],
					 success=>[],
					 settings=>[],
					 outbound=>[],
					 fee=>bal:new(),
					 tip=>bal:new(),
					 pick_block=>#{},
					 parent=>Parent_Hash,
					 height=>Parent_Height+1
					}
				  ),
	lager:info("Collected fee ~p tip ~p",[_FeeCollected, _TipCollected]),
	lager:info("MB Post Setting ~p",[Settings]),
	OutChains=lists:foldl(
				fun({_TxID,ChainID},Acc) ->
						maps:put(ChainID,maps:get(ChainID,Acc,0)+1,Acc)
				end, #{}, Outbound),
	lager:info("MB Outbound to ~p",[OutChains]),
	lager:info("MB Must pick blocks ~p",[maps:keys(PickBlocks)]),
	_T4=erlang:system_time(),
	NewBal1=maps:filter(
			  fun(_,V) ->
					  maps:get(keep,V,true)
			  end, NewBal0),
	NewBal=maps:map(
			 fun(_,V) ->
					 case maps:is_key(ublk,V) of
						 false ->
							 V;
						 true ->
							 bal:put(lastblk, maps:get(ublk,V), V)
					 end
			 end, NewBal1),
	ExtraPatch=maps:fold(
				 fun(ToChain,_NoOfTxs,AccExtraPatch) ->
						 [ToChain|AccExtraPatch]
				 end, [], OutChains),
	lager:info("MB Extra out settings ~p",[ExtraPatch]),

	%lager:info("MB NewBal ~p",[NewBal]),

	HedgerHash=ledger_hash(NewBal),
	_T5=erlang:system_time(),
	Blk=block:mkblock(#{
		  txs=>Success,
		  parent=>Parent_Hash,
		  mychain=>GetSettings(mychain),
		  height=>Parent_Height+1,
		  bals=>NewBal,
		  ledger_hash=>HedgerHash,
		  settings=>Settings,
		  tx_proof=>[ TxID || {TxID,_ToChain} <- Outbound ],
		  inbound_blocks=>lists:foldl(
							fun(PickID,Acc) ->
									[{PickID,
									  proplists:get_value(PickID,TXL)
									 }|Acc]
							end, [], maps:keys(PickBlocks)),
		  extdata=>ExtraData
		 }),
	_T6=erlang:system_time(),
	lager:info("Created block ~w ~s: txs: ~w, bals: ~w, LH: ~s, chain ~p",
			   [
				Parent_Height+1,
				block:blkid(maps:get(hash,Blk)),
				length(Success),
				maps:size(NewBal),
				bin2hex:dbin2hex(HedgerHash),
				GetSettings(mychain)
			   ]),
	lager:info("BENCHMARK txs       ~w~n",[length(TXL)]),
	lager:info("BENCHMARK sort tx   ~.6f ~n",[(_T2-_T1)/1000000]),
	lager:info("BENCHMARK pull addr ~.6f ~n",[(_T3-_T2)/1000000]),
	lager:info("BENCHMARK process   ~.6f ~n",[(_T4-_T3)/1000000]),
	lager:info("BENCHMARK filter    ~.6f ~n",[(_T5-_T4)/1000000]),
	lager:info("BENCHMARK mk block  ~.6f ~n",[(_T6-_T5)/1000000]),
	lager:info("BENCHMARK total ~.6f ~n",[(_T6-_T1)/1000000]),
	#{block=>Blk#{outbound=>Outbound},
	  failed=>Failed
	 }.

addrcheck(Addr) ->
    case naddress:check(Addr) of
        {true, #{type:=public}} ->
            case address_db:lookup(Addr) of
                {ok, Chain} ->
                    {true, {chain, Chain}};
                _ ->
                    unroutable
            end;
        {true, #{type:=private}} ->
            {true, private};
        _ ->
            bad_address
    end.

benchmark(N) ->
    Parent=crypto:hash(sha256,<<"123">>),
    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,
			248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
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
	_=generate_block( _Res,
					  {1,Parent},
					  GetSettings,
					  GetAddr,
					[]),

    T2=erlang:system_time(),
    (T2-T1)/1000000.

decode_tpic_txs(TXs) ->
    lists:map(
      fun({TxID,Tx}) ->
              {TxID, tx:unpack(Tx)}
      end, maps:to_list(TXs)).

-ifdef(TEST).
ledger_hash(NewBal) ->
    {ok,HedgerHash}=case whereis(ledger) of
                undefined ->
                    %there is no ledger. Is it test?
                    {ok,LedgerS1}=ledger:init([test]),
                    {reply,LCResp,_LedgerS2}=ledger:handle_call({check,[]},self(),LedgerS1),
                    LCResp;
                X when is_pid(X) ->
                    ledger:check(maps:to_list(NewBal))
            end,
    HedgerHash.
-else.
ledger_hash(NewBal) ->
    {ok,HedgerHash}=ledger:check(maps:to_list(NewBal)),
    HedgerHash.
-endif.


-ifdef(TEST).

alloc_addr_test() ->
    GetSettings=
    fun(mychain) ->
            0;
       (settings) ->
            #{chain => #{0 =>
                         #{blocktime => 10,
                           minsig => 2,
                           nodes => [<<"node1">>,<<"node2">>,<<"node3">>],
                           <<"allowempty">> => 0}
                        },
              chains => [0],
              globals => #{<<"patchsigs">> => 2},
              keys =>
              #{ <<"node1">> => crypto:hash(sha256,<<"node1">>),
                 <<"node2">> => crypto:hash(sha256,<<"node2">>),
                 <<"node3">> => crypto:hash(sha256,<<"node3">>),
                 <<"node4">> => crypto:hash(sha256,<<"node4">>)
               },
              nodechain => #{<<"node1">> => 0,
                             <<"node2">> => 0,
                             <<"node3">> => 0},
              <<"current">> => #{
                  <<"allocblock">> =>
                  #{<<"block">> => 2,<<"group">> => 10,<<"last">> => 0}
                 }
             };
       ({endless,_Address,_Cur}) ->
            false;
       (Other) ->
            error({bad_setting,Other})
    end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,
			248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    ParentHash=crypto:hash(sha256,<<"parent">>),
    Pub1=tpecdsa:secp256k1_ec_pubkey_create(Pvt1),

    TX0=tx:unpack( tx:pack( #{ type=>register, register=>Pub1 })),
    #{block:=Block,
	  failed:=Failed}=generate_block(
						[{<<"alloc_tx1_id">>,TX0},
						 {<<"alloc_tx2_id">>,TX0}],
						{1,ParentHash},
						GetSettings,
						GetAddr,
						[]),

    io:format("~p~n",[Block]),
    [
    ?assertEqual([], Failed),
    ?assertMatch(#{bals:=#{<<128,1,64,0,2,0,0,1>>:=_,<<128,1,64,0,2,0,0,1>>:=_}}, Block)
    ].


mkblock_test() ->
    OurChain=5,
	GetSettings=fun(mychain) ->
						OurChain;
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
					   },
					  <<"current">> => #{
						  <<"fee">> => #{
							  params=>#{
								<<"feeaddr">> => <<160,0,0,0,0,0,0,1>>,
								<<"tipaddr">> => <<160,0,0,0,0,0,0,2>>
							   },
							  <<"TST">> => #{
								  <<"base">> => 2,
								  <<"baseextra">> => 64, 
								  <<"kb">> => 20
								 },
							  <<"FTT">> => #{
								  <<"base">> => 1,
								  <<"baseextra">> => 64, 
								  <<"kb">> => 10
								 }
							 }
						 }
					 };
				   ({endless,_Address,_Cur}) ->
						false;
				   ({valid_timestamp,TS}) ->
						abs(os:system_time(millisecond)-TS)<3600000 
						orelse
						abs(os:system_time(millisecond)-(TS-86400000))<3600000; 
				   (Other) ->
						error({bad_setting,Other})
				end,
    GetAddr=fun test_getaddr/1,

    Pvt1= <<194,124,65,109,233,236,108,24,50,151,189,216,23,42,215,220,24,240,
			248,115,150,54,239,58,218,221,145,246,158,15,210,165>>,
    ParentHash=crypto:hash(sha256,<<"parent">>),
	SG=3,

	TX0=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>10,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>2, feecur=><<"FTT">> }),
			seq=>2,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),
	TX1=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,8),
			amount=>9000,
			cur=><<"BAD">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
			seq=>3,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),

	TX2=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain+2,1),
			amount=>9,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
			seq=>4,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),
	TX3=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain+2,2),
			amount=>2,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
			seq=>5,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),
	TX4=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(0,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>10,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
			seq=>6,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),
	TX5=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>1,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">> }),
			seq=>7,
			timestamp=>os:system_time(millisecond)
		   },Pvt1)
		 ),
	TX6=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>1,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>3, feecur=><<"TST">> }),
			seq=>8,
			timestamp=>os:system_time(millisecond)+86400000
		   },Pvt1)
		 ),
	TX7=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>1,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>1, feecur=><<"FTT">>, 
									 big=><<"11111111111111111111111111",
											"11111111111111111111111111",
											"11111111111111111111111111",
											"11111111111111111111111111",
											"11111111111111111111111111",
											"11111111111111111111111111">>
								   }),
			seq=>9,
			timestamp=>os:system_time(millisecond)+86400000
		   },Pvt1)
		 ),
	TX8=tx:unpack( 
		  tx:sign(
			#{
			from=>naddress:construct_public(SG,OurChain,3),
			to=>naddress:construct_public(1,OurChain,3),
			amount=>1,
			cur=><<"FTT">>,
			extradata=>jsx:encode(#{ fee=>200, feecur=><<"FTT">> }),
			seq=>9,
			timestamp=>os:system_time(millisecond)+86400000
		   },Pvt1)
		 ),
	#{block:=Block,
	  failed:=Failed}=generate_block(
						[
						 {<<"1interchain">>,TX0},
						 {<<"2invalid">>,TX1},
						 {<<"3crosschain">>,TX2},
						 {<<"4crosschain">>,TX3},
						 {<<"5nosk">>,TX4},
						 {<<"6sklim">>,TX5},
						 {<<"7nextday">>,TX6},
						 {<<"8nofee">>,TX7},
						 {<<"9nofee">>,TX8}
						],
						{1,ParentHash},
						GetSettings,
						GetAddr,
					   []),

	Success=proplists:get_keys(maps:get(txs,Block)),
	?assertMatch([{<<"2invalid">>,insufficient_fund},
				  {<<"5nosk">>,no_sk},
				  {<<"6sklim">>,sk_limit},
				  {<<"8nofee">>,{insufficient_fee,2}},
				  {<<"9nofee">>,insufficient_fund_for_fee}
				 ], lists:sort(Failed)),
	?assertEqual([
				  <<"1interchain">>,
				  <<"3crosschain">>,
				  <<"4crosschain">>,
				  <<"7nextday">>], 
				 lists:sort(Success)),
	?assertEqual([
				  <<"3crosschain">>,
				  <<"4crosschain">>
				 ],
				 proplists:get_keys(maps:get(tx_proof,Block))
				),
	?assertEqual([
				  {<<"4crosschain">>,OurChain+2},
				  {<<"3crosschain">>,OurChain+2}
				 ],
				 maps:get(outbound,Block)
				),
	SignedBlock=block:sign(Block,<<1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1>>),
	file:write_file("tmp/testblk.txt", io_lib:format("~p.~n",[Block])),
	?assertMatch({true, {_,_}},block:verify(SignedBlock)),
	lager:info("FSK B ~p",[proplists:get_keys(maps:get(txs,Block))]),
	_=maps:get(OurChain+2,block:outward_mk(maps:get(outbound,Block),SignedBlock)),
	#{bals:=NewBals}=Block,
	?assertMatch(#{<<160,0,0,0,0,0,0,1>>:=#{amount:=#{<<"FTT">>:=103,<<"TST">>:=102}}}, NewBals),
	?assertMatch(#{<<160,0,0,0,0,0,0,2>>:=#{amount:=#{<<"FTT">>:=101,<<"TST">>:=101}}}, NewBals),
	NewBals.

%test_getaddr%({_Addr,_Cur}) -> %suitable for inbound tx
test_getaddr(Addr) ->
	case naddress:parse(Addr) of
		#{address:=_,block:=_,group:=Grp,type:=public} ->
			#{amount => #{ <<"FTT">> => 110, <<"SK">> => Grp, <<"TST">> => 26 },
			  seq => 1,
			  t => 1512047425350,
			  lastblk => <<0:64>>
			 };
		#{address:=_, block:=_, type := private} ->
			#{amount => #{ 
				<<"FTT">> => 100, 
				<<"TST">> => 100 
			   },
			  lastblk => <<0:64>>
			 }
	end.

xchain_inbound_test() ->
	BlockTx={bin2hex:dbin2hex(
               <<210,136,133,138,53,233,33,79,75,12,212,35,130,40,68,210,73,37,251,211,
                 204,69,65,165,76,171,250,21,89,208,120,119>>),
             #{
               hash => <<210,136,133,138,53,233,33,79,75,12,212,35,130,40,68,210,73,37,251,211,
                         204,69,65,165,76,171,250,21,89,208,120,119>>,
               header => #{
                 balroot => <<53,27,182,176,168,205,168,137,118,192,113,80,26,8,168,161,225,
                              192,179,64,42,131,107,119,228,179,70,213,97,142,22,75>>,
                 height => 3,
                 ledger_hash => <<126,177,211,108,143,33,252,102,28,174,183,241,224,199,53,212,190,
                                  109,9,102,244,128,148,2,141,113,34,173,88,18,54,167>>,
                 parent => <<209,98,117,147,242,200,255,92,65,98,40,145,134,56,237,108,111,31,
                             204,11,199,110,119,85,228,154,171,52,57,169,193,128>>,
                 txroot => <<160,75,167,93,173,15,76,7,206,105,125,171,71,71,73,183,152,20,1,
                             204,255,238,56,119,48,182,3,128,120,199,119,132>>},
               sign => [
                        #{binextra => <<2,33,3,20,168,140,163,14,5,254,154,92,115,194,121,240,35,86,153,
                                        104,127,21,35,19,190,200,202,242,232,101,102,255,67,64,4,1,8,0,
                                        0,1,97,216,215,132,30,3,8,0,0,0,0,0,54,225,28>>,
                          extra => [
                                    {pubkey,<<3,20,168,140,163,14,5,254,154,92,115,194,121,240,35,
                                              86,153,104,127,21,35,19,190,200,202,242,232,101,102,
                                              255,67,64,4>>},
                                    {timestamp,1519761458206},
                                    {createduration,3596572}],
                          signature => <<48,69,2,32,46,71,177,112,252,81,176,202,73,216,45,248,150,187,
                                         65,47,123,172,210,59,107,36,166,151,105,73,39,153,189,162,165,
                                         12,2,33,0,239,133,205,191,10,54,223,131,75,133,178,226,150,62,
                                         90,197,191,170,185,190,202,84,234,147,154,200,78,180,196,145,
                                         135,30>>},
                        #{
                            binextra => <<2,33,2,242,87,82,248,198,80,15,92,32,167,94,146,112,70,81,54,
                                          120,236,25,141,129,124,215,7,210,142,51,139,230,86,0,245,1,8,0,
                                          0,1,97,216,215,132,25,3,8,0,0,0,0,0,72,145,55>>,
                            extra => [
                                      {pubkey,<<2,242,87,82,248,198,80,15,92,32,167,94,146,112,70,81,
                                                54,120,236,25,141,129,124,215,7,210,142,51,139,230,86,
                                                0,245>>},
                                      {timestamp,1519761458201},
                                      {createduration,4755767}],
                            signature => <<48,69,2,33,0,181,13,206,186,91,46,248,47,86,203,119,163,182,
                                           187,224,19,148,186,230,192,77,37,78,34,159,0,129,20,44,94,100,
                                           222,2,32,17,113,133,105,203,59,196,83,152,48,93,234,94,203,
                                           198,204,37,71,163,102,116,222,108,244,177,171,121,241,78,236,
                                           20,49>>}
                       ],
               tx_proof => [
                            {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                             {<<140,165,20,175,211,221,34,143,206,26,228,214,78,239,204,117,248,243,
                                84,232,154,163,25,31,161,244,123,77,137,49,211,190>>,
                              <<227,192,87,99,22,171,181,153,82,253,22,226,105,155,190,217,40,
                                167,35,76,231,83,145,17,235,226,202,176,88,112,164,75>>}}],
               txs => [
                       {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                        #{amount => 10,cur => <<"FTT">>,
                          extradata =>
                          <<"{\"message\":\"preved from test_xchain_tx to AA100000001677721780\"}">>,
                          from => <<128,1,64,0,2,0,0,1>>,
                          seq => 1,
                          sig =>
                          #{<<3,106,33,240,104,190,146,105,114,104,182,13,150,196,202,147,
                              5,46,193,4,228,158,0,58,226,196,4,249,22,134,67,114,244>> =>
                            <<48,69,2,33,0,137,129,11,184,226,47,248,169,88,87,235,54,
                              114,41,218,54,208,110,177,156,86,154,57,168,248,135,234,
                              133,48,122,162,159,2,32,111,74,165,165,165,20,39,231,
                              137,198,69,97,248,202,129,61,131,85,115,106,71,105,254,
                              113,106,128,151,224,154,162,163,161>>},
                          timestamp => 1519761457746,
                          to => <<128,1,64,0,1,0,0,1>>,
                          type => tx}}]}
            },

    ParentHash= <<0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3>>,
    GetSettings=fun(mychain) ->
                        1;
                   (settings) ->
                        #{chain =>
                          #{1 => #{blocktime => 2,minsig => 2,<<"allowempty">> => 0},
                            2 => #{blocktime => 2,minsig => 2,<<"allowempty">> => 0}},
                          chains => [1,2],
                          globals => #{<<"patchsigs">> => 4},
                          keys =>
                          #{<<"c1n1">> =>
                            <<2,6,167,57,142,3,113,35,25,211,191,20,246,212,125,250,157,15,147,
                              0,243,194,122,10,100,125,146,90,94,200,163,213,219>>,
                            <<"c1n2">> =>
                            <<3,49,215,116,73,54,27,41,144,13,76,183,209,15,238,61,231,222,154,
                              116,37,161,113,159,2,37,130,166,140,176,51,183,170>>,
                            <<"c1n3">> =>
                            <<2,232,199,219,27,18,156,224,149,39,153,173,87,46,204,64,247,2,
                              124,209,4,156,168,33,95,67,253,87,225,62,85,250,63>>,
                            <<"c2n1">> =>
                            <<3,20,168,140,163,14,5,254,154,92,115,194,121,240,35,86,153,104,
                              127,21,35,19,190,200,202,242,232,101,102,255,67,64,4>>,
                            <<"c2n2">> =>
                            <<3,170,173,144,22,230,53,155,16,61,0,29,207,156,35,78,48,153,163,
                              136,250,63,111,164,34,28,239,85,113,11,33,238,173>>,
                            <<"c2n3">> =>
                            <<2,242,87,82,248,198,80,15,92,32,167,94,146,112,70,81,54,120,236,
                              25,141,129,124,215,7,210,142,51,139,230,86,0,245>>},
                          nodechain =>
                          #{<<"c1n1">> => 1,<<"c1n2">> => 1,<<"c1n3">> => 1,
                            <<"c2n1">> => 2,<<"c2n2">> => 2,<<"c2n3">> => 2},
                          <<"current">> =>
                          #{<<"allocblock">> =>
                            #{<<"block">> => 1,<<"group">> => 10,<<"last">> => 1}}};
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    GetAddr=fun test_getaddr/1,

    #{block:=#{hash:=NewHash,
               header:=#{height:=NewHeight}}=Block,
      failed:=Failed}=generate_block(
                        [BlockTx],
                        {1,ParentHash},
                        GetSettings,
                        GetAddr,
					   []),

%        SS1=settings:patch(AAlloc,SetState),
    GetSettings2=fun(mychain) ->
                        1;
                   (settings) ->
                         lists:foldl(
                           fun(Patch, Acc) ->
                                   settings:patch(Patch,Acc)
                           end, GetSettings(settings), maps:get(settings,Block));
                   ({endless,_Address,_Cur}) ->
                        false;
                   (Other) ->
                        error({bad_setting,Other})
                end,
    #{block:=Block2,
      failed:=Failed2}=generate_block(
                         [BlockTx],
                         {NewHeight,NewHash},
                         GetSettings2,
                         GetAddr,
						[]),

    [
    ?assertEqual([], Failed),
    ?assertMatch([
                  {<<"151746FE691E15EA-34oMyXcpay8pDeuEUGRsdqLp25aC-03">>,
                   #{amount:=10}
                  }
                 ], maps:get(txs,Block)),
    ?assertMatch(#{amount:=#{<<"FTT">>:=120}},
                 maps:get(<<128,1,64,0,1,0,0,1>>,maps:get(bals,Block))
                ),
    ?assertMatch([], maps:get(txs,Block2)),
    ?assertMatch([{_,{overdue,_}}], Failed2)
    ].

-endif.

