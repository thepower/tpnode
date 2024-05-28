-module(smartcontract).
-include("include/tplog.hrl").
-export([run/6,info/1,getters/1,get/4]).

-callback deploy(Address :: binary(),
         Ledger :: map(),
         Code :: binary(),
         State :: binary()|undefined,
         GasLimit :: integer(),
         GetFun :: fun(),
         Opaque :: map()) ->
  {'ok', NewLedger :: map(), Opaque :: map()}.

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
            ?LOG_INFO("Expected args ~p",[lists:zip(L,Args)]),
            ?LOG_INFO("Calling ~p:get(~p,~p,~p)",[A,Method,Args1,Ledger]),
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

run(VMType, #{to:=To}=Tx, Ledger, free, GetFun, Opaque) ->
  run(VMType, #{to:=To}=Tx, Ledger, {<<"SK">>,100,{10000000,1}}, GetFun, Opaque);

run(VMType, #{to:=To}=Tx, Ledger, {GCur,GAmount,{GNum,GDen}=GRate}, GetFun, Opaque) ->
  %io:format("smartcontract Opaque ~p~n",[Opaque]),
  GasLimit=(GAmount*GNum) div GDen,
  Left=fun(GL) ->
           ?LOG_INFO("VM run gas ~p -> ~p (~p)",[GasLimit,GL, min(GasLimit,GL)]),
           %use min, retrned gas might be greater than sent, because deleting data using sstore
           %might return 15k gas.
           {GCur, (min(GasLimit,GL)*GDen) div GNum, GRate}
       end,
  VM=try
       erlang:binary_to_existing_atom(<<"contract_", VMType/binary>>, utf8)
     catch error:badarg ->
             throw('unknown_vm')
     end,
  ?LOG_INFO("run contract ~s for ~s gas limit ~p", [VM, naddress:encode(To),GasLimit]),
  try
    CallRes=erlang:apply(VM,
                         handle_tx,
                         [Tx, mbal:msgpack_state(Ledger), GasLimit, GetFun, Opaque]),
    case CallRes of
%      {ok, unchanged, GasLeft, EmitTxs} ->
%        {Ledger,
%         EmitTxs,
%         Left(GasLeft),
%         Opaque
%        };
%      {ok, NewState, GasLeft, EmitTxs} when is_binary(NewState) ->
%        {
%         mbal:put(state, NewState, Ledger),
%         EmitTxs,
%         Left(GasLeft),
%         Opaque
%        };
%      {ok, unchanged, GasLeft} ->
%        {Ledger,
%         [],
%         Left(GasLeft),
%         Opaque
%        };
%      {ok, NewState, GasLeft} when is_binary(NewState) ->
%        {
%         mbal:put(state, NewState, Ledger),
%         [], Left(GasLeft),
%         Opaque
%        };
      {ok,
       #{null := "exec",
            "gas" := GasLeft,
            "state" := NewState,
            "txs" := EmitTxs}, Opaque1} when NewState == <<>> orelse NewState == unchanged ->
        {[], EmitTxs, Left(GasLeft), Opaque1};
      {ok,
       #{null := "exec",
         "gas" := GasLeft,
         "state" := NewState,
         "txs" := EmitTxs}, Opaque1} ->
        {
         [{state, NewState}],
         EmitTxs,
         Left(GasLeft),
         Opaque1};
      {ok,
       #{null := "exec",
         "gas" := GasLeft,
         "storage" := NewState,
         "txs" := EmitTxs}, Opaque1} ->
        {
         [{mergestate, NewState}],
         EmitTxs, Left(GasLeft),
         Opaque1
        };

      {ok,
       #{null := "exec",
            "gas" := GasLeft,
            "state" := NewState,
            "txs" := EmitTxs}} when NewState == <<>> orelse NewState == unchanged ->
        {[], EmitTxs, Left(GasLeft), Opaque};
      {ok,
       #{null := "exec",
         "gas" := GasLeft,
         "state" := NewState,
         "txs" := EmitTxs}} ->
        {
         [{state, NewState}],
         EmitTxs,
         Left(GasLeft),
         Opaque};
      {ok,
       #{null := "exec",
         "gas" := GasLeft,
         "storage" := NewState,
         "txs" := EmitTxs}} ->
        {
         [{mergestate, NewState}],
         EmitTxs, Left(GasLeft),
         Opaque
        };
      {ok,#{null := "exec",
            "gas" := _GasLeft,
            "err":=SReason}} ->
        ?LOG_ERROR("Contract error ~p", [SReason]),
        try
          throw(list_to_existing_atom(SReason))
        catch error:badarg ->
                throw({'run_failed', SReason})
        end;
      {error, nogas, _} ->
        throw('insufficient_gas');
      {error, Reason, _GasLeft} ->
        ?LOG_ERROR("Contract error ~p", [Reason]),
        throw({'run_failed', Reason});
        %{[], [], Left(GasLeft), Opaque};
      {error, Reason} ->
        throw({'run_failed', Reason});
      Any ->
        io:format("Contract return error ~p", [Any]),
        ?LOG_ERROR("Contract return error ~p", [Any]),
        throw({'run_failed', other})
    end
  catch
    Ec:Ee:S when Ec=/=throw ->
          ?LOG_INFO("Can't run contract ~p:~p @ ~p/~p~n",
                      [Ec, Ee, hd(S),hd(tl(S))]),
          ?LOG_DEBUG("Stack ~p",[S]),
          throw({'contract_error', [Ec, Ee]})
  end.

