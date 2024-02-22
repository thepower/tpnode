-module(tpnode_evmrun).
-export([evm_run/4,decode_json_args/1]).

decode_json_args(Args) ->
  lists:map(
    fun(<<"0x",B/binary>>) ->
        hex:decode(B);
       (List) when is_list(List) ->
        decode_json_args(List);
       (Any) ->
        Any
    end, Args).

decode_res(_,address,V) ->
  hex:encodex(V);
decode_res(_,bytes,V) ->
  hex:encodex(V);
decode_res(_,bytes32,V) ->
  hex:encodex(V);
decode_res(_,bytes4,V) ->
  hex:encodex(V);
decode_res(_,uint256,V) ->
  if(V>72057594037927936) ->
      integer_to_binary(V);
    true ->
      V
  end;
decode_res(_,_,V) ->
  V.

code(Addr, H) when is_integer(Addr) ->
  code(binary:encode_unsigned(Addr), H);

code(Addr, undefined) ->
  case mledger:get_kpv(Addr,code,[]) of
    {ok, Bin} -> Bin;
    undefined ->
      undefined
  end;

code(Addr, Height) ->
  case mledger:get_kpvs_height(Addr,code,[],Height) of
    [{code,_,Bin}] -> Bin;
    [] -> <<>>
  end.

sload(Addr,Key,undefined) ->
  case mledger:get_kpv(Addr, state, Key) of
    {ok,Bin} -> Bin;
    undefined -> <<>>
  end;

sload(Addr,Key,Height) ->
  case mledger:get_kpvs_height(Addr,state,Key,Height) of
    [{state,Key,Bin}] -> Bin;
    [] -> <<>>
  end.

evm_run(Address, Fun, Args, Ed) ->
  try
    BlockHeight=maps:get(block_height,Ed,undefined),
    Code=code(Address,BlockHeight),
    if is_binary(Code) -> ok;
       true -> throw('no_code')
    end,
    Gas0=maps:get(gas,Ed,100000000),
    Res=run(Address, Code, Ed#{call => {Fun, Args}, gas=>Gas0}),

  FmtStack=fun(St) ->
               [ hex:encodex(binary:encode_unsigned(X)) || X<-St]
           end,

  FmtLog=fun(Logs) ->
             lists:foldl(
               fun(E,A) ->
                   [E|A]
               end,[], Logs)
         end,

  case Res of
    {done, {return,RetVal}, #{stack:=St, extra:=#{log:=Log}, gas:=Gas1}=_EVMState} ->
      Decoded=case binary:match(Fun,<<"returns">>) of
                nomatch -> #{};
                _ ->
                  case contract_evm_abi:parse_signature(Fun) of
                    {ok,{{function,_},_Sig, undefined}} -> #{}; %not it's impossible?
                    {ok,{{function,_},_Sig, RetABI}} when is_list(RetABI) ->
                      try
                        D=contract_evm_abi:decode_abi(RetVal,RetABI,[],fun decode_res/3),
                        #{decode => case D of
                                      [{_,[{<<>>,_}|_]}] -> contract_evm_abi:unwrap(D);
                                      [{_,[{_,_}|_]}] -> D;
                                      [{<<>>,_}|_] -> contract_evm_abi:unwrap(D);
                                      _ -> D
                                    end
                         }
                      catch _Ec:_Ee:S ->
                              logger:error("evmrun decode error: ~p:~p @ ~p",[_Ec,_Ee,S]),
                              #{decode_err => list_to_binary([io_lib:format("~p:~1000p, see logs for detail",[_Ec,_Ee])])
                               }
                      end
                  end
              end,
      maps:merge(Decoded,
                 #{result => return,
                   ok => true,
                   bin => RetVal,
                   gas_used => Gas0-Gas1,
                   log => FmtLog(Log),
                   stack => FmtStack(St)
                  }
                );
    {done, 'stop',  #{stack:=St, gas:=Gas1}} ->
      %{stop, undefined, FmtStack(St)};
      #{
        result => stop,
        ok => true,
        gas_used => Gas0-Gas1,
        stack => FmtStack(St)
       };
    {done, 'eof', #{stack:=St, gas:=Gas1}} ->
      %{eof, undefined, FmtStack(St)};
      #{
        result => eof,
        ok => true,
        gas_used => Gas0-Gas1,
        stack => FmtStack(St)
       };
    {done, 'invalid',  #{stack:=St}} ->
      #{ result => invalid,
         stack => FmtStack(St)
       };
    {done, {revert, <<8,195,121,160,Data/binary>> = Bin},  #{stack:=St, gas:=Gas1}} ->
      #{ result => revert,
         bin => Bin,
         ok => true,
         gas_used => Gas0-Gas1,
         signature => <<"Error(string)">>,
         decode => contract_evm_abi:unwrap(contract_evm_abi:decode_abi(Data,[{<<"Error">>,string}])),
         stack => FmtStack(St)
       };
    {done, {revert, <<78,72,123,113,Data/binary>> =Bin},  #{stack:=St, gas:=Gas1}} ->
      #{ result => revert,
         bin => Bin,
         ok => true,
         gas_used => Gas0-Gas1,
         signature => <<"Panic(uint256)">>,
         decode => contract_evm_abi:unwrap(contract_evm_abi:decode_abi(Data,[{<<"Panic">>,uint256}])),
         stack => FmtStack(St)
       };
    {done, {revert, Data},  #{stack:=St, gas:=Gas1}} ->
      #{ result => revert,
         bin => Data,
         gas_used => Gas0-Gas1,
         ok => true,
         stack => FmtStack(St)
       };
    {error, Desc} ->
      #{ result => error,
         error => Desc
       };
    {error, nogas, #{stack:=St}} ->
      #{ result => error,
         error => nogas,
         gas_used => Gas0,
         stack => FmtStack(St)
       };
    {error, {jump_to,_}, #{stack:=St}} ->
      #{ result => error,
         error => bad_jump,
         stack => FmtStack(St)
       };
    {error, {bad_instruction,I}, #{stack:=St}} ->
      #{ result => error,
         error => bad_instruction,
         data => list_to_binary([io_lib:format("~p",[I])]),
         stack => FmtStack(St)
       }
  end
  catch throw:no_code ->
          #{
            result => error,
            error => no_code
           }
  end.


logger(Message,LArgs0,#{log:=PreLog}=Xtra,#{data:=#{address:=A,caller:=O}}=_EEvmState) ->
  LArgs=[binary:encode_unsigned(I) || I <- LArgs0],
  %?LOG_INFO("EVM log ~p ~p",[Message,LArgs]),
  %io:format("==>> EVM log ~p ~p~n",[Message,LArgs]),
  maps:put(log,[([evm,binary:encode_unsigned(A),binary:encode_unsigned(O),Message,LArgs])|PreLog],Xtra).

run(Address, Code, Data) ->
  BI=fun
       (chainid, #{stack:=Stack}=BIState) ->
         BIState#{stack=>[16#c0de00000000|Stack]};
       (number,#{stack:=BIStack}=BIState) ->
         BIState#{stack=>[10+1|BIStack]};
       (timestamp,#{stack:=BIStack}=BIState) ->
         MT=os:system_time(millisecond),
         BIState#{stack=>[MT|BIStack]};
       (BIInstr,BIState) ->
         logger:error("Bad instruction ~p~n",[BIInstr]),
         {error,{bad_instruction,BIInstr},BIState}
     end,

  BlockHeight=maps:get(block_height,Data,undefined),

  SLoad=fun(Addr, IKey, _Ex0) ->
            Res=sload(
                  binary:encode_unsigned(Addr),
                  binary:encode_unsigned(IKey),
                  BlockHeight
                 ),
            binary:decode_unsigned(Res)
        end,
  State0 = #{
             sload=>SLoad,
             gas=>maps:get(gas,Data,100000000),
             data=>#{
                     address=>binary:decode_unsigned(Address),
                     caller =>binary:decode_unsigned(
                                maps:get(caller, Data, Address)),
                     origin  =>binary:decode_unsigned(
                                 maps:get(caller, Data, Address))
                    }
            },

  FinFun = fun(_,_,#{data:=#{address:=Addr}, storage:=Stor, extra:=Xtra} = FinState) ->
               NewS=maps:merge(
                      maps:get({Addr, stor}, Xtra, #{}),
                      Stor
                     ),
               FinState#{extra=>Xtra#{{Addr, stor} => NewS}}
           end,

  GetCodeFun = fun(Addr,Ex0) ->
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=code((Addr),BlockHeight),
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
                   %io:format("EVMCall from ~p ~p: ~p~n",[CFrom,CallKind,CallArgs]),
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
                        %io:format(">><< LAST ~p~n",[maps:get(last,NewGAcc)]),
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

  CreateFun = fun(Value1, Code1, #{la:=Lst}=Ex0) ->
                  Addr0=naddress:construct_public(16#ffff,16#0,Lst+1),
                  %io:format("Address ~p~n",[Addr0]),
                  Addr=binary:decode_unsigned(Addr0),
                  Ex1=Ex0#{la=>Lst+1},
                  %io:format("Ex1 ~p~n",[Ex1]),
                  Deploy=eevm:eval(Code1,#{},#{
                                               gas=>100000,
                                               data=>#{
                                                       address=>Addr,
                                                       callvalue=>Value1,
                                                       caller=>binary:decode_unsigned(Address),
                                                       gasprice=>1,
                                                       origin=>binary:decode_unsigned(Address)
                                                      },
                                               extra=>Ex1,
                                               sload=>SLoad,
                                               bad_instruction=>BI,
                                               finfun=>FinFun,
                                               get=>#{
                                                      code => GetCodeFun,
                                                      balance => GetBalFun
                                                     },
                                               cb_beforecall => BeforeCall,
                                               logger=>fun logger/4,
                                               trace=>whereis(eevm_tracer)
                                              }),
                  {done,{return,RX},#{storage:=StRet,extra:=Ex2}}=Deploy,
                  %io:format("Ex2 ~p~n",[Ex2]),

                  St2=maps:merge(
                        maps:get({Addr,stor},Ex2,#{}),
                        StRet),
                  Ex3=maps:merge(Ex2,
                                 #{
                                   {Addr,stor} => St2,
                                   {Addr,code} => RX,
                                   {Addr,value} => Value1
                                  }
                                ),
                  %io:format("Ex3 ~p~n",[Ex3]),
                  Ex4=maps:put(created,[Addr|maps:get(created,Ex3,[])],Ex3),

                  {#{ address => Addr },Ex4}
              end,

  CallData = case maps:get(call, Data, undefined) of
               {<<"0x0">>,[BinData]} when is_binary(BinData) andalso size(BinData)>=4 ->
                 BinData;
               {Fun, Arg} ->
                 {ok,{{function,_},FABI,_}=S} = contract_evm_abi:parse_signature(Fun),
                 if(length(FABI)==length(Arg)) -> ok;
                   true -> throw("count of arguments does not match with signature")
                 end,
                 BArgs=contract_evm_abi:encode_abi(Arg,FABI),
                 X=contract_evm_abi:sig32(contract_evm_abi:mk_sig(S)),
                 <<X:32/big,BArgs/binary>>;
               undefined ->
                 <<>>
             end,

  
  Ex1=#{
        la=>0,
        log=>[],
        global_acc=>#{}
       },
  eevm:eval(Code,
            #{},
            State0#{cd=>CallData,
                    extra=>Ex1,
                    sload=>SLoad,
                    finfun=>FinFun,
                    bad_instruction=>BI,
                    get=>#{
                           code => GetCodeFun,
                           balance => GetBalFun
                          },
                    cb_beforecall => BeforeCall,
                    logger=>fun logger/4,
                    create => CreateFun,
                    trace=>whereis(eevm_tracer)
                   }).

