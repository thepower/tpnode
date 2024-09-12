-module(process_txs).
-export([
		 process_tx/3, %process with gas and fee calculation
		 process_tx/4,
		 process_itx/7,
		 new_state/2
		]).
-include("include/tplog.hrl").

new_state(GetFun, GetFunArg) ->
	S0=pstate:new_state(GetFun, GetFunArg),
	S0#{
	  transaction_result => [],
	  transaction_receipt => [],
	  tstorage => #{},
	  log => []
	 }.

%process_tx(Tx#{txex, State0, _Opts) ->
%Ext=maps:get(txext,Tx,#{}),
%    BSponsor=maps:get("sponsor",Ext,undefined),
%    ?LOG_INFO("Processing local =====[ ~s ]======= ~s -> ~s",[TxID,hex:encode(From),hex:encode(To)]),
%    Sponsor=case BSponsor of
%              [<<SpAddr:8/binary>>] ->
%                MyChain=GetFun(mychain),
%                {true,{chain,SChain}}=addrcheck(SpAddr, SetState, MyChain),
%                if(SChain==MyChain) ->
%                    SpAddr;
%                  true ->
%                    false
%                end;
%              undefined -> false;
%              Other ->
%                ?LOG_ERROR("Invalid sponsor ~p",[Other]),
%                throw('invalid_sponsor')
%            end,
%    RSp=if is_binary(Sponsor) ->
%         case maps:is_key(Sponsor, Addresses) of
%           false ->
%             throw('sponsor_not_loaded');
%           true ->
%             SPAcc=maps:get(Sponsor, Addresses),
%             case contract_evm:ask_ERC165(Sponsor,<<16#1B,16#97,16#71,16#2B>>,GetAddr) of
%               true ->
%                 ask_if_wants_to_pay(SPAcc, Tx, 30000,Sponsor);
%               false ->
%                 IsSponsor=ask_if_sponsor(SPAcc),
%                 case IsSponsor of
%                   {true, {Token, Amount}} ->
%                     case to_gas(#{amount=>Amount, cur=>Token}, SetState) of
%                       {ok, {_Tkn,TknAm,{Num,Den}}} ->
%                         ?LOG_NOTICE("fixme: save gas here"),
%                         ask_if_wants_to_pay(SPAcc, Tx, (TknAm*Num) div Den,Sponsor);
%                       _ ->
%                         {false, invalid_gas_specified}
%                     end;
%                   _ ->
%                     {false, no_sponsor}
%                 end
%             end
%         end;
%       true ->
%         false
%    end,
%    case RSp of
%      {ok, SPData} ->
%        ?LOG_INFO("sponsoring ~p from ~p",[SPData,Sponsor]);
%      {false,N} when is_binary(Sponsor) ->
%        ?LOG_NOTICE("not sponsoring from ~p: ~p",[Sponsor,N]);
%      _ ->
%        ok
%    end,

process_tx(#{from:=From}=Tx, State0, Opts) ->
	try
	SettingsToLoad=#{
			   freegas => [<<"freegas2">>,maps:get(to,Tx,undefined)],
			   fee => [ <<"fee">> ],
			   gas => [ <<"gas">> ]
			  },
	ChainSettingsAddress=maps:get(chainsettings_address,Opts,<<0>>),

	{State1, LoadedSettings}=maps:fold(
					fun(Opt, Path, {CState,Acc}) ->
							{Val, _, CState1} = pstate:get_state(ChainSettingsAddress, lstore, Path, CState),
							{CState1, maps:put(Opt,Val,Acc)}
					end, {State0,#{}}, SettingsToLoad),
	FeeSettings=maps:get(fee, LoadedSettings),
	FeeReceiver=case lstore:get([<<"params">>, <<"feeaddr">>],FeeSettings) of
					FeeReceiver1 when is_binary(FeeReceiver1) -> FeeReceiver1;
					_ -> <<0>>
				end,

	State2=if FeeReceiver == <<0>> -> %no fee address or invlid type, no take fee
				   State1;
			  true ->
				  GetFeeFun=fun (FeeCur) when is_binary(FeeCur) ->
									lstore:get([FeeCur],FeeSettings);
								({params, Parameter}) ->
									lstore:get([<<"params">>, Parameter],FeeSettings)
							end,
				  case tx:rate(Tx, GetFeeFun) of
					  {false, #{cost:=MinCost,cur:=Cur}} ->
						  throw(<<"insufficient_fee:",
								  (integer_to_binary(MinCost))/binary,
								  " ",Cur/binary>>);
					  {false, _} ->
						  throw(<<"insufficient_fee">>);
					  {true, #{cost:=MinCost, cur:=Cur, sponsor:=Sponsor}} ->
						  transfer(Sponsor, FeeReceiver, MinCost, Cur, State1);
					  {true, #{cost:=MinCost, cur:=Cur}} ->
						  transfer(From, FeeReceiver, MinCost, Cur, State1)
				  end
		   end,
	FreeGas=case maps:get(freegas, LoadedSettings) of
				N1 when is_integer(N1), N1>0 -> N1;
				_ -> 0
			end,
	GasPayloads=tx:get_payloads(Tx,gas),
	io:format("GasPayloads ~p~n", [GasPayloads]),

	GasSettings=maps:get(gas, LoadedSettings),
	{State3,Taken,GasLimit}=lists:foldl(
						 fun(#{amount:=0, cur:= <<"NORUN">>}, _) ->
								 {State2, [], norun};
							(_,{_,_,norun}=A) ->
								A; 
							(Payload, {_CState, _T, _GasAcc}=A) ->
								 to_gas(maps:merge(
										  #{sponsor=>From},
										  Payload), GasSettings, A)
						 end,
						 {State2, [], FreeGas},
						 GasPayloads
						),

	io:format("Gas collected ~p~n", [GasLimit]),
	io:format("Taken ~p~n", [Taken]),

	
	try
		{Valid, Data, GasLeft, State4} = process_tx(Tx, GasLimit, State3, Opts),

		{GasLeft2, Collected, State5}  = return_gas(GasLeft, Taken, State4, []),
		io:format("Gas left ~p~n", [GasLeft]),
		io:format("Gas left2 ~p / ~p~n", [GasLeft2, Collected]),
		State6 = lists:foldl(
		  fun(Token, State) ->
				  {Src0, _, _} = pstate:get_state(<<"escrow">>, balance, Token, State),
				  transfer(<<"escrow">>, FeeReceiver, Src0, Token, State)
		  end, State5, Collected),

		{Valid, Data, State6}

	catch throw:Reason1 when is_atom(Reason1) -> 
			  % in case of something went wrong, take only fee, and return gas
			  {0, atom_to_binary(Reason1, utf8), State2};
		  throw:Reason1 when is_binary(Reason1) -> 
			  % in case of something went wrong, take only fee, and return gas
			  {0, Reason1, State2}
	end


	catch throw:Reason when is_atom(Reason) -> 
			  {0, atom_to_binary(Reason, utf8), State0};
		  throw:Reason when is_binary(Reason) -> 
			  {0, Reason, State0}
	end.

return_gas(GasLeft, [], State, Acc) ->
	{GasLeft, Acc, State};
return_gas(GasLeft, [#{g:=TotalG, amount:=A, cur:=C, sponsor:=Sponsor}=P|Rest], State, Acc) when GasLeft > TotalG ->
	return_gas(GasLeft-TotalG,
			   Rest,
			   transfer(<<"escrow">>, Sponsor, A, C, State),
			   Acc
			  );
return_gas(GasLeft, [#{k:={N,D}, amount:=A, cur:=C, sponsor:=Sponsor}=P|Rest], State, Acc) ->
	ReturnTokens=min(trunc(GasLeft*D/N),A),
	ReturnGas=ReturnTokens*N div D,

	io:format("gas left ~p return ~p / ~p ~p to ~p~n",
			  [GasLeft, ReturnGas, ReturnTokens, C, Sponsor]),

	return_gas(GasLeft-ReturnGas,
			   Rest,
			   transfer(<<"escrow">>, Sponsor, ReturnTokens, C, State),
			   [C|Acc]
			  ).

to_gas(#{sponsor:=Sponsor, amount:=A, cur:=C}=Payload, GasSettings, {CState, T, GasAcc}) ->
	case to_gas1(Payload,GasSettings) of
		{ok, P1, G} when G>0 ->
			{
			transfer(Sponsor, <<"escrow">>, A, C, CState),
			[P1|T], GasAcc+G
			};
		_ ->
			{CState, T, GasAcc}
	end.

to_gas1(#{amount:=A, cur:=C}=P, Settings) ->
	case lstore:get([C], Settings) of
		#{<<"tokens">> := T, <<"gas">> := G} when is_integer(T),
												  is_integer(G) ->
			Gas=A*G div T,
			{ok, P#{k=>{G,T}, g=>Gas}, Gas};
		G when is_integer(G) ->
			Gas=A*G,
			{ok, P#{k=>{G,1}, g=>Gas}, Gas};
		_ ->
			error
	end.



% --- internal process_tx

process_tx(#{from:=From, to:=To}=Tx,
		   GasLimit, State0, Opts) ->
	Value=tx_value(Tx,<<"SK">>),
	State1=lists:foldl(
			 fun(#{amount:=Amount,cur:=Cur,purpose:=_},StateC) ->
					 transfer(From, To, Amount, Cur, StateC)
			 end,
			 State0#{cur_tx=>Tx},
			 tx:get_payloads(Tx, transfer) -- [tx:get_payload(Tx, transfer)]
			),
	%transfer all except first SK transfer, which will be transfered in process_itx

	CD=tx_cd(Tx),
	{Valid, Return, GasLeft, State2} = process_itx(
										 From,
										 To,
										 Value,
										 CD,
										 GasLimit,
										 State1,
										 Opts
										),

	{Valid, Return, GasLeft,
	 maps:without([cur_tx,tstorage], State2)
	};

process_tx(#{from:=From,
			 seq:=Nonce,
			 kind:=deploy,
			 txext:=#{
					  "code":=Code,
					  "vm":="evm"
					 }
			}=Tx,
		   GasLimit, State, Opts) when is_binary(Code) ->
	Value=tx_value(Tx,<<"SK">>),
	D2Hash=erlp:encode([From,binary:encode_unsigned(Nonce)]),
	{ok,<<_:12/binary,Address:20/binary>>}=ksha3:hash(256, D2Hash),
	io:format("Deploy to address ~p~n",[Address]),
	case process_code_itx(Code, From, Address,
						  Value, <<>>, GasLimit-3200, State#{cur_tx=>Tx}, Opts) of
		{1, DeployedCode, GasLeft, Xtra1} ->
			State2=pstate:set_state(Address, code, [], DeployedCode, Xtra1),
			{1, <<>>, GasLeft,
			 maps:without([cur_tx,tstorage], State2)
			};
		{0, _, GasLeft, _} ->
			{1, <<>>, GasLeft,
			 maps:without([cur_tx,tstorage], State)
			}
	end;

process_tx(#{
			 ver:=2,
			 kind:=lstore,
			 from:=Owner,
			 patches:=Patch
			}=_Tx,
		   GasLimit, State, _Opts) ->
	LSP=lists:map(
		  fun(#{<<"t">>:=<<"set">>, <<"p">>:=Path, <<"v">>:=Val}) ->
				  {Path, set, Val};
			 (#{<<"t">>:=<<"delete">>, <<"p">>:=Path, <<"v">>:=Val}) ->
				  {Path, delete, Val};
			 (#{<<"t">>:=<<"compare">>, <<"p">>:=Path, <<"v">>:=Val}) ->
				  {Path, compare, Val};
			 (#{<<"t">>:=<<"exist">>, <<"p">>:=Path}) ->
				  {Path, exists, null};
			 (#{<<"t">>:=<<"nonexist">>, <<"p">>:=Path}) ->
				  {Path, nonexists, null}
		  end, Patch),
	case pstate_lstore:patch(Owner, LSP, State) of
		{ok, State1} ->
			{1, <<>>, GasLimit, State1};
		{error, Reason} ->
			{0, atom_to_binary(Reason), GasLimit, State}
	end;


process_tx(_Tx, _GasLimit, _State, _Opts) ->
	throw('invalid_tx').

process_itx(From, To, Value, CallData, GasLimit, #{acc:=_}=State0, Opts) ->
	{ok, Code, State1, _} = evm_code(binary:decode_unsigned(To), State0, #{}),
	process_code_itx(Code, From, To, Value, CallData, GasLimit, State1, Opts).

process_code_itx(<<>>,From, To, Value, _CallData, GasLimit, #{acc:=_}=State0, _Opts) ->
	State1=transfer(From, To, Value, <<"SK">>, State0),
	{ 1, <<>>, GasLimit, State1};

process_code_itx(Code,From, To, Value, CallData, GasLimit, #{acc:=_}=State0, _Opts) ->
	State1=transfer(From, To, Value, <<"SK">>, State0),
	Result = eevm:eval(Code, #{},
					   #{
						 gas=>GasLimit,
						 sload=>fun evm_sload/4,
						 sstore=>fun evm_sstore/5,
						 custom_call => fun evm_custom_call/7,
						 extra=>State1,
						 bad_instruction=>fun evm_instructions/2,
						 return=><<>>,
						 get=>#{
								code => fun evm_code/3,
								balance => fun evm_balance/3
							   },
						 %create => CreateFun,
						 data=>#{
								 address=>binary:decode_unsigned(To),
								 callvalue=>Value,
								 caller=>binary:decode_unsigned(From),
								 gasprice=>1,
								 origin=>binary:decode_unsigned(From)
								},
						 cd => CallData,
						 logger=>fun evm_logger/4,
						 trace=>whereis(eevm_tracer)
						}),

	?LOG_INFO("Call ~s (~s) ret {~p,~p,...}",
			  [hex:encodex(To), hex:encode(CallData),
			   element(1,Result),element(2,Result)
			  ]),
	case Result of
		{done, {return,RetVal}, #{gas:=GasLeft, extra:=State3}} ->
			{ 1, RetVal, GasLeft, State3};
		{done, 'stop', #{gas:=GasLeft, extra:=State3}} ->
			{ 1, <<>>, GasLeft, State3};
		{done, 'eof', #{gas:=GasLeft, extra:=State3}} ->
			{ 1, <<>>, GasLeft, State3};
		{done, 'invalid', #{gas:=GasLeft, extra:=_FailState}} ->
			{ 0, <<>>, GasLeft,
			  append_log(
				[<<"evm:invalid">>,To,From,<<>>],
				State1)
			};
		{done, {revert, Revert}, #{ gas:=GasLeft}} ->
			{ 0, Revert, GasLeft,
			  append_log(
				[<<"evm:revert">>,To,From,Revert],
				State1)
			};
		{error, nogas, #{}} ->
			{ 0, <<>>, 0,
			  append_log(
				[<<"evm:nogas">>,To,From,<<>>],
				State1)};
		{error, {jump_to,_}, #{gas:=GasLeft}} ->
			{ 0, <<>>, GasLeft,
			  append_log(
				[<<"evm:bad_jump">>,To,From,<<>>],
				State1)
			};
		{error, {bad_instruction,I}, #{pc:=PC}} ->
			{ 0, <<>>, 0,
			  append_log(
				[<<"evm:bad_instruction">>,To,From,
				 list_to_binary(
				   io_lib:format("~p@~w",[I,PC])
				  )
				],
				State1)
			}
	end.

append_log(LogEntry, #{log:=PreLog}=State) ->
	State#{log=>[LogEntry|PreLog]}.

tx_value(#{payload:=_}=Tx, Cur) ->
	case tx:get_payload(Tx, transfer) of
		undefined ->
			0;
		#{amount:=A,cur:=TxCur} when TxCur==Cur ->
			A;
		_ ->
			0
	end.


tx_cd(#{call:=#{function:="0x0",args:=[Arg1]}}) when is_binary(Arg1) ->
	Arg1;
tx_cd(#{call:=#{function:=FunNameID,args:=CArgs}}) when is_list(FunNameID),
														is_list(CArgs) ->
	BinFun=list_to_binary(FunNameID),
	{ok,<<X:4/binary,_/binary>>}=ksha3:hash(256, BinFun),
	{ok,{{function,_},FABI,_}} = contract_evm_abi:parse_signature(BinFun),
	true=(length(FABI)==length(CArgs)),
	BArgs=contract_evm_abi:encode_abi(CArgs,FABI),
	<<X:4/binary,BArgs/binary>>;
tx_cd(_) ->
	<<>>.


evm_instructions(chainid, #{stack:=Stack}=BIState) ->
	BIState#{stack=>[16#c0de00000000|Stack]};
evm_instructions(number,#{stack:=BIStack}=BIState) ->
	BIState#{stack=>[100+1|BIStack]};
evm_instructions(timestamp,#{stack:=BIStack}=BIState) ->
	MT=1,
	BIState#{stack=>[MT|BIStack]};
evm_instructions(selfbalance,#{stack:=BIStack,data:=#{address:=MyAddr},extra:=#{global_acc:=#{table:=CurT}}}=BIState) ->
	%TODO: hot preload
	MyAcc=maps:get(binary:encode_unsigned(MyAddr),CurT),
	BIState#{stack=>[mbal:get_cur(<<"SK">>, MyAcc)|BIStack]};

evm_instructions(create, #{stack:=[Value,MemOff,Len|Stack],
						   memory:=RAM,
						   gas:=G,
						   extra:=#{acc:=_}=Xtra}=BIState) ->
  case Xtra of
	  #{cur_tx:=#{from:=SrcAddr, seq:=Nonce}} ->
		  Code=eevm_ram:read(RAM,MemOff,Len),
		  D2Hash=erlp:encode([SrcAddr,binary:encode_unsigned(Nonce)]),
		  {ok,<<_:12/binary,Address:20/binary>>}=ksha3:hash(256, D2Hash),
		  io:format("Deploy to address ~p~n",[Address]),
		  createX(Address, Code, Value, BIState#{stack=>Stack});
	  _ ->
		  BIState#{stack=>[0|Stack], gas=>G, extra=>Xtra}
  end;

evm_instructions(create2, #{stack:=[Value,MemOff,Len,Salt|Stack],
							data:=#{address:=From},
							memory:=RAM,
							extra:=#{acc:=_}}=BIState) ->
	Code=eevm_ram:read(RAM,MemOff,Len),
	{ok,CodeHash}=ksha3:hash(256, Code),
	D2Hash= <<255, From:160/big, Salt:256/big, CodeHash>>,
	{ok,<<_:12/binary,Address:20/binary>>}=ksha3:hash(256, D2Hash),
	io:format("Deploy to address ~p~n",[Address]),
	createX(Address, Code, Value, BIState#{stack=>Stack});

evm_instructions(tload, #{stack:=[Addr|Stack],
						  data:=#{address:=From},
						  gas:=G,
						  extra:=#{tstorage:=TSM}}=BIState) ->
	BIState#{stack=>[maps:get({From,Addr},TSM,0)|Stack], gas=>G-100};

evm_instructions(tstore, #{stack:=[Addr,Value|Stack],
						  data:=#{address:=From},
						  gas:=G,
						  extra:=#{tstorage:=TSM}=Extra}=BIState) ->
	BIState#{stack=>Stack,
			 extra=>Extra#{
					  tstorage=>maps:put({From,Addr},Value,TSM)
					 },
			 gas=>G-100};

evm_instructions(BIInstr,BIState) ->
	logger:error("Bad instruction ~p",[BIInstr]),
	{error,{bad_instruction,BIInstr},BIState}.

createX(Address, Code, Value, #{stack:=Stack, data:=#{address:=From}, gas:=G, extra:=Xtra}=BIState) ->
	case process_code_itx(Code, binary:encode_unsigned(From), Address,
						  Value, <<>>, G-3200, Xtra, []) of
		{1, DeployedCode, GasLeft, Xtra1} ->
			Xtra2=pstate:set_state(Address, code, [], DeployedCode, Xtra1),
			BIState#{stack=>[binary:decode_unsigned(Address)|Stack], gas=>GasLeft, extra=>Xtra2};
		{0, _, GasLeft, _} ->
			BIState#{stack=>[0|Stack], gas=>GasLeft, extra=>Xtra}
	end.

transfer(_, _, 0, _Cur, State) ->
	State;
transfer(From, To, Value, Cur, State0) when Value > 0 ->
	%get_state(From, balance, <<"SK">>, Acc, GetFun, GFA)
	{Src0, _, State1} = pstate:get_state(From, balance, Cur, State0),
	{Dst0, _, State2} = pstate:get_state(To, balance, Cur, State1),
	Src1=Src0-Value,
	if(Src1<0) -> throw(insuffucient_fund); true -> ok end,
	Dst1=Dst0+Value,
	State3=pstate:set_state(From, balance, Cur, Src1, State2),
	pstate:set_state(To, balance, Cur, Dst1, State3).


evm_balance(IAddr, State, _) ->
	{Value, Cached, State2} = pstate:get_state(binary:encode_unsigned(IAddr),
										balance,
										<<"SK">>,
										State),
	{'ok', Value, State2, not Cached}.

evm_code(IAddr, State, _) ->
	{Value, Cached, State2} = pstate:get_state(binary:encode_unsigned(IAddr),
											   code,
											   [],
											   State),
	{'ok', Value, State2, not Cached}.


evm_sload(IAddr, IKey, State, _) ->
	{Value, Cached, State2} = pstate:get_state(binary:encode_unsigned(IAddr),
											   storage,
											   binary:encode_unsigned(IKey),
											   State),
	{'ok', binary:decode_unsigned(Value), State2, not Cached}.


evm_sstore(IAddr, IKey, IValue, State, _) ->
	{OldValue, _, State2} = pstate:get_state(
							  binary:encode_unsigned(IAddr),
							  storage,
							  binary:encode_unsigned(IKey),
							  State),
	State3 = pstate:set_state(
			   binary:encode_unsigned(IAddr),
			   storage,
			   binary:encode_unsigned(IKey),
			   binary:encode_unsigned(IValue),
			   State2
			  ),
	{'ok', State3, OldValue=/=<<>>}.

evm_custom_call(CallType, IFrom, ITo, Value, CallData, Gas, Extra) ->
	Static=case CallType of
			   staticcall -> true;
			   delegatecall -> false;
			   callcode -> false;
			   call -> false
		   end,
	process_itx(binary:encode_unsigned(IFrom),
				binary:encode_unsigned(ITo),
				Value,
				CallData,
				Gas,
				Extra,
				if Static==true ->
					   #{ static => true };
				   true ->
					   #{}
				end).

evm_logger(Message,LArgs0,#{log:=PreLog}=Xtra,#{data:=#{address:=A,caller:=O}}) ->
  LArgs=[binary:encode_unsigned(I) || I <- LArgs0],
  ?LOG_INFO("EVM log ~p ~p",[Message,LArgs]),
  %io:format("==>> EVM log ~p ~p~n",[Message,LArgs]),
  Xtra#{log=>[([evm,binary:encode_unsigned(A),binary:encode_unsigned(O),Message,LArgs])|PreLog]}.

