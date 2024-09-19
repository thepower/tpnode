-module(process_txs3_test).
-include_lib("eunit/include/eunit.hrl").

read_contract(Filename) ->
	{ok,HexBin} = file:read_file(Filename),
	hex:decode(HexBin).

default_settings() ->
	{<<0>>,
	 #{ lstore => #{
					<<"fee">> => #{
								   <<"params">>=> #{ <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>> },
								   <<"FTT">> => #{ <<"base">> => 1, <<"baseextra">> => 64, <<"kb">> => 10 }
								  },
					<<"gas">> => #{
								   <<"FTT">> => #{ <<"gas">> => 35000, <<"tokens">> => 10 },
								   <<"SK">> => #{ <<"gas">> => 50000, <<"tokens">> => 1 }
								  },
					<<"allocblock">> => #{
										  <<"block">> => 10,
										  <<"group">> => 2,
										  <<"last">> => 3
										 }
				   }
	  }
	}.

process_register_test() ->
	Ledger=[default_settings()],
	Pvt=crypto:hash(sha256,<<"test">>),
	Pub=tpecdsa:calc_pub(Pvt),

	{ok,Tx}= tx:verify(
			   tx:sign(
				 tx:construct_tx(
				   #{kind=>register,
					 ver=>2,
					 t=>1,
					 keys=>[Pub]
					}),Pvt)),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 {Ret,RetData,State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 Patch=pstate:patch(State1),
			 {Ret,RetData,Patch}
	 end,

	DB=test3_ptx,
	{Res, <<0:192/big,Address:8/binary>>, Patch} = mledger:deploy4test(DB, Ledger, Test),
	[?assertEqual(1, Res),
	 ?assertMatch({_,lstore,[<<"allocblock">>,<<"last">>],_,_}, lists:keyfind(lstore,2,Patch)),
	 ?assertMatch({Address,pubkey,[],_,Pub}, lists:keyfind(pubkey,2,Patch))
	].


process_embedded_lstore_write_test() ->
	UserAddr= <<128,1,64,0,2,0,0,1>>,
	Ledger=[default_settings(),
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									},
						lstore => #{ <<"a">> => #{ <<"b">> => 1 }}
						}
			}
		   ],

	Tx= tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=><<16#AFFFFFFFFF000005:64/big>>,
			seq=>1,
			call=>#{function=>"setByPath(bytes[],uint256,bytes)",
					args=>
					[ [ <<"path">>,<<"one">>, <<"two">> ], 1, <<"preved">> ] },
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee}
					 ]
		   }),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 {Ret,RetData,State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 Patch=pstate:patch(State1),
			 {Ret,RetData,Patch}
	 end,

	DB=test3_ptx,
	{Res, Data, State1} = mledger:deploy4test(DB, Ledger, Test),
	[?assertEqual(1, Res),
	 ?assertMatch( <<1:256/big>>, Data),
	 ?assertMatch({_,lstore,[<<"path">>,<<"one">>,<<"two">>],undefined,<<"preved">>},
				  lists:keyfind(lstore,2,State1))
	].


process_embedded_lstore_read_test() ->
	UserAddr= <<128,1,64,0,2,0,0,1>>,
	Ledger=[default_settings(),
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									}}}
		   ],

	Tx= tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=><<16#AFFFFFFFFF000005:64/big>>,
			seq=>1,
			call=>#{function=>"getByPath(address,bytes[])",
					args=>
					[<<0>>,
					 [ <<"fee">>,<<"params">>, <<"feeaddr">> ]
					]
				   },
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee}
					 ]
		   }),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 %io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
			 {Ret,RetData,_State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 %io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
			 {Ret,RetData}
	 end,

	DB=test3_ptx,
	{Res, Data} = mledger:deploy4test(DB, Ledger, Test),
	OutABI=[{<<"datatype">>,uint256},
			{<<"res_bin">>,bytes},
			{<<"res_int">>,uint256},
			{<<"keys">>,{darray,{tuple,[{<<"datatype">>,uint256},
										{<<"res_bin">>,bytes}]}}}],
	[?assertEqual(1, Res),
	 ?assertMatch(
		[{_, [{<<"datatype">>,2},
			  {<<"res_bin">>,<<160,0,0,0,0,0,0,1>>},
			  {<<"res_int">>,8},
			  {<<"keys">>,[]}]}],
		contract_evm_abi:decode_abi(Data, [{<<>>, {tuple, OutABI}}])
	   )
	].

process_embedded_chkey_test() ->
	UserAddr= <<128,1,64,0,2,0,0,1>>,
	Ledger=[default_settings(),
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									}}}
		   ],

	Tx= tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=><<16#AFFFFFFFFF000006:64/big>>,
			seq=>1,
			call=>#{function=>"setKey(bytes)",args=>
					[<<"invalid_key">>]
				   },
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee}
					 ]
		   }),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 %io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
			 {Ret,RetData,State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 %io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
			 Patch=pstate:patch(State1),
			 {Ret,RetData,Patch}
	 end,

	DB=test3_ptx,
	{Res, Data, State1} = mledger:deploy4test(DB, Ledger, Test),
	[?assertEqual(1, Res),
	 ?assertEqual(<<1:256/big>>,Data),
	 ?assertMatch({_,pubkey,[],_Old,<<"invalid_key">>}, lists:keyfind(pubkey,2,State1))
	].

process_embedded_gettx_test() ->
	UserAddr= <<128,1,64,0,2,0,0,1>>,
	Ledger=[
			default_settings(),
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									}}}
		   ],

	Tx= tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=><<16#AFFFFFFFFF000002:64/big>>,
			seq=>1,
			call=>#{function=>"fun1(uint256,uint256,uint256)",args=>[1,2,3]},
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee}
					 ]
		   }),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 %io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
			 {Ret,RetData,_State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 %io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
			 {Ret,RetData}
	 end,

	DB=test3_ptx,
	{Res, Data} = mledger:deploy4test(DB, Ledger, Test),
	%EncCD=contract_evm:cd("fun1(uint256,uint256,uint256)",[1,2,3]),
	EncCD= <<16#40F9971E:32/big,
			 1:256/big,
			 2:256/big,
			 3:256/big>>,
	[?assertEqual(Res, 1),
	 ?assertMatch([{<<"tx">>,[
							  {<<"kind">>,16},
							  {<<"from">>,UserAddr},
							  {<<"to">>,<<16#AFFFFFFFFF000002:64/big>>},
							  {<<"t">>,1},
							  {<<"seq">>,1},
							  {<<"call">>,EncCD},
							  {<<"payload">>, [_,_]},
							  {<<"signatures">>,[]}
							 ]}],contract_evm_abi:decode_abi(Data,  contract_evm:tx_abi()))
	 ].

process_embedded_test() ->
	UserAddr= <<128,1,64,0,2,0,0,1>>,
	Ledger=[
			{<<0>>,
			 #{ lstore => #{ <<"fee">> => #{ <<"params">>=> #{ <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>> }, <<"FTT">> => #{ <<"base">> => 1, <<"baseextra">> => 64, <<"kb">> => 10 } }, <<"gas">> => #{ <<"FTT">> => #{ <<"gas">> => 35000, <<"tokens">> => 10 }, <<"SK">> => #{ <<"gas">> => 50000, <<"tokens">> => 1 } } } }
			},
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									}}}
		   ],

	Tx= tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=><<16#AFFFFFFFFF000001:64/big>>,
			seq=>1,
			call=>#{function=>"0x0",args=>[<<"preved">>]},
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee}
					 ]
		   }),


	Test=fun(DB) ->
			 State0=process_txs:new_state(fun mledger:getfun/2, DB),
			 %io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
			 {Ret,RetData,_State1}=process_txs:process_tx(Tx,
														 State0,
														 #{}),
			 %io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
			 {Ret,RetData}
	 end,

	DB=test3_ptx,
	[?assertEqual({1,<<"deverp">>},mledger:deploy4test(DB, Ledger, Test))].

process_sponsor_callcode_test() ->
	Admin = <<128,1,64,0,2,0,0,2>>,
	Sponsor = hex:decode("0x15DE8BB840CB47788A6378CC6DA51B572F38A86A"),
	User = <<128,1,64,0,2,0,0,1>>,
	CAddr= <<128,1,64,0,2,0,0,3>>,

	Ledger=[
			{<<0>>,
			 #{ lstore => #{ <<"fee">> => #{ <<"params">>=> #{ <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>> }, <<"FTT">> => #{ <<"base">> => 1, <<"baseextra">> => 64, <<"kb">> => 10 } }, <<"gas">> => #{ <<"FTT">> => #{ <<"gas">> => 35000, <<"tokens">> => 10 }, <<"SK">> => #{ <<"gas">> => 50000, <<"tokens">> => 1 } }, <<"freegas2">> => #{ CAddr => 1000 } } }
			},
			{Admin, #{amount => #{ <<"SK">> => 1000,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 3000,
									  <<"TEST2">> => 3
									}}},
			{CAddr, #{amount => #{},
					  code =>
					  eevm_asm:asm(
						[{push,1,0},
						 sload,
						 {push,1,1},
						 add,
						 {dup,1},
						 {push,1,0},
						 sstore,
						 {push,1,0},
						 mstore,
						 calldatasize,
						 {dup,1},
						 {push,1,0},
						 {push,1,0},
						 calldatacopy,
						 {push,1,0},
						 return]
					   )
					 }
			}
		   ],

	TXs= [
		  tx:construct_tx(
			#{kind=>deploy,
			  ver=>2,
			  from=>Admin,
			  seq=>1,
			  t=>1,
			  payload=>[
						#{amount=>99,cur=> <<"FTT">>,purpose=>srcfee},
						#{amount=>500,cur=> <<"FTT">>,purpose=>gas},
						#{amount=>2000,cur=> <<"FTT">>,purpose=>transfer}
					   ],
			  txext=>#{"vm"=>"evm",
					   "code"=> read_contract(
								  filename:join(
									proplists:get_value("PWD",os:env(),"."),
									"examples/evm_builtin/build/Sponsor.bin"
								   )
								 )
					  }
			 }),
		  tx:construct_tx(
			#{kind=>generic,
			  ver=>2,
			  from=>Admin,
			  to=>Sponsor,
			  call => #{
						function => "allow(address,uint32,uint32)",
						args => [ CAddr, 3, 0 ]
					   },
			  seq=>2,
			  t=>2,
			  payload=>[
						#{amount=>100,cur=> <<"FTT">>,purpose=>gas},
						#{amount=>10,cur=> <<"FTT">>,purpose=>srcfee}
					   ]
			 }),
		  tx:construct_tx(
			#{kind=>generic,
			  ver=>2,
			  from=>User,
			  to=>User,
			  seq=>2,
			  t=>2,
			  txext => #{
						 "sponsor" => [Sponsor],
						 "callcode" => CAddr
						},
			  payload=>[
						#{amount=>100,cur=> <<"FTT">>,purpose=>gashint},
						#{amount=>10,cur=> <<"FTT">>,purpose=>srcfeehint}
					   ]
			 })
		 ],
	{Patch, _, Res} = do_test3(Ledger, TXs),
	[?assertMatch([{User,storage,<<0>>,<<>>,<<1>>}],
				  lists:filter(fun({A,storage,_,_,_}) ->
									   A==User;(_) -> false
							   end,Patch)),
	 ?assertMatch([{1,_},{1,_},{1,_}],Res)
	].

process_txs3_test() ->
	Sponsor = <<128,1,64,0,2,0,0,200>>,
	UserAddr= <<128,1,64,0,2,0,0,2>>,
	Addr= <<128,1,64,0,2,0,0,1>>,
	CAddr= <<128,1,64,0,2,0,0,3>>,

	Ledger=[
			{<<0>>,
			 #{
			   lstore =>
			   #{
				 <<"fee">> =>
				 #{
				   <<"params">>=> #{ <<"feeaddr">> => <<160, 0, 0, 0, 0, 0, 0, 1>> },
				   <<"FTT">> => #{ <<"base">> => 1, <<"baseextra">> => 64, <<"kb">> => 10 }
				  },
				 <<"gas">> => #{
								<<"FTT">> => #{ <<"gas">> => 35000, <<"tokens">> => 10 },
								<<"SK">> => #{ <<"gas">> => 50000, <<"tokens">> => 1 }
							   },
				 <<"freegas2">> => #{ CAddr => 1000 }

				}
			  }
			},
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									  <<"TEST1">> => 2,
									  <<"FTT">> => 10,
									  <<"TEST2">> => 3
									}}},
			{Sponsor, #{amount => #{
									<<"FTT">> => 1000
								   }
					   }},
			{Addr, #{code=>eevm_asm:assemble(
							 <<"
push 0
push 0
push 0
push 0
push 2
push 9223407223743447044
push 262144
call

returndatasize
dup1
push 0
push 0
returndatacopy
push 0
return
">>)
					}},
			{CAddr, #{code => eevm_asm:assemble(
								<<"
push 38
push32 0x63000003e8600055716000546001018060005560005260206000F360701B6000
push 0
mstore
push 0x5260126000F3
push 208
shl
push 32
mstore

dup1
PUSH 0
PUSH 0
CREATE

push 0
push 0
push 0
push 0
push 0
push 9223723880743436294
push 262144
call

returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>)}}
		   ],

	TXs= [
		  tx:construct_tx(
			#{kind=>deploy,
			  ver=>2,
			  from=>Sponsor,
			  seq=>1,
			  t=>1,
			  payload=>[
						#{amount=>60,cur=> <<"FTT">>,purpose=>srcfee},
						#{amount=>500,cur=> <<"FTT">>,purpose=>gas}
					   ],
			  txext=>#{"vm"=>"evm",
					   "deploy"=>"inplace",
					   "code"=> read_contract(
								  filename:join(
									proplists:get_value("PWD",os:env(),"."),
									"examples/evm_builtin/build/Sponsor.bin"
								   )
								 )
					  }
			 }),
		  tx:construct_tx(
			#{kind=>generic,
			  ver=>2,
			  from=>Sponsor,
			  to=>Sponsor,
			  call => #{
						function => "allow(address,uint32,uint32)",
						args => [ CAddr, 3, 0 ]
					   },
			  seq=>2,
			  t=>2,
			  payload=>[
						#{amount=>100,cur=> <<"FTT">>,purpose=>gas},
						#{amount=>10,cur=> <<"FTT">>,purpose=>srcfee}
					   ]
			 }),

		  tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=>Addr,
			seq=>1,
			t=>1,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"SK">>,purpose=>transfer},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee},
					  #{amount=>2,cur=> <<"TEST1">>,purpose=>transfer},
					  #{amount=>2,cur=> <<"TEST2">>,purpose=>transfer}
					 ]
		   }),
		  tx:construct_tx(
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=>Addr,
			seq=>2,
			t=>2,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>gas},
					  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee},
					  #{amount=>2,cur=> <<"SK">>,purpose=>transfer}
					 ]
		   })

		  ,tx:construct_tx(
			#{kind=>generic,
			  ver=>2,
			  from=>UserAddr,
			  to=>CAddr,
			  seq=>3,
			  t=>3,
			  payload=>[
						%#{amount=>7,cur=> <<"FTT">>,purpose=>gas,sponsor=>Sponsor},
						%#{amount=>2,cur=> <<"FTT">>,purpose=>srcfee,sponsor=>Sponsor},
						#{amount=>7,cur=> <<"FTT">>,purpose=>gashint},
						#{amount=>2,cur=> <<"FTT">>,purpose=>srcfeehint},
						#{amount=>1,cur=> <<"SK">>,purpose=>transfer}
					   ],
			  txext => #{
						 "sponsor"=>[Sponsor]
						}
			 })

		  %,tx:construct_tx(
		  %#{kind=>deploy,
		  %  ver=>2,
		  %  from=>UserAddr,
		  %  seq=>4,
		  %  t=>4,
		  %  payload=>[
		  %  		  #{amount=>2,cur=> <<"FTT">>,purpose=>srcfee},
		  %  		  #{amount=>0,cur=> <<"SK">>,purpose=>transfer}
		  %  		 ],
		  %  txext=>#{"vm"=>"evm",
		  %  		 "code"=>
		  %  		 hex:decode("0x63000003e8600055716000546001018060005560005260206000F360701B6000")
		  %  		}
		  % })
		 ],
	do_test3(Ledger, TXs).

do_test3(Ledger, TXs) ->
	DB=test3_ptx,
	Test=fun(_) ->
				 State0=process_txs:new_state(fun mledger:getfun/2, DB),
				 {StateE,Res}=lists:foldl(
								 fun(Tx, {State,ResAcc}) ->
										 io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
										 {Ret,RetData,State1}=process_txs:process_tx(Tx,
																					 State,
																					 #{}),
										 io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
										 {State1,[{Ret,RetData}|ResAcc]}
								 end, {State0,[]},
								 TXs),
				 Patch=pstate:patch(StateE),
				 io:format("--- [ ~w txs done ] ---~n",[length(TXs)]),
				 FormatCode=fun(Code) when size(Code) < 128 ->
									hex:encodex(Code);
							   (<<Code:100/binary,_/binary>>) ->
									<<(hex:encodex(Code))/binary,"...">>
							end,
				 lists:foreach(
				   fun({Address,Field,Path,Old,New}) ->
						   if(Field == code) ->
								 io:format("~42s ~-10s ~p~n",
										   [hex:encodex(Address),Field,Path]),
								 io:format("\t ~s -> ~s~n",
										   [FormatCode(Old),FormatCode(New)]);
							 (Field == storage) ->
								 io:format("~42s ~-10s ~s ~s -> ~s~n",
										   [hex:encodex(Address),Field,hex:encodex(Path),hex:encodex(Old),hex:encodex(New)]);

							 (is_binary(New)) ->
								 io:format("~42s ~-10s ~p ~s -> ~s~n",
										   [hex:encodex(Address),Field,Path,hex:encodex(Old),hex:encodex(New)]);
							 true ->
								 io:format("~42s ~-10s ~p ~p -> ~p~n",
										   [hex:encodex(Address),Field,Path,Old,New])
						   end
				   end, Patch),
				 {Patch, StateE, Res}
		 end,
	mledger:deploy4test(DB, Ledger, Test).


