%% -*- syntax: erlang -*-

io:format("Preved from sc~n"),
io:format("Mean time is ~p~n",[MeanTime]),
{ok,State} = msgpack:unpack(maps:get(<<"state">>, Ledger,<<128>>)),

Run=fun
  (deploy,"init",[InitVal], _Tx) when is_integer(InitVal) ->
    {ok, "result", #{<<0>> => <<InitVal:64/big>>}, Gas, []};
  (deploy,"init",_, _Tx) ->
    {ok, "result", #{<<0>> => <<0:64/big>>}, Gas-1, []};
  (deploy,"expensive",_, _Tx) ->
    {ok, "result", #{<<0>> => <<0:64/big>>}, Gas-10000, []};
  (deploy,_,_, _Tx) ->
    throw('error');
  (generic,"inc",[Val], _Tx) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<0>>,State),
    S1=S0+Val,
    {ok, "result", #{<<0>> => <<S1:64/big>>}, Gas-1, []};
  (generic,"dec",[Val], _Tx) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<0>>,State),
    S1=S0-Val,
    {ok, "result", #{<<0>> => <<S1:64/big>>}, Gas-100, []};
  (generic,"expensive",[Val], _Tx) when is_integer(Val) ->
    <<S0:64/big>>=maps:get(<<0>>,State),
    S1=S0-Val,
    {ok, "result", #{<<0>> => <<S1:64/big>>}, Gas-10000, []};
 (generic,"notify",[Val], #{from:=F}) when is_integer(Val) ->
    NewTx=#{ver=>2,kind=>notify,from=>F,
      t=>0,
      seq=>0,
      payload=>[],
      notify=>[{"http://10.250.250.240/test/endpoint",<<"preved, medved",Val:32/big>>}]
    },
    NTX=maps:get(body,tx:construct_tx(NewTx)),
    S0=maps:get(<<0>>,State),
    {ok, "result", #{<<0>> => S0}, Gas, [NTX]};
 (generic,"badnotify",[Val], #{from:=F}) when is_integer(Val) ->
    NTX= <<130,161,107,23,162,101,118,145,146,217,33,104,116,116,112,58,47,47,53,49,46,49,53,57,46,53,55,46,57,54,58,51,48,48,48,47,103,101,116,111,119,110,101,114,196,12,72,101,108,108,111,32,119,111,114,108,100,33>>,
    S0=maps:get(<<0>>,State),
    {ok, "result", #{<<0>> => S0}, Gas, [NTX]};
 (generic,"emit",[Val], #{from:=F}) when is_integer(Val) ->
    NewTx=#{ver=>2,kind=>generic,from=>F,
    to=>F,
    t=>0,
    seq=>0,
    payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
    call=>#{function=>"notify",args=>[512]}
    },
    NTX=maps:get(body,tx:construct_tx(NewTx)),
    S0=maps:get(<<0>>,State),
    {ok, "result", #{<<0>> => S0}, Gas, [NTX]};
 (generic,"delayjob",[Val], #{from:=F}) when is_integer(Val) ->
    NewTx=#{ver=>2,kind=>generic,from=>F,
    to=>F,
    t=>0,
    seq=>0,
    not_before => (MeanTime div 1000) + 60,
    payload=>[#{purpose=>gas, amount=>50000, cur=><<"FTT">>}],
    call=>#{function=>"notify",args=>[512]}
    },
    NTX=maps:get(body,tx:construct_tx(NewTx)),
    S0=maps:get(<<0>>,State),
    {ok, "result", #{<<0>> => S0}, Gas, [NTX]};
  (generic,_,_, _Tx) ->
    <<S0:64/big>>=maps:get(<<0>>,State),
    S1=S0+1,
    {ok, "result", #{<<0>> => <<S1:64/big>>}, Gas-1, []}
end,

Kind=maps:get(kind, Tx),
#{args := A,function := F}=maps:get(call, Tx, #{args => [],function => "default"}),

%io:format("Ledger ~p~n",[maps:without([<<"code">>,<<"state">>],Ledger)]),
io:format("Tx ~p~n",[maps:without([body,sig],Tx)]),
io:format("Call ~s(~p)~n",[F,A]),
io:format("Gas ~p~n",[Gas]),
%io:format("Pid ~p~n",[self()]),

%{ok, "result", <<"new_state">>, Gas-100, []}.
Res=Run(Kind, F, A, Tx),

io:format("call ~s(~s, ~s, ~p)=~p~n",[testcontract,Kind,F,A,Res]),
Res.

