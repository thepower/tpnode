%% -*- mode: erlang -*-

%io:format("Ledger ~p~n",[Ledger]),
%io:format("Tx ~p~n",[Tx]),
%io:format("Gas ~p~n",[Gas]),
io:format("Pid ~p~n",[self()]),

{ok, "result", <<"new_state">>, Gas-100, []}.

