-module(process_txs_sponsor).
-export([process_sponsors/3]).
-include("include/tplog.hrl").

process_sponsors([],#{payload:=P},State0) ->
	{P, maps:remove(cur_tx,State0)};

process_sponsors([Sponsor|Rest],Tx,State0) when is_binary(Sponsor),
												size(Sponsor)==8 orelse size(Sponsor)==20 ->
	case process_evm:check_EIP165(Sponsor,<<16#A44EFBE7:32/big>>,State0) of
		{false, State1} ->
			?LOG_INFO("~s not a sponsor",[hex:encodex(Sponsor)]),
			process_sponsors(Rest,Tx,State1);
		{true, State1} ->
			case sponsor_pays(Sponsor, Tx, State1#{cur_tx=>Tx}) of
				{false, _, State2} ->
					?LOG_INFO("Sponsor ~s not pays",[hex:encodex(Sponsor)]),
					process_sponsors(Rest,Tx,State2);
				{true, Payloads, State2} ->
					process_sponsors(Rest,
									 Tx#{
									   payload => Payloads
									  },State2)
			end
	end;

process_sponsors([_|Rest],Tx,State0) ->
	process_sponsors(Rest,Tx,State0).


sponsor_pays(Address, Tx, State0) ->
	Function= "sponsor_tx("
	"(uint256,address,address,uint256,uint256,bytes,"
	"(uint256,string,uint256)[],"
	"(bytes,uint256,bytes,bytes,bytes)[])"
	")",
	try
		OutABI=[{<<"pays">>,uint256},{<<"pay">>,{darray,{tuple,[{<<"purpose">>,uint256},{<<"cur">>,string},{<<"amount">>,uint256}]}}}],
		{ok,PTx}=contract_evm:preencode_tx(Tx,[]),
		CallData = contract_evm_abi:encode_abi_call([PTx], Function),

		case process_evm:static_call(Address, CallData, 30000, State0) of
			{0, _Ret, _GasLeft, State1} ->
				{false, [], State1};
			{1, Ret, _GasLeft, State1} ->
				case contract_evm_abi:decode_abi(Ret,OutABI) of
					[{<<"pays">>,1},{<<"pay">>,WillPay}] ->
						R=lists:foldr(
							fun([{<<"purpose">>,P},{<<"cur">>,Cur},{<<"amount">>,Amount}],A) ->
									[#{sponsor=>Address,
									   purpose=>tx:decode_purpose(P),
									   cur=>Cur,
									   amount=>Amount}|A]
							end, maps:get(payload,Tx), WillPay),
						{true, R, State1};
					[{<<"pays">>,0},_] ->
						?LOG_INFO("Sponsor is not willing to pay for tx"),
						{false, [], State1};
					Any ->
						?LOG_ERROR("~s static call error: unexpected result ~p",[Function,Any]),
						{false, [], State1}
				end
		end
	catch Ec:Ee:S ->
			  ?LOG_ERROR("~s static call error: ~p:~p @ ~p",[Function,Ec,Ee,S]),
			  {false, [], State0}
	end.

