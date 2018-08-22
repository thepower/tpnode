%% -*- syntax: erlang -*-

Run=fun
  (deploy,"init",[InitVal]) when is_integer(InitVal) ->
    {ok, "result", <<InitVal:64/big>>, Gas-1, []};
  (deploy,"init",_) ->
    {ok, "result", <<0:64/big>>, Gas-1, []};
  (generic,"inc",[Val]) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<"state">>, Ledger),
    S1=S0+Val,
    {ok, "result", <<S1:64/big>>, Gas-1, []};
  (generic,"dec",[Val]) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<"state">>, Ledger),
    S1=S0-Val,
    {ok, "result", <<S1:64/big>>, Gas-100, []};
  (generic,"expensive",[Val]) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<"state">>, Ledger),
    S1=S0-Val,
    {ok, "result", <<S1:64/big>>, Gas-10000, []};
  (generic,_,_) ->
    <<S0:64/big>>=maps:get(<<"state">>, Ledger),
    S1=S0+1,
    {ok, "result", <<S1:64/big>>, Gas-1, []}
end,

Kind=maps:get(kind, Tx),
#{args := A,function := F}=maps:get(call, Tx, #{args => [],function => "default"}),

%io:format("Ledger ~p~n",[maps:without([<<"code">>,<<"state">>],Ledger)]),
%io:format("Tx ~p~n",[maps:without([body,sig],Tx)]),
%io:format("Gas ~p~n",[Gas]),
%io:format("Pid ~p~n",[self()]),

%{ok, "result", <<"new_state">>, Gas-100, []}.
Res=Run(Kind, F, A),


%error_logger:info_msg("call ~s(~s, ~s, ~p)=~p",[testcontract,Kind,F,A,Res]),
Res.

