-module(mledger_test).
-include_lib("eunit/include/eunit.hrl").

mledger_test() ->
  Addr= <<128,1,64,0,2,0,0,1>>,
  D0 = #{amount => #{
					 <<"FTT">> => 110,
					 <<"SK">> => 10,
					 <<"TST">> => 26
					},
		 seq => 1,
		 state => #{ <<0>> => <<0>>, <<1>> => <<1>>, <<2>> => <<1>>,
					 <<"updated">> => <<"old_value_to_update">>,
					 <<"deleted">> => <<"old_value_to_delete">>
				   },
		 t => 1512047425350,
		 lastblk => <<0:64>>,
		 lstore=><<129,196,6,101,120,105,115,116,115,1>>
		},
  D1 = #{amount => #{
					 <<"FTT">> => 100,
					 <<"SK">> => 10,
					 <<"TST">> => 26
					},
		 state => #{ <<0>> => <<1>>, <<1>> => <<>>, <<3>> => <<4>>,
					 <<"created">> => <<"new_item">>,
					 <<"updated">> => <<"updated_value">>,
					 <<"deleted">> => <<>>
				   },
		 lstore=><<129,196,6,101,120,105,115,116,115,0>>,
		 seq => 555,
		 changes => [state, seq]
		},
  Test=fun(_) ->
			   T0=[
				   ?assertMatch({ok,<<"old_value_to_delete">>},mledger:get_kpv(Addr,state,<<"deleted">>)),
				   ?assertMatch({ok,<<"old_value_to_update">>},mledger:get_kpv(Addr,state,<<"updated">>)),
				   ?assertMatch({ok,#{ <<"FTT">> := 110, <<"SK">> := 10, <<"TST">> := 26 }},mledger:get_kpv(Addr,amount,[])),
				   ?assertMatch(undefined,mledger:get_kpv(Addr,state,<<"created">>)),
				   ?assertMatch({ok,<<0>>},mledger:get_kpv(Addr,state,<<0>>)),
				   ?assertMatch({ok,<<1>>},mledger:get_kpv(Addr,state,<<1>>))
				  ],

           {ok, LedgerHash0}=mledger:apply_patch([],check),

           Patch=mledger:bals2patch(maps:to_list(#{Addr => D1})),
		   %io:format("Patch ~p~n",[Patch]),
           {ok, LedgerHash1}=mledger:apply_patch(Patch,{commit,2}),
           {ok, LedgerHash2}=mledger:apply_patch([],check),

           %io:format("LH0 ~p~n", [LedgerHash0]),
           %io:format("LH1 ~p~n", [LedgerHash1]),
           %io:format("LH2 ~p~n", [LedgerHash2]),

		   T1=[
			   ?assertMatch({ok,<<1>>},mledger:get_kpv(Addr,state,<<0>>)),
			   ?assertMatch(undefined,mledger:get_kpv(Addr,state,<<1>>)),
			   ?assertMatch(undefined,mledger:get_kpv(Addr,state,<<"deleted">>)),
			   ?assertMatch({ok,<<"updated_value">>},mledger:get_kpv(Addr,state,<<"updated">>)),
			   ?assertMatch({ok,<<"new_item">>},mledger:get_kpv(Addr,state,<<"created">>)),
			   ?assertMatch({ok,#{ <<"FTT">> := 100, <<"SK">> := 10, <<"TST">> := 26 }},mledger:get_kpv(Addr,amount,[])),
			   ?assertNotEqual(LedgerHash0, LedgerHash1),
			   ?assertEqual(LedgerHash1, LedgerHash2)
			  ],
		   {ok,LedgerHash3}=mledger:rollback(2,LedgerHash0),

		   %io:format("~p~n",[ mledger:get_vers(Addr) ]),

		   T3=[
			   ?assertMatch({ok,<<"old_value_to_delete">>},mledger:get_kpv(Addr,state,<<"deleted">>)),
			   ?assertMatch({ok,<<"old_value_to_update">>},mledger:get_kpv(Addr,state,<<"updated">>)),
			   ?assertMatch(undefined,mledger:get_kpv(Addr,state,<<"created">>)),
			   ?assertMatch({ok,#{ <<"FTT">> := 110, <<"SK">> := 10, <<"TST">> := 26 }},mledger:get_kpv(Addr,amount,[])),
			   ?assertEqual(LedgerHash0, LedgerHash3)
			  ],
		   T0++T1++T3
       end,
  Ledger=[
          {Addr,
		   D0
           
          }
         ],
  mledger:deploy4test(Ledger, Test).

