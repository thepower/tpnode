-module(smartcontract).
-export([run/5,info/1,getters/1,get/4]).

-callback deploy(Address :: binary(),
         Ledger :: map(),
         Code :: binary(),
         State :: binary()|undefined,
         GasLimit :: integer(),
         GetFun :: fun()) ->
  {'ok', NewLedger :: map()}.

-callback handle_tx(Tx :: map(),
          Ledger :: map(),
          GasLimit :: integer(),
          GetFun :: fun()) ->
  {'ok',  %success finish, emit new txs
   NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
   GasLeft :: integer(),
   EmitTxs :: list()
  } |
  {'ok',  %success finish
   NewState :: 'unchanged' | binary(), % atom unchanged if no state changed
   GasLeft :: integer()
  } |
  {'error', %error during execution
   Reason :: 'insufficient_gas' | string(),
   GasLeft :: integer()
  } |
  {'error', %error during start
   Reason :: string()
  }.

-callback info() -> {Name::binary(), Descr::binary()}.
-type args() :: [{Arg::binary(),int|bin|addr}].
-type fa() :: {Method::binary(), Args::args()}|{Method::binary(), Args::args(), Descr::binary()}.
-callback getters() -> [Getter::fa()].
-callback get(Method::binary(), Args::[binary()|integer()], Ledger :: map()) -> [Getter::mfa()].

info(VMType) ->
  try
    A=erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8),
    {CN,CD}=erlang:apply(A, info, []),
    {ok,CN,CD}
  catch error:badarg ->
          error
  end.

get(VMType,Method,Args,Ledger) -> 
  try
    A=erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8),
    Getters=erlang:apply(A, getters, []),
    case proplists:get_value(Method, Getters) of
      L when is_list(L) ->
        if(length(Args) =/= length(L)) -> 
            throw("bad_args_count");
          true ->
            Args1=lists:map(
                    fun({{_,int},Value}) ->
                        binary_to_integer(Value);
                       ({{_,addr},Value}) ->
                        naddress:parse(Value);
                       ({{_,bin},Value}) ->
                        Value;
                       ({{_,Unknown},_}) ->
                        throw({"unsupported_type",Unknown})
                    end,
                    lists:zip(L,Args)),
            lager:info("Expected args ~p",[lists:zip(L,Args)]),
            lager:info("Calling ~p:get(~p,~p,~p)",[A,Method,Args1,Ledger]),
            Res=erlang:apply(A, get, [Method,Args1,Ledger]),
            {ok,Res}
        end;
      undefined ->
        throw("bad_method")
    end
  catch error:badarg ->
          error
  end.

getters(VMType) -> 
  try
    A=erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8),
    Res=erlang:apply(A, getters, []),
    {ok,Res}
  catch error:badarg ->
          error
  end.

run(VMType, #{to:=To}=Tx, Ledger, {GCur,GAmount,GRate}, GetFun) ->
  GasLimit=trunc(GAmount*GRate),
  Left=fun(GL) ->
           lager:info("VM run gas ~p -> ~p",[GasLimit,GL]),
           {GCur, GL div GRate, GRate}
       end,
  VM=try
       erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8)
     catch error:badarg ->
             throw('unknown_vm')
     end,
  lager:info("run contract ~s for ~s gas limit ~p", [VM, naddress:encode(To),GasLimit]),
  try
    case erlang:apply(VM,
                      handle_tx,
                      [Tx, Ledger, GasLimit, GetFun]) of
      {ok, NewState, GasLeft, EmitTxs} when
          NewState==unchanged orelse is_binary(NewState) ->
        if NewState == unchanged ->
             {Ledger, EmitTxs, Left(GasLeft)};
           true ->
             {
              bal:put(state, NewState, Ledger),
              EmitTxs, Left(GasLeft)}
        end;
      {ok, NewState, GasLeft} when
          NewState==unchanged orelse is_binary(NewState) ->
        if NewState == unchanged ->
             {Ledger, [], Left(GasLeft)};
           true ->
             {
              bal:put(state, NewState, Ledger),
              [], Left(GasLeft)}
        end;
      {ok,#{null := "exec",
            "gas" := GasLeft,
            "state" := NewState,
            "txs" := EmitTxs}} ->
        if NewState == <<>> ->
             {Ledger, EmitTxs, Left(GasLeft)};
           true ->
             {
              bal:put(state, NewState, Ledger),
              EmitTxs, Left(GasLeft)}
        end;
      {ok,#{null := "exec",
            "gas" := _GasLeft,
            "err":=SReason}} ->
        lager:error("Contract error ~p", [SReason]),
        try
          throw(list_to_existing_atom(SReason))
        catch error:badarg ->
                throw({'run_failed', SReason})
        end;
      {error, Reason, GasLeft} ->
        %throw({'run_failed', Reason});
        lager:error("Contract error ~p", [Reason]),
        {Ledger, [], Left(GasLeft)};
      {error, Reason} ->
        throw({'run_failed', Reason});
      Any ->
        lager:error("Contract return error ~p", [Any]),
        throw({'run_failed', other})
    end
  catch 
    Ec:Ee when Ec=/=throw ->
          S=erlang:get_stacktrace(),
          lager:error("Can't run contract ~p:~p @ ~p",
                      [Ec, Ee, hd(S)]),
          throw({'contract_error', [Ec, Ee]})
  end.

