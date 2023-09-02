-module(sponsor_sc_test_test).

-include_lib("eunit/include/eunit.hrl").

ssc_test() ->
  {ok,Bin} = file:read_file("examples/evm_builtin/build/sponsor.bin"),
  ABI=contract_evm_abi:parse_abifile("examples/evm_builtin/build/sponsor.abi"),

  Code1=hex:decode(hd(binary:split(Bin,<<"\n">>))),

  {done,{return,Code2},_}=eevm:eval(Code1,#{},#{ gas=>1000000, extra=>#{} }),

  %BinFun= <<"areYouSponsor()">>,
  %{ok,E}=ksha3:hash(256, BinFun),
  %<<X:4/binary,_/binary>> = E,
  %CD= <<X:4/binary>>,

  %{done,{return,Ret},_}=eevm:eval(Code2,#{},#{ gas=>10000, extra=>#{}, cd=>CD }),
  %[{_,_,FABI}]=contract_evm_abi:find_function(BinFun,ABI),

  %DRet=contract_evm_abi:decode_abi(Ret,FABI),
  DRet=call(<<"areYouSponsor()">>,[],ABI,Code2),
  DRet2=call(<<"wouldYouLikeToPayTx((uint256,address,address,uint256,uint256,(string,uint256[])[],(uint256,string,uint256)[],(bytes,uint256,bytes,bytes,bytes)[]))">>,
             [
              [1,<<1,2,3,4,5,6,7,8>>,<<1,2,3,4,5,6,7,9>>,1,2,[],
               [[1,<<"SK">>,5],[2,<<"SK">>,6]],
              []
              ]],ABI,Code2),
  %wouldYouLikeToPayTx(tpTx calldata utx) p
  [?assertMatch([{<<"arg1">>,true},{<<"arg2">>,<<"SK">>},{<<"arg3">>,100000}], DRet),
   ?assertMatch([{<<"iWillPay">>,<<"i will pay">>},
        {<<"pay">>,
         [[{<<"purpose">>,0},{<<"cur">>,<<"SK">>},{<<"amount">>,10}]]}],DRet2)
  ].

call(Function, CArgs, ABI, Code) when is_binary(Function), is_list(CArgs) ->
  [{_,InABI,OutABI}]=contract_evm_abi:find_function(Function,ABI),
  CD=callcd(Function, CArgs, InABI),
  {done,{return,Ret},_}=eevm:eval(Code,#{},#{ gas=>10000, extra=>#{}, cd=>CD }),
  contract_evm_abi:decode_abi(Ret,OutABI).

callcd(BinFun, CArgs, FABI) ->
  {ok,E}=ksha3:hash(256, BinFun),
  <<X:4/binary,_/binary>> = E,
  true=(length(FABI)==length(CArgs)),
  BArgs=contract_evm_abi:encode_abi(CArgs,FABI),
  <<X:4/binary,BArgs/binary>>.

