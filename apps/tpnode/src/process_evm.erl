-module(process_evm).
-include("include/tplog.hrl").

-export([evm_balance/3,
		 evm_code/3,
		 evm_sload/4,
		 evm_sstore/5,
		 evm_custom_call/8,
		 evm_logger/4,
		 evm_instructions/2,
		 static/2, static/3,
		 static_call/4,
		 check_EIP165/3]).

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
			   if IValue==0 ->
					  <<>>;
				  true ->
					  binary:encode_unsigned(IValue)
			   end,
			   State2
			  ),
	{'ok', State3, OldValue=/=<<>>}.

evm_custom_call(staticcall, IFrom, ITo, Value, CallData, Gas, Extra, _InternalState) ->
	static(
	  fun(S) ->
			  process_txs:process_itx(binary:encode_unsigned(IFrom),
									  binary:encode_unsigned(ITo),
									  Value,
									  CallData,
									  Gas,
									  S,
									  #{})
	  end, Extra);

evm_custom_call(callcode, IFrom, ITo, Value, CallData, Gas, Extra, _InternalState) ->
	{ok, Code, Extra1, _} = process_evm:evm_code(ITo, Extra, #{}),
	process_txs:process_code_itx(
	  Code,
	  binary:encode_unsigned(IFrom),
	  binary:encode_unsigned(IFrom),
	  Value,
	  CallData,
	  Gas,
	  Extra1,
	  #{});

evm_custom_call(delegatecall, _IFrom, ITo, Value, CallData, Gas, Extra,
				#{data:=#{address:=OrigTo, caller:=OrigFrom}} =_InternalState) ->
	{ok, Code, Extra1, _} = process_evm:evm_code(ITo, Extra, #{}),
	process_txs:process_code_itx(
	  Code,
	  binary:encode_unsigned(OrigFrom),
	  binary:encode_unsigned(OrigTo),
	  Value,
	  CallData,
	  Gas,
	  Extra1,
	  #{});

evm_custom_call(call, IFrom, ITo, Value, CallData, Gas, Extra, _InternalState) ->
	process_txs:process_itx(
	  binary:encode_unsigned(IFrom),
	  binary:encode_unsigned(ITo),
	  Value,
	  CallData,
	  Gas,
	  Extra,
	  #{}).

evm_logger(Message,LArgs0,#{log:=PreLog}=Xtra,#{data:=#{address:=A,caller:=O}}) ->
  LArgs=[binary:encode_unsigned(I) || I <- LArgs0],
  ?LOG_INFO("EVM log ~p ~p",[Message,LArgs]),
  %io:format("==>> EVM log ~p ~p~n",[Message,LArgs]),
  Xtra#{log=>[([<<"evm">>,binary:encode_unsigned(A),binary:encode_unsigned(O),Message,LArgs])|PreLog]}.

evm_instructions(chainid, #{stack:=Stack}=BIState) ->
	BIState#{stack=>[16#c0de00000000|Stack]};
evm_instructions(number,#{stack:=BIStack}=BIState) ->
	BIState#{stack=>[100+1|BIStack]};
evm_instructions(timestamp,#{stack:=BIStack}=BIState) ->
	MT=1,
	BIState#{stack=>[MT|BIStack]};

evm_instructions(selfbalance,#{stack:=BIStack,data:=#{address:=MyAddr},extra:=#{acc:=_}=State0}=BIState) ->
	{Value, _Cached, State1} = pstate:get_state(binary:encode_unsigned(MyAddr),
										balance,
										<<"SK">>,
										State0),
	io:format("selfbalance add ~p ~p~n",[MyAddr,Value]),
	BIState#{stack=>[Value|BIStack],extra=>State1};

evm_instructions(create, #{stack:=[Value,MemOff,Len|Stack],
						   memory:=RAM,
						   gas:=G,
						   extra:=#{acc:=_}=Xtra}=BIState) ->
  case Xtra of
	  #{cur_tx:=#{from:=SrcAddr, seq:=Nonce}} ->
		  Code=eevm_ram:read(RAM,MemOff,Len),
		  D2Hash=erlp:encode([SrcAddr,binary:encode_unsigned(Nonce)]),
		  {ok,<<_:12/binary,Address:20/binary>>}=ksha3:hash(256, D2Hash),
		  ?LOG_DEBUG("Deploy to address ~p~n",[Address]),
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
	?LOG_DEBUG("Deploy to address ~p~n",[Address]),
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
	case process_txs:process_code_itx(Code, binary:encode_unsigned(From), Address,
						  Value, <<>>, G-3200, Xtra, []) of
		{1, DeployedCode, GasLeft, Xtra1} ->
			Xtra2=pstate:set_state(Address, code, [], DeployedCode, Xtra1),
			BIState#{stack=>[binary:decode_unsigned(Address)|Stack], gas=>GasLeft, extra=>Xtra2};
		{0, _, GasLeft, _} ->
			BIState#{stack=>[0|Stack], gas=>GasLeft, extra=>Xtra}
	end.

%already static, do not clear static flag on finish
static(Fun, Arg, State=#{static:=_}) when is_function(Fun,2) ->
	Fun(Arg, State);

static(Fun, Arg, State) when is_function(Fun,2) ->
	case Fun(Arg, State#{static=>1}) of
		{Ret, State1} ->
			{Ret, maps:remove(static, State1)};
		{Res, Ret, Gas, State1} ->
			{Res, Ret, Gas, maps:remove(static, State1)}
	end.


static(Fun, State=#{static:=_}) when is_function(Fun,1) ->
	Fun(State);

static(Fun, State) when is_function(Fun,1) ->
	case Fun(State#{static=>1}) of
		{Ret, State1} ->
			{Ret, maps:remove(static, State1)};
		{Res, Ret, Gas, State1} ->
			{Res, Ret, Gas, maps:remove(static, State1)}
	end.

static_call(Address, CallData, Gas, State) ->
	static(
	  fun(S) ->
			  process_txs:process_itx(
				<<0>>, Address, 0, CallData, Gas, S, #{}
			   ) 
	  end, State).

check_EIP165(Address, InterfaceId, State0) ->
	Calls =  [{contract_evm_abi:encode_abi_call(
				 [InterfaceId],
				 "supportsInterface(bytes4)"),
			   <<1:256/big>>},
			  {contract_evm_abi:encode_abi_call(
				 [<<255,255,255,255>>],
				 "supportsInterface(bytes4)"),
			   <<0:256/big>>}],
	static(
	  fun(S) ->
			  proc_eip165_(Calls, Address, S)
	  end, State0).

proc_eip165_([], _, State) ->
	{true, State};

proc_eip165_([{Call,Expected}|Rest], Address, State) ->
	case process_txs:process_itx(
		   <<0>>, Address, 0, Call, 30000, State, #{}
		  ) of
		{1, Expected, _, State1} ->
			proc_eip165_(Rest, Address, State1);
		{0, _, _, State1} ->
			{false, State1};
		_ ->
			{false, State}
	end.


