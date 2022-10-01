-module(contract_evm).
-include("include/tplog.hrl").
-behaviour(smartcontract2).

-export([deploy/5, handle_tx/5, getters/0, get/3, info/0, call/3]).
-export([transform_extra/1]).

info() ->
	{<<"evm">>, <<"EVM">>}.

convert_storage(Map) ->
  maps:fold(
    fun(K,0,A) ->
        maps:put(binary:encode_unsigned(K), <<>>, A);
       (K,V,A) ->
        maps:put(binary:encode_unsigned(K), binary:encode_unsigned(V), A)
    end,#{},Map).


deploy(#{from:=From,txext:=#{"code":=Code}=_TE}=Tx, Ledger, GasLimit, GetFun, Opaque) ->
  %DefCur=maps:get("evmcur",TE,<<"SK">>),
  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A,cur:= <<"SK">>} ->
            A;
          _ ->
            0
        end,

  State=case maps:get(state,Ledger,#{}) of
          Map when is_map(Map) -> Map;
          _ -> #{}
        end,
  Functions=#{
              16#AFFFFFFFFF000000 => fun(_) ->
                                         MT=maps:get(mean_time,Opaque,0),
                                         Ent=case maps:get(entropy,Opaque,<<>>) of
                                               Ent1 when is_binary(Ent1) ->
                                                 Ent1;
                                               _ ->
                                                 <<>>
                                             end,
                                         {1,<<MT:256/big,Ent/binary>>}
                                     end,
              16#AFFFFFFFFF000001 => fun(Bin) ->
                                         {1,list_to_binary(
                                              lists:reverse(
                                                binary_to_list(Bin)
                                               )
                                             )}
                                     end
            },
  GetCodeFun = fun(Addr,Ex0) ->
                   io:format(".: Get code for  ~p~n",[Addr]),
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=GetFun({addr,binary:encode_unsigned(Addr),code}),
                       {ok, GotCode, maps:put({Addr,code},GotCode,Ex0)}
                   end
               end,
  GetBalFun = fun(Addr,Ex0) ->
                  case maps:is_key({Addr,value},Ex0) of
                    true ->
                      maps:get({Addr,value},Ex0);
                    false ->
                      0
                  end
              end,

  EvalRes = eevm:eval(Code,
                      State,
                      #{
                        extra=>Opaque,
                        logger=>fun logger/4,
                        gas=>GasLimit,
                        get=>#{
                               code => GetCodeFun,
                               balance => GetBalFun
                              },
                        data=>#{
                                address=>binary:decode_unsigned(From),
                                callvalue=>Value,
                                caller=>binary:decode_unsigned(From),
                                gasprice=>1,
                                origin=>binary:decode_unsigned(From)
                               },
                        embedded_code => Functions,
                        trace=>whereis(eevm_tracer)
                       }),
  %io:format("EvalRes ~p~n",[EvalRes]),
  case EvalRes of
    {done, {return,NewCode}, #{ gas:=GasLeft, storage:=NewStorage }} ->
      io:format("Deploy -> OK~n",[]),
      {ok, #{null=>"exec",
             "code"=>NewCode,
             "state"=>convert_storage(NewStorage),
             "gas"=>GasLeft,
             "txs"=>[]
            }, Opaque};
    {done, 'stop', _} ->
      io:format("Deploy -> stop~n",[]),
      {error, deploy_stop};
    {done, 'invalid', _} ->
      io:format("Deploy -> invalid~n",[]),
      {error, deploy_invalid};
    {done, {revert, _}, _} ->
      io:format("Deploy -> revert~n",[]),
      {error, deploy_revert};
    {error, nogas, _} ->
      io:format("Deploy -> nogas~n",[]),
      {error, nogas};
    {error, {jump_to,_}, _} ->
      io:format("Deploy -> bad_jump~n",[]),
      {error, bad_jump};
    {error, {bad_instruction,_}, _} ->
      io:format("Deploy -> bad_instruction~n",[]),
      {error, bad_instruction}
%
% {done, [stop|invalid|{revert,Err}|{return,Data}], State1}
% {error,[nogas|{jump_to,Dst}|{bad_instruction,Instr}], State1}


    %{done,{revert,Data},#{gas:=G}=S2};
  end.

encode_arg(Arg,Acc) when is_integer(Arg) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(<<Arg:256/big>>,Acc) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(<<Arg:64/big>>,Acc) ->
  <<Acc/binary,Arg:256/big>>;
encode_arg(_,_) ->
  throw(arg_encoding_error).


handle_tx(#{to:=To,from:=From}=Tx, #{code:=Code}=Ledger,
          GasLimit, GetFun, #{log:=PreLog}=Opaque) ->
  State=case maps:get(state,Ledger,#{}) of
          BinState when is_binary(BinState) ->
            {ok,MapState}=msgpack:unpack(BinState),
            MapState;
          MapState when is_map(MapState) ->
            MapState
        end,

  Value=case tx:get_payload(Tx, transfer) of
          undefined ->
            0;
          #{amount:=A,cur:= <<"SK">>} ->
            A;
          _ ->
            0
        end,

  CD=case Tx of
       #{call:=#{function:="0x0",args:=[Arg1]}} when is_binary(Arg1) ->
         Arg1;
       #{call:=#{function:="0x"++FunID,args:=CArgs}} ->
         FunHex=hex:decode(FunID),
         lists:foldl(fun encode_arg/2, <<FunHex:4/binary>>, CArgs);
       #{call:=#{function:=FunNameID,args:=CArgs}} when is_list(FunNameID) ->
         {ok,E}=ksha3:hash(256, list_to_binary(FunNameID)),
         <<X:4/binary,_/binary>> = E,
         lists:foldl(fun encode_arg/2, <<X:4/binary>>, CArgs);
       _ ->
         <<>>
     end,


  SLoad=fun(Addr, IKey, _Ex0=#{get_addr:=GAFun}) ->
            io:format("=== sLoad key 0x~s:~p~n",[hex:encode(binary:encode_unsigned(Addr)),IKey]),
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(
              if Addr == To ->
                   case maps:is_key(BKey,State) of
                     true ->
                       maps:get(BKey, State, <<0>>);
                     false ->
                       GAFun({storage,binary:encode_unsigned(Addr),BKey})
                   end;
                 true ->
                   GAFun({storage,binary:encode_unsigned(Addr),BKey})
              end
             )
        end,
  Functions=#{
              16#AFFFFFFFFF000000 => fun(_) ->
                                         MT=maps:get(mean_time,Opaque,0),
                                         Ent=case maps:get(entropy,Opaque,<<>>) of
                                               Ent1 when is_binary(Ent1) ->
                                                 Ent1;
                                               _ ->
                                                 <<>>
                                             end,
                                         {1,<<MT:256/big,Ent/binary>>}
                                     end,
              16#AFFFFFFFFF000001 => fun(Bin) ->
                                         {1,list_to_binary(
                                              lists:reverse(
                                                binary_to_list(Bin)
                                               )
                                             )}
                                     end
            },

  FinFun = fun(_,_,#{data:=#{address:=Addr}, storage:=Stor, extra:=Xtra} = FinState) ->
               NewS=maps:merge(
                      maps:get({Addr, state}, Xtra, #{}),
                      Stor
                     ),
               FinState#{extra=>Xtra#{{Addr, state} => NewS}}
           end,

  GetCodeFun = fun(Addr,Ex0) ->
                   io:format(".: Get code for  ~p~n",[Addr]),
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=GetFun({addr,binary:encode_unsigned(Addr),code}),
                       {ok, GotCode, maps:put({Addr,code},GotCode,Ex0)}
                   end
               end,
  GetBalFun = fun(Addr,Ex0) ->
                  case maps:is_key({Addr,value},Ex0) of
                    true ->
                      maps:get({Addr,value},Ex0);
                    false ->
                      0
                  end
              end,
  BeforeCall = fun(CallKind,CFrom,_Code,_Gas,
                   #{address:=CAddr, value:=V}=CallArgs,
                   #{global_acc:=GAcc}=Xtra) ->
                   io:format("EVMCall from ~p ~p: ~p~n",[CFrom,CallKind,CallArgs]),
                   ?LOG_INFO("EVMCall from ~p ~p: ~p~n",[CFrom,CallKind,CallArgs]),
                   if V > 0 ->
                        TX=msgpack:pack(#{
                                          "k"=>tx:encode_kind(2,generic),
                                          "to"=>binary:encode_unsigned(CAddr),
                                          "p"=>[[tx:encode_purpose(transfer),<<"SK">>,V]]
                                         }),
                        {TxID,CTX}=generate_block_process:complete_tx(TX,
                                                               binary:encode_unsigned(CFrom),
                                                               GAcc),
                        SCTX=CTX#{sigverify=>#{valid=>1},norun=>1},
                        NewGAcc=generate_block_process:try_process([{TxID,SCTX}], GAcc),
                        io:format(">><< LAST ~p~n",[maps:get(last,NewGAcc)]),
                        case maps:get(last,NewGAcc) of
                          failed ->
                            throw({cancel_call,insufficient_fund});
                          ok ->
                            ok
                        end,
                        Xtra#{global_acc=>NewGAcc};
                      true ->
                        Xtra
                   end
               end,

  CreateFun = fun(Value1, Code1, #{aalloc:=AAlloc}=Ex0) ->
                  %io:format("Ex0 ~p~n",[Ex0]),
                  {ok, Addr0, AAlloc1}=generate_block_process:aalloc(AAlloc),
                  %io:format("Address ~p~n",[Addr0]),
                  Addr=binary:decode_unsigned(Addr0),
                  Ex1=Ex0#{aalloc=>AAlloc1},
                  %io:format("Ex1 ~p~n",[Ex1]),
                  Deploy=eevm:eval(Code1,#{},#{
                                               gas=>100000,
                                               extra=>Ex1,
                                               sload=>SLoad,
                                               finfun=>FinFun,
                                               get=>#{
                                                      code => GetCodeFun,
                                                      balance => GetBalFun
                                                     },
                                               data=>#{
                                                       address=>Addr,
                                                       callvalue=>Value,
                                                       caller=>binary:decode_unsigned(From),
                                                       gasprice=>1,
                                                       origin=>binary:decode_unsigned(From)
                                                      },
                                               embedded_code => Functions,
                                               cb_beforecall => BeforeCall,
                                               logger=>fun logger/4,
                                               trace=>whereis(eevm_tracer)
                                              }),
                  {done,{return,RX},#{storage:=StRet,extra:=Ex2}}=Deploy,
                  %io:format("Ex2 ~p~n",[Ex2]),

                  St2=maps:merge(
                        maps:get({Addr,state},Ex2,#{}),
                        StRet),
                  Ex3=maps:merge(Ex2,
                                 #{
                                   {Addr,state} => St2,
                                   {Addr,code} => RX,
                                   {Addr,value} => Value1
                                  }
                                ),
                  %io:format("Ex3 ~p~n",[Ex3]),
                  Ex4=maps:put(created,[Addr|maps:get(created,Ex3,[])],Ex3),

                  {#{ address => Addr },Ex4}
              end,

  Result = eevm:eval(Code,
                 #{},
                 #{
                   gas=>GasLimit,
                   sload=>SLoad,
                   extra=>Opaque,
                   get=>#{
                          code => GetCodeFun,
                          balance => GetBalFun
                         },
                   create => CreateFun,
                   finfun=>FinFun,
                   data=>#{
                           address=>binary:decode_unsigned(To),
                           callvalue=>Value,
                           caller=>binary:decode_unsigned(From),
                           gasprice=>1,
                           origin=>binary:decode_unsigned(From)
                          },
                   embedded_code => Functions,
                   cb_beforecall => BeforeCall,
                   cd=>CD,
                   logger=>fun logger/4,
                   trace=>whereis(eevm_tracer)
                  }),

  io:format("Call ~p -> {~p,~p,...}~n",[CD, element(1,Result),element(2,Result)]),
  case Result of
    {done, {return,RetVal}, RetState} ->
      returndata(RetState,#{"return"=>RetVal});
    {done, 'stop', RetState} ->
      returndata(RetState,#{});
    {done, 'eof', RetState} ->
      returndata(RetState,#{});
    {done, 'invalid', _} ->
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>0,
             "txs"=>[]}, Opaque};
    {done, {revert, Revert}, #{ gas:=GasLeft}} ->
      Log1=[([evm,revert,Revert])|PreLog],
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>GasLeft,
             "txs"=>[]}, Opaque#{"revert"=>Revert, log=>Log1}};
    {error, nogas, #{storage:=NewStorage}} ->
      io:format("St ~w keys~n",[maps:size(NewStorage)]),
      io:format("St ~p~n",[(NewStorage)]),
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.


logger(Message,LArgs0,#{log:=PreLog}=Xtra,#{data:=#{address:=A,caller:=O}}=_EEvmState) ->
  LArgs=[binary:encode_unsigned(I) || I <- LArgs0],
  ?LOG_INFO("EVM log ~p ~p",[Message,LArgs]),
  io:format("==>> EVM log ~p ~p~n",[Message,LArgs]),
  maps:put(log,[([evm,binary:encode_unsigned(A),binary:encode_unsigned(O),Message,LArgs])|PreLog],Xtra).

call(#{state:=State,code:=Code}=_Ledger,Method,Args) ->
  SLoad=fun(IKey) ->
            %io:format("Load key ~p~n",[IKey]),
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(maps:get(BKey, State, <<0>>))
        end,
  CD=case Method of
       "0x"++FunID ->
         FunHex=hex:decode(FunID),
         lists:foldl(fun encode_arg/2, <<FunHex:4/binary>>, Args);
       FunNameID when is_list(FunNameID) ->
         {ok,E}=ksha3:hash(256, list_to_binary(FunNameID)),
         <<X:4/binary,_/binary>> = E,
         lists:foldl(fun encode_arg/2, <<X:4/binary>>, Args)
     end,

  Result = eevm:eval(Code,
                     #{},
                     #{
                       gas=>20000,
                       sload=>SLoad,
                       value=>0,
                       cd=>CD,
                       caller=><<0>>,
                       logger=>fun logger/4,
                       trace=>whereis(eevm_tracer)
                      }),
  case Result of
    {done, {return,RetVal}, _} ->
      {ok, RetVal};
    {done, 'stop', _} ->
      {ok, stop};
    {done, 'invalid', _} ->
      {ok, invalid};
    {done, {revert, Msg}, _} ->
      {ok, Msg};
    {error, nogas, _} ->
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.

transform_extra_created(#{created:=C}=Extra) ->
  M1=lists:foldl(
       fun(Addr, ExtraAcc) ->
           %io:format("Created addr ~p~n",[Addr]),
           {Acc1, ToDel}=maps:fold(
           fun
             ({Addr1, state}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put(state,convert_storage(Value),IAcc),
               [K|IToDel]
              };
            ({Addr1, value}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put_cur(<<"SK">>,Value,IAcc),
               [K|IToDel]
              };
             ({Addr1, code}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
              {
               mbal:put(vm,<<"evm">>,
                        mbal:put(code,Value,IAcc)
                       ),
               [K|IToDel]
              };
             (_K,_V,A) ->
              A
                           end, {mbal:new(),[]}, ExtraAcc),
           maps:put(binary:encode_unsigned(Addr), Acc1,
                    maps:without(ToDel,ExtraAcc)
                   )
       end, Extra, C),
  M1#{created => [ binary:encode_unsigned(X) || X<-C ]};

transform_extra_created(Extra) ->
  Extra.

transform_extra_changed(#{changed:=C}=Extra) ->
  {Changed,ToRemove}=lists:foldl(fun(Addr,{Acc,Remove}) ->
                             case maps:is_key({Addr,state},Extra) of
                               true ->
                                 {
                                  [{{binary:encode_unsigned(Addr),mergestate},
                                    convert_storage(maps:get({Addr,state},Extra))}|Acc],
                                  [{Addr,state}|Remove]
                                 };
                               false ->
                                 {Acc,Remove}
                             end
                         end, {[],[]}, C),
  maps:put(changed, Changed,
           maps:without(ToRemove,Extra)
          );

transform_extra_changed(Extra) ->
  Extra.

transform_extra(Extra) ->
  %io:format("Extra ~p~n",[Extra]),
  T1=transform_extra_created(Extra),
  T2=transform_extra_changed(T1),
  T2.

returndata(#{ gas:=GasLeft, storage:=NewStorage, extra:=Extra },Append) ->
  {ok,
   maps:merge(
     #{null=>"exec",
       "storage"=>convert_storage(NewStorage),
       "gas"=>GasLeft,
       "txs"=>[]},
     Append),
   maps:merge(Append,transform_extra(Extra))}.

getters() ->
  [].

get(_,_,_Ledger) ->
  throw("unknown method").

