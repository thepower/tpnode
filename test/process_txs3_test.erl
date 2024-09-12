-module(process_txs3_test).
-include_lib("eunit/include/eunit.hrl").

read_contract(Filename) ->
	{ok,HexBin} = file:read_file(Filename),
	hex:decode(HexBin).


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
				 StateE=lists:foldl(
								 fun(Tx, State) ->
										 io:format(" = > Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
										 {Ret,RetData,State1}=process_txs:process_tx(Tx,
																					 State, 
																					 #{}),
										 io:format(" < = Ret ~w: ~p~n",[Ret, RetData]),
										 State1
								 end, State0,
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
				 %{Patch, StateE}
				 StateE
		 end,
	mledger:deploy4test(DB, Ledger, Test).


