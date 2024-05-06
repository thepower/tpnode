-module(contract_evm).
-include("include/tplog.hrl").

-export([deploy/5, handle_tx/5, getters/0, get/3, info/0, call/3, call/4, call_i/4]).
-export([encode_tx/2,decode_tx/2]).
-export([tx_abi/0]).
-export([enc_settings1/1]).
-export([callcd/3]).
-export([ask_ERC165/3]).
-export([ask_ERC165/2]).
-export([transform_extra/1]).
-export([ask_if_sponsor/1, ask_if_wants_to_pay/4,ask_if_wants_to_pay/3]).
-export([preencode_tx/2]).

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
  GetCodeFun = fun(Addr,Ex0) ->
                   %io:format(".: Get code for  ~p~n",[Addr]),
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=GetFun({code,binary:encode_unsigned(Addr)}),
                       if is_binary(GotCode) ->
                            {ok, GotCode, maps:put({Addr,code},GotCode,Ex0)};
                          GotCode==undefined ->
                            {ok, <<>>, maps:put({Addr,code},<<>>,Ex0)}
                       end
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
  ACD=try
        case Tx of
          #{call:=#{function:="ABI",args:=CArgs}} ->
            abi_encode_simple(CArgs);
          #{call:=#{function:="0x0",args:=[Bin]}} when is_binary(Bin) ->
            Bin;
          #{call:=#{function:=FunNameID,args:=CArgs}} when is_list(FunNameID) ->
            BinFun=list_to_binary(FunNameID),
            {ok,{{function,_},FABI,_}} = contract_evm_abi:parse_signature(BinFun),
            true=(length(FABI)==length(CArgs)),
            contract_evm_abi:encode_abi(CArgs,FABI);
          _ ->
            <<>>
        end
      catch Ec:Ee:S ->
              ?LOG_ERROR("ABI encode error: ~p:~p @~p",[Ec,Ee,hd(S)]),
              <<>>
      end,

  BI=fun
       (chainid, #{stack:=Stack}=BIState) ->
         BIState#{stack=>[16#c0de00000000|Stack]};
       (number,#{stack:=BIStack}=BIState) ->
         #{height:=PHei} = GetFun(parent_block),
         BIState#{stack=>[PHei+1|BIStack]};
       (timestamp,#{stack:=BIStack}=BIState) ->
         MT=maps:get(mean_time,Opaque,0),
         BIState#{stack=>[MT|BIStack]};
       (BIInstr,BIState) ->
         logger:error("Bad instruction ~p~n",[BIInstr]),
         {error,{bad_instruction,BIInstr},BIState}
     end,

  EvalRes = eevm:eval(<<Code/binary,ACD/binary>>,
                      State,
                      #{
                        extra=>Opaque#{getfun=>GetFun, tx=>Tx},
                        logger=>fun logger/4,
                        gas=>GasLimit,
                        bad_instruction=>BI,
                        get=>#{
                               code => GetCodeFun,
                               balance => GetBalFun
                              },
                        data=>#{
                                address=>binary:decode_unsigned(maps:get(address,Tx,From)),
                                callvalue=>Value,
                                caller=>binary:decode_unsigned(From),
                                gasprice=>1,
                                origin=>binary:decode_unsigned(From)
                               },
                        embedded_code => embedded_functions(),
                        trace=>whereis(eevm_tracer)
                       }),
  %io:format("EvalRes ~p~n",[EvalRes]),
  case EvalRes of
    {done, {return,NewCode}, #{ gas:=GasLeft, storage:=NewStorage }} ->
      %io:format("Deploy -> OK~n",[]),
      {ok, #{null=>"exec",
             "code"=>NewCode,
             "state"=>convert_storage(NewStorage),
             "gas"=>GasLeft,
             "txs"=>[]
            }, Opaque};
    {done, 'stop', _} ->
      %io:format("Deploy -> stop~n",[]),
      {error, deploy_stop};
    {done, 'invalid', _} ->
      %io:format("Deploy -> invalid~n",[]),
      {error, deploy_invalid};
    {done, {revert, _}, _} ->
      %io:format("Deploy -> revert~n",[]),
      {error, deploy_revert};
    {error, nogas, _} ->
      %io:format("Deploy -> nogas~n",[]),
      {error, nogas};
    {error, {jump_to,_}, _} ->
      %io:format("Deploy -> bad_jump~n",[]),
      {error, bad_jump};
    {error, {bad_instruction,_}, _} ->
      %io:format("Deploy -> bad_instruction~n",[]),
      {error, bad_instruction}
%
% {done, [stop|invalid|{revert,Err}|{return,Data}], State1}
% {error,[nogas|{jump_to,Dst}|{bad_instruction,Instr}], State1}


    %{done,{revert,Data},#{gas:=G}=S2};
  end.

abi_encode_simple(Elements) ->
  HdLen=length(Elements)*32,
  {H,B,_}=lists:foldl(
            fun(E, {Hdr,Body,BOff}) when is_integer(E) ->
                {<<Hdr/binary,E:256/big>>,
                 Body,
                 BOff};
               (<<E:64/big>>, {Hdr,Body,BOff}) -> %the power address
                {<<Hdr/binary,E:256/big>>,
                 Body,
                 BOff};
               (<<E:256/big>>, {Hdr,Body,BOff}) ->
                {<<Hdr/binary,E:256/big>>,
                 Body,
                 BOff};
               (E, {Hdr,Body,BOff}) when is_list(E) ->
                EncStr=encode_str(list_to_binary(E)),
                {
                 <<Hdr/binary,BOff:256/big>>,
                 <<Body/binary,EncStr/binary>>,
                 BOff+size(EncStr)
                }
            end, {<<>>, <<>>, HdLen}, Elements),
  HdLen=size(H),
  <<H/binary,B/binary>>.

encode_str(Bin) ->
  Pad = case (size(Bin) rem 32) of
          0 -> 0;
          N -> 32 - N
        end*8,
  <<(size(Bin)):256/big,Bin/binary,0:Pad/big>>.

handle_tx(#{to:=To,from:=From,txext:=#{"code":=Code,"vm":= "evm"}}=Tx,
          Ledger, GasLimit, GetFun, Opaque) when To==From ->
  handle_tx_int(Tx, Ledger#{code=>Code}, GasLimit, GetFun, maps:merge(#{log=>[]},Opaque));

handle_tx(Tx, Ledger, GasLimit, GetFun, Opaque) ->
  handle_tx_int(Tx, Ledger, GasLimit, GetFun, maps:merge(#{log=>[]},Opaque)).

handle_tx_int(#{to:=To,from:=From}=Tx, #{code:=Code}=Ledger,
              GasLimit, GetFun, #{log:=PreLog}=Opaque) ->
  State=case maps:get(state,Ledger,#{}) of
          BinState when is_binary(BinState) ->
            {ok,MapState}=msgpack:unpack(BinState),
            MapState;
          MapState when is_map(MapState) ->
            MapState
        end,

  Value=case Tx of
          #{amount := A, cur := <<"SK">>} ->
            A;
          #{payload:=_} ->
            case tx:get_payload(Tx, transfer) of
              undefined ->
                0;
              #{amount:=A,cur:= <<"SK">>} ->
                A;
              _ ->
                0
            end
        end,

  CD=case Tx of
       #{call:=#{function:="0x0",args:=[Arg1]}} when is_binary(Arg1) ->
         Arg1;
       #{call:=#{function:="0x"++FunID,args:=CArgs}} ->
         FunHex=hex:decode(FunID),
         %lists:foldl(fun encode_arg/2, <<FunHex:4/binary>>, CArgs);
         BArgs=abi_encode_simple(CArgs),
         <<FunHex:4/binary,BArgs/binary>>;
       #{call:=#{function:=FunNameID,args:=CArgs}} when is_list(FunNameID) ->
         BinFun=list_to_binary(FunNameID),
         {ok,E}=ksha3:hash(256, BinFun),
         <<X:4/binary,_/binary>> = E,
         try
           {ok,{{function,_},FABI,_}} = contract_evm_abi:parse_signature(BinFun),
           true=(length(FABI)==length(CArgs)),
           BArgs=contract_evm_abi:encode_abi(CArgs,FABI),
           <<X:4/binary,BArgs/binary>>
         catch EEc:EEe ->
           ?LOG_ERROR("abiencode error: ~p:~p function ~p args ~p",[EEc,EEe,FunNameID,CArgs]),
           BArgs2=abi_encode_simple(CArgs),
           <<X:4/binary,BArgs2/binary>>
         end;
       _ ->
         <<>>
     end,

  SLoad=fun(Addr, IKey, Ex0=#{get_addr:=GAFun}) ->
            %io:format("=== sLoad key 0x~s:~p~n",[hex:encode(binary:encode_unsigned(Addr)),IKey]),
            case maps:get(IKey,maps:get({Addr,stor},Ex0,#{}),undefined) of
              IRes when is_integer(IRes) ->
                IRes;
              undefined ->
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
            end
        end,

  FinFun = fun(_,_,#{data:=#{address:=Addr}, storage:=Stor, extra:=Xtra} = FinState) ->
               NewS=maps:merge(
                      maps:get({Addr, stor}, Xtra, #{}),
                      Stor
                     ),
               FinState#{extra=>Xtra#{{Addr, stor} => NewS}}
           end,

  GetCodeFun = fun(Addr,Ex0) ->
                   logger:debug("Load code for ~p",[Addr]),
                   case maps:is_key({Addr,code},Ex0) of
                     true ->
                       maps:get({Addr,code},Ex0,<<>>);
                     false ->
                       GotCode=GetFun({code,binary:encode_unsigned(Addr)}),
                       if is_binary(GotCode) ->
                            {ok, GotCode, maps:put({Addr,code},GotCode,Ex0)};
                          GotCode==undefined ->
                            {ok, <<>>, maps:put({Addr,code},<<>>,Ex0)}
                       end
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
  BI=fun
       (chainid, #{stack:=Stack}=BIState) ->
         BIState#{stack=>[16#c0de00000000|Stack]};
       (number,#{stack:=BIStack}=BIState) ->
         #{height:=PHei} = GetFun(parent_block),
         BIState#{stack=>[PHei+1|BIStack]};
       (timestamp,#{stack:=BIStack}=BIState) ->
         MT=maps:get(mean_time,Opaque,0),
         BIState#{stack=>[MT|BIStack]};
       (BIInstr,BIState) ->
         logger:error("Bad instruction ~p~n",[BIInstr]),
         {error,{bad_instruction,BIInstr},BIState}
     end,

  EmbeddedCode=embedded_functions(),
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
                                               bad_instruction=>BI,
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
                                               embedded_code => EmbeddedCode,
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

  Result = eevm:eval(Code,
                 #{},
                 #{
                   gas=>GasLimit,
                   sload=>SLoad,
                   extra=>Opaque#{getfun=>GetFun, tx=>Tx},
                   bad_instruction=>BI,
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
                   embedded_code => EmbeddedCode,
                   cb_beforecall => BeforeCall,
                   cd=>CD,
                   logger=>fun logger/4,
                   trace=>whereis(eevm_tracer)
                  }),

  ?LOG_INFO("Call (~s) -> {~p~n,~p~n,...}~n",[hex:encode(CD), element(1,Result),element(2,Result)]),
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
      Log1=[[<<"evm:revert">>,To,From,Revert]|PreLog],
      {ok, #{null=>"exec",
             "state"=>unchanged,
             "gas"=>GasLeft,
             "txs"=>[]}, Opaque#{"revert"=>Revert, log=>Log1}};
    {error, nogas, #{storage:=_NewStorage}} ->
      {error, nogas, 0};
    {error, {jump_to,_}, _} ->
      {error, bad_jump, 0};
    {error, {bad_instruction,_}, _} ->
      {error, bad_instruction, 0}
  end.


logger(Message,LArgs0,#{log:=PreLog}=Xtra,#{data:=#{address:=A,caller:=O}}=_EEvmState) ->
  LArgs=[binary:encode_unsigned(I) || I <- LArgs0],
  ?LOG_INFO("EVM log ~p ~p",[Message,LArgs]),
  %io:format("==>> EVM log ~p ~p~n",[Message,LArgs]),
  maps:put(log,[([evm,binary:encode_unsigned(A),binary:encode_unsigned(O),Message,LArgs])|PreLog],Xtra).

call(#{state:=_State,code:=_Code}=Ledger,Method,Args) ->
  ?LOG_ERROR("deprecated call"),
  call(<<1>>,#{<<1>>=>Ledger},Method,Args).

call(Address, LedgerMap, Method, Args) ->
  SLoad=fun(Addr, IKey, _) ->
            %io:format("=== sLoad key 0x~s:~p~n",[hex:encode(binary:encode_unsigned(Addr)),IKey]),
            L=maps:get(binary:encode_unsigned(Addr),LedgerMap,#{}),
            S=maps:get(state,L,#{}),
            binary:decode_unsigned(maps:get(binary:encode_unsigned(IKey),S,<<0>>))
        end,
  GetCode = fun(Addr,_) ->
                   L=maps:get(binary:encode_unsigned(Addr),LedgerMap,#{}),
                   maps:get(code,L,<<>>)
               end,
  call_i(Address, Method, Args, #{sload=>SLoad, getcode=>GetCode}).

call_i(Address, Method, Args, #{sload:=SLoad, getcode:=GetCode}=Opts) ->
  CD=case Method of
       "0x0" ->
         list_to_binary(Args);
       "0x"++FunID ->
         FunHex=hex:decode(FunID),
         BArgs=abi_encode_simple(Args),
         <<FunHex:4/binary,BArgs/binary>>;
       FunNameID when is_list(FunNameID) ->
         {ok,{{function,_},FABI,_}=S} = contract_evm_abi:parse_signature(FunNameID),
         if(length(FABI)==length(Args)) -> ok;
           true -> throw("amount of arguments does not match with signature")
         end,
         BArgs=contract_evm_abi:encode_abi(Args,FABI),
         X=contract_evm_abi:sig32(contract_evm_abi:mk_sig(S)),
         <<X:32/big,BArgs/binary>>
     end,

  Code=GetCode(binary:decode_unsigned(Address),#{}),
  Result = eevm:eval(Code,
                     #{},
                     #{
                       gas=>maps:get(gas,Opts,30000),
                       sload=>SLoad,
                       get=>#{ code => GetCode },
                       value=>0,
                       cd=>CD,
                       data=>#{
                                address=>binary:decode_unsigned(Address),
                                callvalue=>0,
                                caller=>0,
                                gasprice=>1,
                                origin=>0
                               },
                       logger=>fun logger/4,
                       trace=>whereis(eevm_tracer)
                      }),
  case Result of
    {done, {return,RetVal}, _X1} ->
      {ok, RetVal};
    {done, 'stop', _} ->
      {ok, stop};
    {done, 'invalid', _} ->
      {ok, invalid};
    {done, {revert, Msg}, _X1} ->
      {revert, Msg};
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
             ({Addr1, stor}=K,Value,{IAcc,IToDel}) when Addr==Addr1 ->
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
                             case maps:is_key({Addr,stor},Extra) of
                               true ->
                                 {
                                  [{{binary:encode_unsigned(Addr),mergestate},
                                    convert_storage(maps:get({Addr,stor},Extra))}|Acc],
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

tx_abi() ->
  [{<<"tx">>,
    {tuple,[{<<"kind">>,uint256},
            {<<"from">>,address},
            {<<"to">>,address},
            {<<"t">>,uint256},
            {<<"seq">>,uint256},
            {<<"call">>,
             {darray,{tuple,[{<<"func">>,string},
                            {<<"args">>,{darray,uint256}}]}}},
            {<<"payload">>,
             {darray,{tuple, [
                             {<<"purpose">>,uint256},
                             {<<"cur">>,string},
                             {<<"amount">>,uint256}
                            ]}}},
            {<<"signatures">>,
             {darray,{tuple,[{<<"raw">>,bytes},
                            {<<"timestamp">>,uint256},
                            {<<"pubkey">>,bytes},
                            {<<"rawkey">>,bytes},
                            {<<"signature">>,bytes}
                           ]}}}
           ]}
   }].

decode_tx(BinTx,_Opts) ->
  FABI=tx_abi(),
  Dec=contract_evm_abi:decode_abi(BinTx,FABI),
  case Dec of
    [{_,Proplist}] ->
      {Ver,K}=tx:decode_kind(proplists:get_value(<<"kind">>,Proplist)),
      From=proplists:get_value(<<"from">>,Proplist),
      To=proplists:get_value(<<"to">>,Proplist),
      T=proplists:get_value(<<"t">>,Proplist),
      Seq=proplists:get_value(<<"seq">>,Proplist),
      Call=proplists:get_value(<<"call">>,Proplist),
      Payload0=proplists:get_value(<<"payload">>,Proplist),
      Signatures0=proplists:get_value(<<"signatures">>,Proplist),

      Payload=lists:map(
                fun([{<<"purpose">>,Purp},{<<"cur">>,Token},{<<"amount">>,Am}]) ->
                    #{amount => Am, cur => Token, purpose => tx:decode_purpose(Purp)}
                end,Payload0),
      Signatures=lists:foldl(
                   fun(PL,S) ->
                       case proplists:get_value(<<"raw">>,PL) of
                         X when is_binary(X) ->
                           [X|S];
                         _ ->
                           S
                       end
                   end, [], Signatures0),
      T0=#{
           ver=>Ver,
           kind=>K,
           from=>From,
           to=>To,
           t=>T,
           seq=>Seq,
           payload=>Payload
          },

      T1=case Call of
           [[{<<"func">>,F},{<<"args">>,A}]] ->
             T0#{call=>#{function=>binary_to_list(F), args=>A}};
           _ ->
             T0
         end,

      %needs to be fixed
      TC=tx:construct_tx(T1),
      TC#{'sig' => Signatures};
    _ ->
      error
  end.



preencode_tx(#{kind:=Kind,ver:=Ver,from:=From,to:=To,t:=T,seq:=Seq,sig:=Sig,payload:=RPayload}=Tx,_Opts) ->
  K=tx:encode_kind(Ver,Kind),
  Call=case Tx of
         #{call:=#{function:=F, args:=A}} ->
           case lists:all(fun(E) -> is_integer(E) end,A) of
             true ->
               [[F,A]];
             false ->
               %% TODO: figure out what to do with args!!!! How to encode them in ABI
               [[F,[]]]
           end;
         _ ->
           []
       end,
  Payload=lists:map(
            fun(#{amount := Am, cur := Token, purpose := Purp}) ->
                [tx:encode_purpose(Purp),Token,Am]
            end,RPayload),
  Signatures=lists:foldl(
        fun(E,S) ->
            #{signature:=SigS,extra:=Xt}=bsig:unpacksig(E),
            PK=proplists:get_value(pubkey,Xt,<<>>),
            {_,RPK}=tpecdsa:cmp_pubkey(PK),
            [[
              E,
              proplists:get_value(timestamp,Xt,0),
              PK,
              RPK,
              SigS
             ]
             |S]
        end, [], Sig),
  %R=tx:verify(Tx,[nocheck_ledger]),
  %io:format("~p~n",[R]),
  %contract_evm_abi:decode_abi(Bin,FABI).
  {ok,[K, From, To, T, Seq, Call, Payload, Signatures]}.


encode_tx(#{kind:=_,ver:=_,from:=_,to:=_,t:=_,seq:=_,sig:=_,payload:=_}=Tx,Opts) ->
  {ok,Pre}=preencode_tx(Tx,Opts),
  FABI=tx_abi(),
  contract_evm_abi:encode_abi([Pre],FABI).


%extra=>Opaque#{GetFun,Tx},
embedded_functions() ->
  #{
    16#AFFFFFFFFF000000 =>
    fun(_,XAcc) ->
        MT=maps:get(mean_time,XAcc,0),
        Ent=case maps:get(entropy,XAcc,<<>>) of
              Ent1 when is_binary(Ent1) ->
                Ent1;
              _ ->
                <<>>
            end,
        {1,<<MT:256/big,Ent/binary>>,XAcc}
    end,
    16#AFFFFFFFFF000001 => %just for test
    fun(Bin,XAcc) ->
        {1,list_to_binary( lists:reverse( binary_to_list(Bin))),XAcc}
    end,
    16#AFFFFFFFFF000002 => %getTx()
    fun(_,#{tx:=Tx}=XAcc) ->
        RBin= encode_tx(Tx,[]),
        {1,RBin,XAcc}
    end,
    16#AFFFFFFFFF000003 => fun embedded_settings/2,
    16#AFFFFFFFFF000004 => fun embedded_blocks/2, %block service
    16#AFFFFFFFFF000005 => fun embedded_lstore/3, %lstore service
    16#AFFFFFFFFF000006 => fun embedded_chkey/3 %key service
   }.

embedded_blocks(<<1489993744:32/big,Bin/binary>>,#{getfun:=GetFun}=XAcc) -> %get_signatures(uint256 height)
  io:format("=== get_signatures: ~p~n",[Bin]),
  try
    [{<<"key">>,N}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,uint256}]),
    #{sign:=Signatures}=GetFun({get_block, N}),

    Data=lists:sort([ PubKey || #{beneficiary :=  PubKey } <- Signatures]),

    logger:notice("=== get_block: ~p",[Data]),
    RBin=contract_evm_abi:encode_abi([Data], [{<<>>, {darray,bytes}}]),
    {1,RBin,XAcc}
  catch Ec:Ee ->
          logger:info("decode_abi error: ~p:~p~n",[Ec,Ee]),
          {0, <<"badarg">>, XAcc}
  end;
embedded_blocks(<<Sig:32/big,_/binary>>,XAcc) ->
  ?LOG_NOTICE("Address ~p unknown sig: ~p~n",[16#AFFFFFFFFF000004,Sig]),
  {0, <<"badarg">>, XAcc}.


embedded_settings(<<3410561484:32/big,Bin/binary>>,#{getfun:=GetFun}=XAcc) -> %byPath(string[])
  try
    [{<<"key">>,Path}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,{darray,string}}]),
    SRes=GetFun({settings,Path}),
    RBin=enc_settings1(SRes),
    {1,RBin,XAcc}
  catch Ec:Ee ->
          logger:info("decode_abi error: ~p:~p~n",[Ec,Ee]),
          {0, <<"badarg">>, XAcc}
  end;
embedded_settings(<<3802961955:32/big,Bin/binary>>,#{getfun:=GetFun}=XAcc) ->% isNodeKnown(bytes)
  try
    [{<<"key">>,PubKey}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,bytes}]),
    true=is_binary(PubKey),
    Sets=settings:clean_meta(GetFun({settings,[]})),
    NC=chainsettings:nodechain(PubKey,Sets),
    RStr=case NC of
           false ->
             [0,0,<<>>];
           {NodeName,Chain} ->
             [1,Chain,NodeName]
         end,
    FABI=[{<<"known">>,uint8},
          {<<"chain">>,uint256},
          {<<"name">>,bytes}],
    RBin=contract_evm_abi:encode_abi(RStr, FABI),
    {1,RBin,XAcc}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
          {0, <<"badarg">>, XAcc}
  end;
embedded_settings(<<Sig:32/big,_/binary>>,XAcc) ->
  ?LOG_NOTICE("Address ~p unknown sig: ~p~n",[16#AFFFFFFFFF000003,Sig]),
  {0, <<"badsig">>, XAcc}.

embedded_chkey(<<16#218EBFA3:32/big,Bin/binary>>,
                #{data:=#{address:=AI}},
                #{global_acc:=GA=#{table:=Addresses}}=XAcc) ->% setKey(bytes)
  InABI=[{<<"key">>,bytes}],
  try
    [{<<"key">>,NewKey}]=contract_evm_abi:decode_abi(Bin,InABI),
    Addr=binary:encode_unsigned(AI),

    NewAddresses=maps:put(Addr,
                          mbal:put(pubkey, NewKey,
                                   case maps:is_key(Addr,Addresses) of
                                     false ->
                                       Load=maps:get(loadaddr, GA),
                                       Load({undefined, #{ver=>2, kind=>chkey, from=>Addr, keys=>[]}}, Addresses);
                                     true ->
                                       maps:get(Addr,Addresses)
                                   end
                                  ),
                          Addresses),

    {1,<<>>,XAcc#{global_acc=>GA#{table=>NewAddresses}}}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
          {0, <<"badarg">>, XAcc}
  end.

embedded_lstore(<<16#8D0FE062:32/big,Bin/binary>>,
                #{data:=#{address:=A}},
                #{getfun:=GetFun}=XAcc) ->% getByPath(bytes[])
  InABI=[{<<"key">>,{darray,bytes}}],
  try
    [{<<"key">>,Path}]=contract_evm_abi:decode_abi(Bin,InABI),
    
    SRes=try
           GetFun({lstore,binary:encode_unsigned(A),Path})
         catch Ec1:Ee1:S1 ->
                 ?LOG_ERROR("lstore error ~p:~p @ ~p",[Ec1,Ee1,S1]),
                 error
         end,
    
    RBin=enc_settings1(SRes),
    {1,RBin,XAcc}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
          {0, <<"badarg">>, XAcc}
  end;

embedded_lstore(<<2693574879:32/big,Bin/binary>>,
                #{data:=#{address:=_A}},
                #{getfun:=GetFun}=XAcc) ->% getByPath(address,bytes[])
  InABI=[{<<"address">>,address},{<<"key">>,{darray,bytes}}],
  try
    [{<<"address">>,Addr},{<<"key">>,Path}]=contract_evm_abi:decode_abi(Bin,InABI),

    SRes=try
           GetFun({lstore,Addr,Path})
         catch Ec1:Ee1:S1 ->
                 ?LOG_ERROR("lstore error ~p:~p @ ~p",[Ec1,Ee1,S1]),
                 error
         end,

    RBin=enc_settings1(SRes),
    {1,RBin,XAcc}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
          {0, <<"badarg">>, XAcc}
  end;

embedded_lstore(<<2956342894:32/big,Bin/binary>>,
                #{data:=#{address:=OwnerI}},
                #{global_acc:=GA=#{table:=Addresses}}=XAcc) ->% setByPath(bytes[],uint256,bytes)
  Owner=binary:encode_unsigned(OwnerI),
  InABI=[{<<"p">>,{darray,bytes}}, {<<"t">>,uint256}, {<<"v">>,bytes}],
  try
    hex:hexdump(Bin),
    io:format("Bin ~4000p~n",[Bin]),
    io:format("ABI ~p~n",[InABI]),
    [{<<"p">>,Path},{<<"t">>,Type},{<<"v">>,ValB}]=contract_evm_abi:decode_abi(Bin,InABI),
    Patch=case Type of
            1 -> [#{<<"p">>=>Path,<<"t">>=><<"set">>,<<"v">>=>ValB}];
            _ -> []
          end,
    Bal=maps:get(Owner, Addresses),
    Set1=mbal:get(lstore, Bal),
    Set2=settings:patch(Patch, Set1),
    NewBal=mbal:put(lstore, Set2, Bal),
    NewAddresses=maps:put(Owner, NewBal, Addresses),
    RBin= <<1:256/big>>,
    {1,RBin,XAcc#{global_acc=>GA#{table=>NewAddresses}}}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
          {0, <<"badarg">>, XAcc}
  end;

embedded_lstore(<<Sig:32/big,_/binary>>,_,XAcc) ->
  ?LOG_ERROR("Address ~p unknown sig: ~p~n",[16#AFFFFFFFFF000003,Sig]),
  {0, <<"badsig">>, XAcc}.



enc_settings1(SRes) ->
  OutABI=[{<<"datatype">>,uint256},
          {<<"res_bin">>,bytes},
          {<<"res_int">>,uint256},
          {<<"keys">>,{darray,{tuple,[{<<"datatype">>,uint256},
                                     {<<"res_bin">>,bytes}]}}}],
  EncSub=fun(Sub) ->
             [ if is_atom(A) -> [5, atom_to_binary(A)];
                  is_integer(A) -> [1, binary:encode_unsigned(A)];
                  is_binary(A) -> [2, A]
               end || A <-  Sub]
         end,
  RStr=case SRes of
         #{} = Mapa ->
           [3, <<>>, maps:size(Mapa), EncSub(maps:keys(Mapa))];
         I when is_integer(I) ->
           [1,<<>>,I,[]];
         B when is_binary(B) ->
           [2,B,size(B),[]];
         A when is_atom(A) ->
           [5,atom_to_binary(A,utf8),0,[]];
         L when is_list(L) ->
           [4,<<>>,length(L),EncSub(L)]
       end,
  contract_evm_abi:encode_abi([RStr], [{<<>>, {tuple, OutABI}}]).

ask_if_wants_to_pay(Code, Tx, Gas, From) ->
  Function= <<"wouldYouLikeToPayTx("
  "(uint256,address,address,uint256,uint256,"
  "(string,uint256[])[],"
  "(uint256,string,uint256)[],"
  "(bytes,uint256,bytes,bytes,bytes)[])"
  ")">>,
  try
    %{ok,{_,OutABI,_}}=contract_evm_abi:parse_signature(
    %                    "(string iWillPay,(uint256 purpose,string cur,uint256 amount)[] pay)"
    %                   ),
    InABI=[{<<>>,{tuple,[{<<>>,uint256},
                         {<<>>,address},
                         {<<>>,address},
                         {<<>>,uint256},
                         {<<>>,uint256},
                         {<<>>,{darray,{tuple,[{<<>>,string},{<<>>,{darray,uint256}}]}}},
                         {<<>>,{darray,{tuple,[{<<>>,uint256},{<<>>,string},{<<>>,uint256}]}}},
                         {<<>>,{darray,{tuple,[
                                              {<<>>,bytes},
                                              {<<>>,uint256},
                                              {<<>>,bytes},
                                              {<<>>,bytes},
                                              {<<>>,bytes}]}}}
                        ]}}],
    OutABI=[{<<"iWillPay">>,string},{<<"pay">>,{darray,{tuple,[{<<"purpose">>,uint256},{<<"cur">>,string},{<<"amount">>,uint256}]}}}],
    {ok,PTx}=preencode_tx(Tx,[]),

    CD=callcd(Function, [PTx], InABI),
    SLoad=fun(Addr, IKey, _Ex0) ->
            BKey=binary:encode_unsigned(IKey),
            case mledger:get_kpv(binary:encode_unsigned(Addr),state,BKey) of
              undefined -> 0;
              {ok,Bin} -> binary:decode_unsigned(Bin)
            end
        end,

    case eevm:eval(Code,#{},#{ gas=>Gas, extra=>#{}, cd=>CD, sload=>SLoad,
                               data=>#{
                                address=>binary:decode_unsigned(From),
                                callvalue=>0,
                                caller=>binary:decode_unsigned(From),
                                gasprice=>1,
                                origin=>binary:decode_unsigned(From)
                               }
                             }) of
      {done,{return,Ret},_} ->
        case contract_evm_abi:decode_abi(Ret,OutABI) of
          [{<<"iWillPay">>,<<"i will pay">>},{<<"pay">>,WillPay}] ->
            R=lists:foldr(
                fun([{<<"purpose">>,P},{<<"cur">>,Cur},{<<"amount">>,Amount}],A) ->
                    [#{purpose=>tx:decode_purpose(P), cur=>Cur, amount=>Amount}|A]
                end, [], WillPay),
            {ok, R};
          [{<<"iWillPay">>,<<"no">>},_] ->
            ?LOG_INFO("Sponsor is not willing to pay for tx"),
            false;
          Any ->
            ?LOG_ERROR("~s static call error: unexpected result ~p",[Function,Any]),
            false
        end;
      {done, Other,_} ->
        ?LOG_ERROR("~s static call error: unexpected finish ~p",[Function,Other]),
        false;
      {error, Reason, _} ->
        ?LOG_ERROR("~s static call error ~p",[Function,Reason]),
        false;
      Any ->
        ?LOG_ERROR("~s static call error: unexpected return  ~p",[Function,Any]),
        false
    end
  catch Ec:Ee:S ->
          ?LOG_ERROR("~s static call error: ~p:~p @ ~p",[Function,Ec,Ee,S]),
          false
  end.

%ask_if_wants_to_pay(Address, Tx) ->
%ask_if_wants_to_pay(Address, Tx, fun mledger:getfun/1).

ask_if_wants_to_pay(Address, Tx, GetFun) ->
  Function= <<"wouldYouLikeToPayTx("
  "(uint256,address,address,uint256,uint256,"
  "(string,uint256[])[],"
  "(uint256,string,uint256)[],"
  "(bytes,uint256,bytes,bytes,bytes)[])"
  ")">>,
  try
    %{ok,{_,OutABI,_}}=contract_evm_abi:parse_signature(
    %                    "(string iWillPay,(uint256 purpose,string cur,uint256 amount)[] pay)"
    %                   ),
    OutABI=[{<<"iWillPay">>,string},{<<"pay">>,{darray,{tuple,[{<<"purpose">>,uint256},{<<"cur">>,string},{<<"amount">>,uint256}]}}}],
    {ok,PTx}=preencode_tx(Tx,[]),

    GetCode = fun(Addr,_Ex0) ->
                  GotCode=GetFun({code,binary:encode_unsigned(Addr)}),
                  if is_binary(GotCode) ->
                       GotCode;
                     GotCode==undefined ->
                       <<>>
                  end
              end,
    SLoad=fun(Addr, IKey, _Ex0) ->
              BKey=binary:encode_unsigned(IKey),
              binary:decode_unsigned(
                GetFun({storage,binary:encode_unsigned(Addr),BKey})
               )
          end,

    case call_i(Address, Function, [PTx], #{sload=>SLoad, getcode=>GetCode}) of
      {ok,Ret} ->
        case contract_evm_abi:decode_abi(Ret,OutABI) of
          [{<<"iWillPay">>,<<"i will pay">>},{<<"pay">>,WillPay}] ->
            R=lists:foldr(
                fun([{<<"purpose">>,P},{<<"cur">>,Cur},{<<"amount">>,Amount}],A) ->
                    [#{purpose=>tx:decode_purpose(P), cur=>Cur, amount=>Amount}|A]
                end, [], WillPay),
            {ok, R};
          [{<<"iWillPay">>,<<"no">>},_] ->
            ?LOG_INFO("Sponsor is not willing to pay for tx"),
            false;
          Any ->
            ?LOG_ERROR("~s static call error: unexpected result ~p",[Function,Any]),
            false
        end;
      Any ->
        ?LOG_ERROR("~s static call error: unexpected return  ~p",[Function,Any]),
        false
    end
  catch Ec:Ee:S ->
          ?LOG_ERROR("~s static call error: ~p:~p @ ~p",[Function,Ec,Ee,S]),
          false
  end.

ask_ERC165(Address, InterfaceId) ->
  ask_ERC165(Address, InterfaceId, fun mledger:getfun/1).

ask_ERC165(Address, InterfaceId, GetFun) ->
  GetCode = fun(Addr,_Ex0) ->
                   GotCode=GetFun({code,binary:encode_unsigned(Addr)}),
                   if is_binary(GotCode) ->
                        GotCode;
                      GotCode==undefined ->
                        <<>>
                   end
               end,
  SLoad=fun(Addr, IKey, _Ex0) ->
            BKey=binary:encode_unsigned(IKey),
            binary:decode_unsigned(
              GetFun({storage,binary:encode_unsigned(Addr),BKey})
             )
        end,
  try
    %supportsInterface(bytes4 interfaceId) returns (bool) #01FFC9A7
    {ok,<<1:256/big>>}=call_i(Address, "supportsInterface(bytes4)", [InterfaceId],
                              #{sload=>SLoad, getcode=>GetCode}),
    {ok,<<0:256/big>>}=call_i(Address, "supportsInterface(bytes4)", [<<255,255,255,255>>],
                              #{sload=>SLoad, getcode=>GetCode}),
    true
  catch _:_ -> false
  end.

ask_if_sponsor(Code) ->
  Function= <<"areYouSponsor()">>,
  try
  %{ok,{_,OutABI,_}}=contract_evm_abi:parse_signature( "(bool,bytes,uint256)"),
  OutABI = [{<<"allow">>,bool},{<<"cur">>,bytes},{<<"amount">>,uint256}],
  CD=callcd(Function, [], []),
  {done,{return,Ret},_}=eevm:eval(Code,#{},#{ gas=>2000, extra=>#{}, cd=>CD }),
  case contract_evm_abi:decode_abi(Ret,OutABI) of
    [{_,true},{_,Cur},{_,Amount}] ->
      {true, {Cur,Amount}};
    Any ->
      ?LOG_ERROR("~s static call error: unexpected result ~p",[Function,Any]),
      false
  end
  catch Ec:Ee:S ->
          ?LOG_ERROR("~s static call error: ~p:~p @ ~p",[Function,Ec,Ee,S]),
          false
  end.

callcd(BinFun, CArgs, FABI) ->
  {ok,<<X:4/binary,_/binary>>}=ksha3:hash(256, BinFun),
  true=(length(FABI)==length(CArgs)),
  BArgs=contract_evm_abi:encode_abi(CArgs,FABI),
  <<X:4/binary,BArgs/binary>>.

