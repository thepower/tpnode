-module(process_txs_test).
-include_lib("eunit/include/eunit.hrl").
-export([testdata_deploy/1]).


lstore_test() ->
	UserAddr= <<128,1,64,0,2,0,0,2>>,
	Ledger=[
			{UserAddr, #{amount => #{ <<"SK">> => 10 },
						 lstore => #{
									 <<"a">> => <<123>>,
									 <<"map">> => #{
													<<"a">> => 1,
													<<"b">> => [3,2]
												   },
									 <<"list">> => [1,2,3]
									}
						}}
		   ],
	Gas0=100000,
	TXs= [
		  #{kind=>lstore,
			ver=>2,
			from=>UserAddr,
			seq=>1,
			patches => [
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"map">>,<<"c">>,1], <<"v">>=>1},
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"map">>,<<"c">>,<<"c">>], <<"v">>=>2},
						#{<<"t">>=><<"compare">>, <<"p">>=>[<<"map">>,<<"b">>], <<"v">>=>[3,2]},
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"map">>,<<"b">>], <<"v">>=>[1,2,3]},
						%#{<<"t">>=><<"compare">>, <<"p">>=>[<<"map">>,<<"b">>], <<"v">>=>[1,2,3]},
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"map">>,<<"c">>,<<"array">>], <<"v">>=>[1,2,3]},
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"map">>,<<"c">>,1], <<"v">>=>1234},
						#{<<"t">>=><<"set">>, <<"p">>=>[<<"list">>], <<"v">>=>[1,2,3]}
					   ]
		   }
		 ],

	DB=test_ptx,
	Test=fun(_) ->
				 State0=process_txs:new_state(fun mledger:getfun/2, DB),
				 {_GasE,StateE}=lists:foldl(
								 fun(Tx, {Gas, State}) ->
										 io:format("Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
										 {Ret,RetData,Gas1,State1}=process_txs:process_tx(Tx, Gas, State, []),
										 io:format(" - Ret ~w: ~p~n",[Ret, RetData]),
										 {Gas1, State1}
								 end, {Gas0, State0},
								 TXs),
				 Patch=pstate:patch(StateE),
				 io:format("--- [ ~w txs done ] ---~n",[length(TXs)]),
				 lists:foreach(
				   fun({Address,Field,Path,Old,New}) ->
						   if(Field == code) ->
								 io:format("~42s ~-10s ~p~n",
										   [hex:encodex(Address),Field,Path]),
								 io:format("\t ~s -> ~s~n",
										   [hex:encodex(Old),hex:encodex(New)]);
							 (is_binary(New)) ->
								 io:format("~42s ~-10s ~100p ~s -> ~s~n",
										   [hex:encodex(Address),Field,Path,hex:encodex(Old),hex:encodex(New)]);
							 true ->
								 io:format("~42s ~-10s ~150p ~150p -> ~150p~n",
										   [hex:encodex(Address),Field,Path,Old,New])
						   end
				   end, Patch),
				 io:format("~p~n",[maps:get(lstore_patches,StateE)]),
				 Patch
		 end,
	mledger:deploy4test(DB, Ledger, Test).


process_txs4_test() ->
	UserAddr= <<128,1,64,0,2,0,0,2>>,
	Addr= <<128,1,64,0,2,0,0,1>>,
	CAddr= <<128,1,64,0,2,0,0,3>>,
	Ledger=[
			{UserAddr, #{amount => #{ <<"SK">> => 10,
									<<"TEST1">> => 2,
									<<"TEST2">> => 3
									}}},
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

	Gas0=100000,
	TXs= [
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=>Addr,
			seq=>1,
			payload=>[
					  #{amount=>2,cur=> <<"SK">>,purpose=>transfer},
					  #{amount=>2,cur=> <<"TEST1">>,purpose=>transfer},
					  #{amount=>2,cur=> <<"TEST2">>,purpose=>transfer}
					 ]
		   },
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=>Addr,
			seq=>2,
			payload=>[
					  #{amount=>2,cur=> <<"SK">>,purpose=>transfer}
					 ]
		   },
		  #{kind=>generic,
			ver=>2,
			from=>UserAddr,
			to=>CAddr,
			seq=>3,
			payload=>[
					  #{amount=>1,cur=> <<"SK">>,purpose=>transfer}
					 ]
		   },
		  #{kind=>deploy,
			ver=>2,
			from=>UserAddr,
			seq=>4,
			payload=>[
					  #{amount=>0,cur=> <<"SK">>,purpose=>transfer}
					 ],
			txext=>#{"vm"=>"evm",
					 "code"=>
					 hex:decode("0x63000003e8600055716000546001018060005560005260206000F360701B6000")
					}
		   }
		 ],
	{_Patch, _StateE, GasE} = do_test4(Ledger, TXs, Gas0),
	GasE.

tstore_test() ->
  UserAddr= <<128,1,64,0,2,0,0,2>>,
  Addr= <<128,1,64,0,2,0,0,1>>,
  Ledger=[
		  {UserAddr, #{amount => #{ <<"SK">> => 10 }}},
		  {Addr, #{code=>eevm_asm:assemble(
						   <<"
push1 0
tload
push1 1
add
dup1
push1 0
tstore
push1 0
sstore

gas
push 5000
gt
push ret
jumpi

push1 0
push1 0
push1 0
push1 0
push1 0
address
push3 20000
call

jumpdest ret
returndatasize
dup1
push1 0
push1 0
returndatacopy
push1 0
return
">>)
				  }}
		 ],
  TXs= [
		#{kind=>generic,
		  ver=>2,
		  from=>UserAddr,
		  to=>Addr,
		  seq=>1,
		  payload=>[]
		 }
	   ],

  {Patch,_,_}=do_test4(Ledger, TXs, 100000),

  [
   ?assertMatch([{_,storage,<<0>>,<<>>,<<4>>}],Patch)
  ].



do_test4(Ledger, TXs, Gas0) ->
	DB=test_ptx,
	Test=fun(_) ->
				 State0=process_txs:new_state(fun mledger:getfun/2, DB),
				 {GasE,StateE}=lists:foldl(
								 fun(Tx, {Gas, State}) ->
										 io:format("Exec tx ~100p~n",[maps:with([from,to,kind],Tx)]),
										 {Ret,RetData,Gas1,State1}=process_txs:process_tx(Tx, Gas, State, []),
										 io:format(" - Ret ~w: ~p~n",[Ret, RetData]),
										 {Gas1, State1}
								 end, {Gas0, State0},
								 TXs),
				 Patch=pstate:patch(StateE),
				 io:format("--- [ ~w txs done ] ---~n",[length(TXs)]),
				 lists:foreach(
				   fun({Address,Field,Path,Old,New}) ->
						   if(Field == code) ->
								 io:format("~42s ~-10s ~p~n",
										   [hex:encodex(Address),Field,Path]),
								 io:format("\t ~s -> ~s~n",
										   [hex:encodex(Old),hex:encodex(New)]);
							 (is_binary(New)) ->
								 io:format("~42s ~-10s ~p ~s -> ~s~n",
										   [hex:encodex(Address),Field,Path,hex:encodex(Old),hex:encodex(New)]);
							 true ->
								 io:format("~42s ~-10s ~p ~p -> ~p~n",
										   [hex:encodex(Address),Field,Path,Old,New])
						   end
				   end, Patch),
				 {Patch, StateE, GasE}
		 end,
	mledger:deploy4test(DB, Ledger, Test).


testdata_deploy(DBName) ->
	LedgerData=[{<<1>>, #{ lstore => #{
				 <<"key1">> => 1,
				 <<"key2">> => <<"bin">>,
				 <<"key3">> => [<<$l>>,<<$i>>,<<$s>>,<<$t>>],
				 <<"key4">> => [$l,$>,$s,$t],
				 <<"map">> => #{
								<<"int">> => 1,
								<<"bin">> => <<"value">>,
								123 => 321
							   }
				}}}],
  application:start(rockstable),
  TmpDir="/tmp/"++atom_to_list(DBName)++"_test."++(integer_to_list(os:system_time(),16)),
  filelib:ensure_dir(TmpDir),
  ok=rockstable:open_db(DBName, TmpDir, mledger:tables(DBName)),
  Patches=mledger:bals2patch(LedgerData),
  {ok,LH}=mledger:apply_patch(DBName, Patches, {commit,0}),
  LH.



