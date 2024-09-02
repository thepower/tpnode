-module(process_txs).
-export([
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

process_tx(#{from:=From, to:=To}=Tx, GasLimit, State, Opts) ->
	Value=tx_value(Tx,<<"SK">>),
	CD=tx_cd(Tx),
	{Valid, Return, GasLeft, State2} = process_itx(From, To, Value, CD, GasLimit, State#{cur_tx=>Tx}, Opts),

	{Valid, Return, GasLeft, 
	 maps:without([cur_tx,tstorage], State2)
	};

process_tx(#{from:=From, seq:=Nonce, kind:=deploy,
			 txext:=#{
					  "code":=Code,
					  "vm":="evm"
					 }
			}=Tx, GasLimit, State, Opts) when is_binary(Code) ->
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
			}=Tx,
		   GasLimit,
		   State,
		   Opts) ->
	case pstate_lstore:patch(Owner, Patch, State) of
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
	State1=transfer(From, To, Value, State0),
	{ 1, <<>>, GasLimit, State1};

process_code_itx(Code,From, To, Value, CallData, GasLimit, #{acc:=_}=State0, _Opts) ->
	State1=transfer(From, To, Value, State0),
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

transfer(_, _, 0, State) ->
	State;
transfer(From, To, Value, State0) when Value > 0 ->
	%get_state(From, balance, <<"SK">>, Acc, GetFun, GFA)
	{Src0, _, State1} = pstate:get_state(From, balance, <<"SK">>, State0),
	{Dst0, _, State2} = pstate:get_state(To, balance, <<"SK">>, State1),
	Src1=Src0-Value,
	if(Src1<0) -> throw(insuffucient_fund); true -> ok end,
	Dst1=Dst0+Value,
	State3=pstate:set_state(From, balance, <<"SK">>, Src1, State2),
	pstate:set_state(To, balance, <<"SK">>, Dst1, State3).


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

