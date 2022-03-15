-module(contract_evm).
-behaviour(smartcontract2).

-export([deploy/4, handle_tx/4, getters/0, get/3, info/0]).

info() ->
	{<<"evm">>, <<"EVM">>}.

convert_storage(Map) ->
  maps:fold(
    fun(K,0,A) ->
        maps:put(binary:encode_unsigned(K), remove, A);
       (K,V,A) ->
        maps:put(binary:encode_unsigned(K), binary:encode_unsigned(V), A)
    end,#{},Map).


deploy(#{from:=From,txext:=#{"code":=Code}=_TE}=Tx, Ledger, GasLimit, _GetFun) ->
  %DefCur=maps:get("evmcur",TE,<<"SK">>),
  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A} ->
            A
        end,

  Logger=fun(Message,Args) ->
             lager:info("EVM tx ~p log ~p ~p",[Tx,Message,Args])
         end,

  State=maps:get(state,Ledger,#{}),
  case eevm:eval(Code,
                 State,
                 #{
                   logger=>Logger,
                   gas=>GasLimit,
                   value=>Value,
                   caller=>binary:decode_unsigned(From),
                   trace=>whereis(eevm_tracer)
                  }) of
    {done, {return,NewCode}, #{ gas:=GasLeft, storage:=NewStorage }} ->
      {ok, #{null=>"exec", "code"=>NewCode, "state"=>convert_storage(NewStorage), "gas"=>GasLeft }};
    {done, 'stop', _} ->
      {error, deploy_stop};
    {done, 'invalid', _} ->
      {error, deploy_invalid};
    {done, {revert, _}, _} ->
      {error, deploy_revert};
    {error, nogas, _} ->
      {error, nogas};
    {error, {jump_to,_}, _} ->
      {error, bad_jump};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction}
%
% {done, [stop|invalid|{revert,Err}|{return,Data}], State1}
% {error,[nogas|{jump_to,Dst}|{bad_instruction,Instr}], State1}


    %{done,{revert,Data},#{gas:=G}=S2};
  end.

handle_tx(#{from:=From}=Tx, #{state:=State0,code:=Code}=_Ledger, GasLimit, _GetFun) ->
  {ok,State}=msgpack:unpack(State0),

  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A} ->
            A
        end,

  Logger=fun(Message,Args) ->
             lager:info("EVM tx ~p log ~p ~p",[Tx,Message,Args])
         end,
  SLoad=fun(IKey) ->
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(maps:get(BKey, State, <<0>>))
        end,
  EncodeArg=fun(Arg,Acc) when is_integer(Arg) ->
                <<Acc/binary,Arg:256/big>>;
               (<<Arg:64/big>>,Acc) ->
                <<Acc/binary,Arg:256/big>>
            end,
  CD=case Tx of
       #{call:=#{function:="0x"++FunID,args:=CArgs}} ->
         FunHex=hex:decode(FunID),
         lists:foldl(EncodeArg, <<FunHex:4/binary>>, CArgs);
       #{call:=#{function:=FunNameID,args:=CArgs}} when is_list(FunNameID) ->
         {ok,E}=ksha3:hash(256, list_to_binary(FunNameID)),
         <<X:4/binary,_/binary>> = E,
         lists:foldl(EncodeArg, <<X:4/binary>>, CArgs);
       _ ->
         <<>>
     end,


  Result = eevm:eval(Code,
                 #{},
                 #{
                   logger=>Logger,
                   gas=>GasLimit,
                   sload=>SLoad,
                   value=>Value,
                   cd=>CD,
                   caller=>binary:decode_unsigned(From),
                   trace=>whereis(eevm_tracer)
                  }),

  io:format("Call ~p -> {~p,~p,...}~n",[CD, element(1,Result),element(2,Result)]),
  case Result of
    {done, {return,RetVal}, #{ gas:=GasLeft, storage:=NewStorage }} ->
      {ok, #{null=>"exec",
             "state"=>convert_storage(NewStorage),
             "return"=>RetVal,
             "gas"=>GasLeft}};
    {done, 'stop', #{ gas:=GasLeft, storage:=NewStorage }} ->
      {ok, #{null=>"exec",
             "state"=>convert_storage(NewStorage),
             "gas"=>GasLeft}};
    {done, 'invalid', _} ->
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>0}};
    {done, {revert, _}, #{ gas:=GasLeft}} ->
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>GasLeft}};
    {error, nogas, #{storage:=NewStorage}} ->
      io:format("St ~w keys~n",[maps:size(NewStorage)]),
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.




getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

