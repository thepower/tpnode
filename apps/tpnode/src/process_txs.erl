-module(process_txs).
-export([
		 process_tx/3, %process with gas and fee calculation
		 process_tx/4,
		 process_itx/7,
		 process_code_itx/8,
		 new_state/2,
		 upgrade_settings/3
		]).
-include("include/tplog.hrl").

upgrade_settings(Settings, GetFun, GetFunArg) ->
	State0 = new_state(GetFun, GetFunArg),
	LStoreMap=settings:clean_meta(maps:with(
									[<<"fee">>,<<"freegas2">>,<<"gas">>],
									Settings
								   )),

	Addr0=lists:foldl(
		 fun(#{<<"p">> := P, <<"t">> := <<"set">>, <<"v">> := V}, A) ->
				 maps:put({lstore,P}, {V,undefined}, A)
		 end,
		 #{ lstore_map => LStoreMap },
		 settings:get_patches(LStoreMap)
		),

	State0#{acc=>#{<<0>> => Addr0 }}.

new_state(GetFun, GetFunArg) ->
	S0=pstate:new_state(GetFun, GetFunArg),
	S0#{
	  transaction_result => [],
	  transaction_receipt => [],
	  tstorage => #{},
	  cumulative_gas => 0,
	  log => []
	 }.

process_tx(#{txext:=#{"sponsor":=Sponsors}=E,payload:=OldP}=Tx, State0, Opts) ->
	{NewPayloads,State1} = process_txs_sponsor:process_sponsors(Sponsors,Tx,State0),
	?LOG_INFO("Process sponsors ~p pay ~p",[Sponsors,NewPayloads--OldP]),
	process_tx(Tx#{
				 payload=>NewPayloads,
				 txext=>maps:remove("sponsor",E)
				},State1, Opts);

process_tx(#{kind:=register,
			 sigverify:=#{
						  invalid:=0,
						  valid:=1,
						  pubkeys:=[PubKey|_]
						 }
			}, State0, Opts) ->
	try
		ChainSettingsAddress=maps:get(chainsettings_address,Opts,<<0>>),
		{Alloc, _, State1} = pstate:get_state(
							 ChainSettingsAddress,
							 lstore,
							 [<<"allocblock">>],
							 State0),
		case Alloc of
			#{<<"block">> := Blk,
			  <<"group">> := Grp,
			  <<"last">> := Last} when Last < 16#FFFFF0 ->
				NewBAddr=naddress:construct_public(Grp, Blk, Last+1),
				Patch={[<<"allocblock">>,<<"last">>],set,Last+1},
				case pstate_lstore:patch(ChainSettingsAddress, [Patch], State1) of
					{ok, State2} ->
						State3=pstate:set_state(NewBAddr, pubkey, [], PubKey, State2),
						{1, NewBAddr, State3};
					{error, FReason} ->
						{0, atom_to_binary(FReason), State1}
				end;
			_ ->
				{0, <<"unallocable">>, State1}
		end
	catch throw:Reason when is_atom(Reason) ->
			  {0, atom_to_binary(Reason, utf8), State0};
		  throw:Reason when is_binary(Reason) ->
			  {0, Reason, State0}
	end;

process_tx(#{from:=From,seq:=Seq}=Tx, #{cumulative_gas := GasC0} = State0, Opts) ->
	?LOG_INFO("Process generic from ~s",[hex:encodex(From)]),
	try
	SettingsToLoad=#{
			   freegas => [<<"freegas2">>,maps:get(to,Tx,undefined)],
			   fee => [ <<"fee">> ],
			   gas => [ <<"gas">> ]
			  },
	ChainSettingsAddress=maps:get(chainsettings_address,Opts,<<0>>),
	EscrowAddress=maps:get(chainsettings_address,Opts,<<"escrow">>),

	{State1, LoadedSettings}=maps:fold(
					fun(Opt, Path, {CState,Acc}) ->
							{Val, _, CState1} = pstate:get_state(
												  ChainSettingsAddress,
												  lstore,
												  Path,
												  CState),
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
	?LOG_DEBUG("GasPayloads ~p~n", [GasPayloads]),

	GasSettings=maps:get(gas, LoadedSettings),
	{State3,Taken,GasLimit}=lists:foldl(
						 fun(#{amount:=0, cur:= <<"NORUN">>}, _) ->
								 {State2, [], norun};
							(_,{_,_,norun}=A) ->
								A;
							(Payload, {_CState, _T, _GasAcc}=A) ->
								 to_gas(EscrowAddress, maps:merge(
										  #{sponsor=>From},
										  Payload), GasSettings, A)
						 end,
						 {State2, [], FreeGas},
						 GasPayloads
						),

	?LOG_DEBUG("Gas collected ~p taken ~p~n", [GasLimit, Taken]),


	State4=pstate:set_state(From, seq, [], Seq, State3),

	if GasLimit == norun ->
		   To=maps:get(to, Tx),
		   State5=lists:foldl(
					fun(#{amount:=Amount,cur:=Cur,purpose:=_},StateC) ->
							transfer(From, To, Amount, Cur, StateC)
					end,
					State4,
					tx:get_payloads(Tx, transfer)
				   ),
		   {1, <<>>, State5#{last_tx_gas => 0}};
	   true ->

		   try
			   {Valid, Data, GasLeft, State5} = process_tx(Tx, GasLimit, State4, Opts),

			   {GasLeft2, Collected, State6}  = return_gas(EscrowAddress, GasLeft, Taken, State5, []),
			   ?LOG_DEBUG("Gas left ~p left2 ~p / ~p~n", [GasLeft, GasLeft2, Collected]),
			   State7 = lists:foldl(
						  fun(Token, State) ->
								  {Src0, _, _} = pstate:get_state(EscrowAddress, balance, Token, State),
								  transfer(EscrowAddress, FeeReceiver, Src0, Token, State)
						  end, State6, Collected),

			   GasUsed = GasLimit - GasLeft,
			   {Valid, Data, State7#{cumulative_gas => GasC0 + GasUsed,
									 last_tx_gas => GasUsed }}
		   catch throw:Reason1 when is_atom(Reason1) ->
					 % in case of something went completely wrong, take only fee, and full return gas
					 {0, atom_to_binary(Reason1, utf8), State2#{last_tx_gas => 0 }};
				 throw:Reason1 when is_binary(Reason1) ->
					 % in case of something went completely wrong, take only fee, and full return gas
					 {0, Reason1, State2#{last_tx_gas => 0 }}
		   end
	end


	catch throw:Reason when is_atom(Reason) ->
			  {0, atom_to_binary(Reason, utf8), State0#{last_tx_gas => 0 }};
		  throw:Reason when is_binary(Reason) ->
			  {0, Reason, State0#{last_tx_gas => 0 }}
	end.

return_gas(_EscrowAddress, GasLeft, [], State, Acc) ->
	{GasLeft, Acc, State};
return_gas(EscrowAddress, GasLeft, [#{g:=TotalG, amount:=A, cur:=C, sponsor:=Sponsor}|Rest], State, Acc) when GasLeft > TotalG ->
	return_gas(EscrowAddress, GasLeft-TotalG,
			   Rest,
			   transfer(EscrowAddress, Sponsor, A, C, State),
			   Acc
			  );
return_gas(EscrowAddress, GasLeft, [#{k:={N,D}, amount:=A, cur:=C, sponsor:=Sponsor}|Rest], State, Acc) ->
	ReturnTokens=min(trunc(GasLeft*D/N),A),
	ReturnGas=ReturnTokens*N div D,

	?LOG_DEBUG("gas left ~p return ~p / ~p ~p to ~p~n",
			  [GasLeft, ReturnGas, ReturnTokens, C, Sponsor]),

	return_gas(EscrowAddress, GasLeft-ReturnGas,
			   Rest,
			   transfer(EscrowAddress, Sponsor, ReturnTokens, C, State),
			   [C|Acc]
			  ).

to_gas(EscrowAddress, #{sponsor:=Sponsor, amount:=A, cur:=C}=Payload, GasSettings, {CState, T, GasAcc}) ->
	case to_gas1(Payload,GasSettings) of
		{ok, P1, G} when G>0 ->
			{
			transfer(Sponsor, EscrowAddress, A, C, CState),
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
	?LOG_INFO("Process internal gas ~p ",[GasLimit]),

	Value=tx_value(Tx,<<"SK">>),
	State1=lists:foldl(
			 fun(#{amount:=Amount,cur:=Cur,purpose:=_},StateC) ->
					 transfer(From, To, Amount, Cur, StateC)
			 end,
			 State0#{cur_tx=>Tx},
			 tx:get_payloads(Tx, transfer) -- [tx:get_payload(Tx, transfer)]
			),
	%transfer all except first SK transfer, which will be transfered in process_itx

	CD=contract_evm:tx_cd(Tx),
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
					 } = TxExt
			}=Tx,
		   GasLimit, State, Opts) when is_binary(Code) ->
	?LOG_INFO("Process deploy internal gas ~p ",[GasLimit]),
	Value=tx_value(Tx,<<"SK">>),
	Address = case TxExt of
				  #{ "deploy":= "inplace"} ->
					  From;
				  _ ->
					  D2Hash=erlp:encode([From,binary:encode_unsigned(Nonce)]),
					  {ok,<<_:12/binary,EVMAddress:20/binary>>}=ksha3:hash(256, D2Hash),
					  EVMAddress
			  end,
	?LOG_INFO("Deploy to address ~p gas ~p transfer ~p~n",
			  [Address, GasLimit,
			   tx:get_payloads(Tx, transfer)
			  ]),
	State0=State#{cur_tx=>Tx},
	State1=lists:foldl(
			 fun(#{amount:=Amount,cur:=Cur,purpose:=_},StateC) ->
					 transfer(From, Address, Amount, Cur, StateC)
			 end,
			 State0,
			 tx:get_payloads(Tx, transfer)
			),
	case process_code_itx(Code, From, Address,
						  Value, <<>>, GasLimit-3200, State1, Opts) of
		{1, DeployedCode, GasLeft, State2} ->
			State3=pstate:set_state(Address, code, [], DeployedCode, State2),
			?LOG_INFO("Deploy to address ~p success",[Address]),
			State4=maps:without([cur_tx,tstorage], State3),
			State5=case TxExt of
					   #{ "setkey":= Key } when is_binary(Key) ->
						   pstate:set_state(Address, pubkey, [], Key, State4);
					   _ ->
						   State4
				   end,
			{1, Address, GasLeft, State5};
		{0, <<>>, 0, _} ->
			{0, <<"nogas">>, 0,
			 maps:without([cur_tx,tstorage], State)
			};
		{0, Reason, GasLeft, _} ->
			{0, Reason, GasLeft,
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
	?LOG_INFO("Process lstore internal gas ~p ",[GasLimit]),
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
	?LOG_INFO("Invalid tx ~p",[_Tx]),
	throw('invalid_tx').

-define (ASSERT_NOVAL,
		 if Value>0 ->
				throw({revert,<<"embedded called with value">>});
			Value == 0 ->
				ok
		 end).

process_itx(_From, <<16#AFFFFFFFFF000000:64/big>>=_To, Value, _CallData, GasLimit, State0, _Opts) ->
	?ASSERT_NOVAL,
	MT=maps:get(mean_time,State0,0),
	Ent=case maps:get(entropy,State0,<<>>) of
			Ent1 when is_binary(Ent1) ->
				Ent1;
			_ ->
				<<>>
		end,
	{1,<<MT:256/big,Ent/binary>>, GasLimit-10, State0};

process_itx(_From, <<16#AFFFFFFFFF000001:64/big>>=_To, Value, CallData, GasLimit, State0, _Opts) ->
	?ASSERT_NOVAL,
	{1,list_to_binary( lists:reverse( binary_to_list(CallData))), GasLimit-10, State0};

%getTx() returns ((uint256,address,address,uint256,uint256,bytes,(uint256,string,uint256)[],(bytes,uint256,bytes,bytes,bytes)[]))
process_itx(_From, <<16#AFFFFFFFFF000002:64/big>>=_To, Value, <<2285013609:32/big>>, GasLimit,
			#{cur_tx:=Tx}=State0, _Opts) ->
	?ASSERT_NOVAL,
	RBin= contract_evm:encode_tx(Tx,[]),
	{1, RBin, GasLimit-100, State0};

%getExtra(string keyname) returns (uint256, bytes)
process_itx(_From, <<16#AFFFFFFFFF000002:64/big>>=_To, Value,
			<<1404481427:32/big,CallData/binary>>, GasLimit,
			#{cur_tx:=Tx}=State0, _Opts) ->
	?ASSERT_NOVAL,
	[{<<>>,String}] = contract_evm_abi:decode_abi(CallData,[{<<>>,string}]),
	TxExt = maps:get(txext, Tx, #{}),
	Ret = case maps:get(binary_to_list(String),TxExt,<<>>) of
			  <<>> ->
				  [0, <<>>];
			  [I|_]=L when is_integer(I) ->
				  [1,list_to_binary(L)];
			  B when is_binary(B) ->
				  [2,B];
			  [B|_]=L when is_binary(B) -> %list of binary
				  [3,erlp:encode(L)]
		  end,
	RBin=contract_evm_abi:encode_abi(Ret, [{<<>>,uint256},{<<>>,bytes}]),
	{1, RBin, GasLimit-100, State0};

process_itx(_From, <<16#AFFFFFFFFF000002:64/big>>=_To, Value, _CallData, GasLimit,
			#{cur_tx:=Tx}=State0, _Opts) ->
	?ASSERT_NOVAL,
	hex:hexdump(_CallData),
	RBin= contract_evm:encode_tx(Tx,[]),
	{1, RBin, GasLimit-100, State0};

process_itx(From, <<16#AFFFFFFFFF000003:64/big>>, Value, CallData, GasLimit, State0, Opts) ->
	?ASSERT_NOVAL,
	process_embedded:settings_service(From, CallData, GasLimit, State0, Opts);

process_itx(From, <<16#AFFFFFFFFF000004:64/big>>, Value, CallData, GasLimit, State0, Opts) ->
	?ASSERT_NOVAL,
	process_embedded:block_service(From, CallData, GasLimit, State0, Opts);

process_itx(From, <<16#AFFFFFFFFF000005:64/big>>, Value, CallData, GasLimit, State0, Opts) ->
	?ASSERT_NOVAL,
	process_embedded:lstore_service(From, CallData, GasLimit, State0, Opts);

process_itx(From, <<16#AFFFFFFFFF000006:64/big>>, Value, CallData, GasLimit, State0, Opts) ->
	?ASSERT_NOVAL,
	process_embedded:chkey_service(From, CallData, GasLimit, State0, Opts);

process_itx(From, <<16#AFFFFFFFFF000007:64/big>>, Value, CallData, GasLimit, State0, Opts) ->
	?ASSERT_NOVAL,
	process_embedded:bronkerbosch_service(From, CallData, GasLimit, State0, Opts);

process_itx(From, From, 0, CallData, GasLimit,
			#{acc:=_,
			  cur_tx:=#{ txext:=#{ "code":=Code, "vm":="evm" } }
			 }=State0, Opts) ->
	process_code_itx(Code, From, From, 0, CallData, GasLimit, State0, Opts);

process_itx(From, From, 0, CallData, GasLimit,
			#{acc:=_,
			  cur_tx:=#{ txext:=#{ "callcode" := CodeAddr } }
			 }=State0, Opts) ->
	{ok, Code, State1, _} = process_evm:evm_code(binary:decode_unsigned(CodeAddr), State0, #{}),
	process_code_itx(Code, From, From, 0, CallData, GasLimit, State1, Opts);

process_itx(From, To, Value, CallData, GasLimit, #{acc:=_}=State0, Opts) ->
	{ok, Code, State1, _} = process_evm:evm_code(binary:decode_unsigned(To), State0, #{}),
	process_code_itx(Code, From, To, Value, CallData, GasLimit, State1, Opts).

process_code_itx(<<>>,From, To, Value, _CallData, GasLimit, #{acc:=_}=State0, _Opts) ->
	if GasLimit == 0 -> ok;
	   true -> ?LOG_INFO("== process call without code ~p~n",[To])
	end,
	State1=transfer(From, To, Value, <<"SK">>, State0),
	{ 1, <<>>, GasLimit, State1};

process_code_itx(_Code,_From, _To, Value, _CallData, GasLimit, State0=#{static:=_}, _) when
	  Value>0 ->
	{ 0, <<"static_call_with_value">>, GasLimit, State0};

process_code_itx(Code,From, To, Value, CallData, GasLimit, #{acc:=_}=State0, _Opts) ->
	?LOG_INFO("Call proc code size ~p",[size(Code)]),

	State1=transfer(From, To, Value, <<"SK">>, State0),
	Result = eevm:eval(Code, #{},
					   maps:merge(
						 maps:with([static],State0),
						 #{
						   gas=>GasLimit,
						   sload=>fun process_evm:evm_sload/4,
						   sstore=>fun process_evm:evm_sstore/5,
						   custom_call => fun process_evm:evm_custom_call/8,
						   extra=>State1,
						   bad_instruction=>fun process_evm:evm_instructions/2,
						   return=><<>>,
						   get=>#{
								  code => fun process_evm:evm_code/3,
								  balance => fun process_evm:evm_balance/3
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
						   logger=>fun process_evm:evm_logger/4,
						   trace=>whereis(eevm_tracer)
						  })),

	?LOG_INFO("Call ~s (~s) ret {~p,~p,...}",
			  [hex:encodex(To), hex:encode(CallData),
			   element(1,Result),
			   case element(2,Result) of
				   {return, Bin} when size(Bin)<128 ->
					   {return, hex:encodex(Bin)};
				   {return, <<Hdr:100/binary,_/binary>>}  ->
					   {return, hex:encodex(Hdr), more};
				   Other -> Other
			   end
			  ]),
	case Result of
		{done, {return,RetVal}, #{gas:=GasLeft, extra:=State3}} ->
			{ 1, RetVal, gas_left(GasLeft,GasLimit), State3};
		{done, 'stop', #{gas:=GasLeft, extra:=State3}} ->
			{ 1, <<>>, gas_left(GasLeft,GasLimit), State3};
		{done, 'eof', #{gas:=GasLeft, extra:=State3}} ->
			{ 1, <<>>, gas_left(GasLeft,GasLimit), State3};
		{done, 'invalid', #{gas:=GasLeft, extra:=_FailState}} ->
			{ 0, <<>>, gas_left(GasLeft,GasLimit),
			  append_log(
				[<<"evm:invalid">>,To,From,<<>>],
				State1)
			};
		{done, {revert, Revert}, #{ gas:=GasLeft}} ->
			{ 0, Revert, gas_left(GasLeft,GasLimit),
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
			{ 0, <<>>, gas_left(GasLeft,GasLimit),
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

gas_left(GasLeft, GasLimit) when GasLeft < GasLimit ->
	GasLeft;
gas_left(_GasLeft, GasLimit) ->
	Stack = try throw(ok) catch throw:ok:S -> S end,
	?LOG_ERROR("Gas mismatch ~w sent but ~w returned! @ ~p",[GasLimit, _GasLeft, Stack]),
	GasLimit.


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

transfer(_, _, 0, _Cur, State) ->
	State;
transfer(From, To, _, _Cur, State) when From==To ->
	State;
transfer(From, To, Value, Cur, State0) when Value > 0 ->
	%get_state(From, balance, <<"SK">>, Acc, GetFun, GFA)
	{Src0, _, State1} = pstate:get_state(From, balance, Cur, State0),
	Src1=Src0-Value,
	if(Src1<0) -> throw(insuffucient_fund); true -> ok end,
	State2=pstate:set_state(From, balance, Cur, Src1, State1),
	{Dst0, _, State3} = pstate:get_state(To, balance, Cur, State2),
	Dst1=Dst0+Value,
	?LOG_INFO("trasfer ~s -> ~s ~w ~s",[hex:encodex(From),hex:encodex(To),Value,Cur]),
	pstate:set_state(To, balance, Cur, Dst1, State3).



