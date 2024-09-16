-module(process_embedded).
-export([block_service/5,
		 settings_service/5,
		 lstore_service/5,
		 chkey_service/5,
		 bronkerbosch_service/5
		]).
-include("include/tplog.hrl").


%% getByPath(bytes[])
lstore_service(From, <<16#8D0FE062:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  InABI=[{<<"key">>,{darray,bytes}}],
  try
    [{<<"key">>,Path}]=contract_evm_abi:decode_abi(Bin,InABI),
	{SRes, _Cached, State} = pstate:get_state(From, lstore, Path, State0),
	RBin=contract_evm:enc_settings1(SRes),
    {1,RBin,GasLimit-100,State}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
		  {0, <<"badarg">>, GasLimit-100, State0}
  end;

%% getByPath(address,bytes[])
lstore_service(_From, <<2693574879:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  InABI=[{<<"address">>,address},{<<"key">>,{darray,bytes}}],
  try
    [{<<"address">>,Addr},{<<"key">>,Path}]=contract_evm_abi:decode_abi(Bin,InABI),
	Addr1=if Addr == 0 -> <<0>>;
			 is_integer(Addr) -> binary:encode_unsigned(Addr);
			 is_binary(Addr) -> Addr
		  end,
	{SRes, _Cached, State} = pstate:get_state(Addr1, lstore, Path, State0),
	RBin=contract_evm:enc_settings1(SRes),
    {1,RBin,GasLimit-100,State}
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
		  {0, <<"badarg">>, GasLimit-100, State0}
  end;

%% setByPath(bytes[],uint256,bytes)
lstore_service(From, <<2956342894:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  InABI=[{<<"p">>,{darray,bytes}}, {<<"t">>,uint256}, {<<"v">>,bytes}],
  try
	  [{<<"p">>,Path},{<<"t">>,Type},{<<"v">>,ValB}]=contract_evm_abi:decode_abi(Bin,InABI),
	  Patch=case Type of
				1 -> [{Path,set,ValB}];
				_ -> []
			end,
	  case pstate_lstore:patch(From, Patch, State0) of
		  {ok, State1} ->
			  {1, <<1:256/big>>, GasLimit-(100*length(Patch)), State1};
		  {error, Reason} ->
			  {0, atom_to_binary(Reason), GasLimit-100, State0}
	  end
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
		  {0, <<"badarg">>, GasLimit-100, State0}
  end;

lstore_service(_From, _CallData, GasLimit, State0, _Opts) ->
	{0, <<"badarg">>, GasLimit-100, State0}.

%% setKey(bytes)
chkey_service(From, <<16#218EBFA3:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	try
		InABI=[{<<"key">>,bytes}],
		[{<<"key">>,NewKey}]=contract_evm_abi:decode_abi(Bin,InABI),
		hex:hexdump(NewKey),
		State1=pstate:set_state(From, pubkey, [], NewKey, State0),
		{1, <<1:256/big>>, GasLimit-200, State1}
		catch Ec:Ee:S ->
		  ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
		  {0, <<"badarg">>, GasLimit-100, State0}
	end;

chkey_service(_From, _CallData, GasLimit, State0, _Opts) ->
	{0, <<"badarg">>, GasLimit-100, State0}.


%% max_clique((uint256,uint256[])[])
bronkerbosch_service(_From, <<16#1C20CF3E:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	InABI=[{<<>>,
			{darray,{tuple,[{<<"node_id">>,uint256},
							{<<"nodes">>,{darray,uint256}}]}}}],
	try
		[{<<>>,Data}]=contract_evm_abi:decode_abi(Bin,InABI),
		Data1=[ {N,Ls} || [{<<"node_id">>,N},{<<"nodes">>,Ls}] <- Data ],
		Res=bron_kerbosch:max_clique(Data1),
		?LOG_INFO("BronKerbosch(~p)=x ~p",[Data1, Res]),
		BinRes=contract_evm_abi:encode_abi([Res],[{<<"max_clique">>,{darray,uint256}}]),
		{1, BinRes, GasLimit-100, State0}
	catch Ec:Ee:S ->
			  ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
			  {0, <<"badarg">>, GasLimit-100, State0}
	end;

%% max_clique_list(uint256[2][])
bronkerbosch_service(_From, <<16#85BC5446:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	InABI=[{<<>>,{darray,{{fixarray,2},uint256}}}],
	try
		[{<<>>,Data}]=contract_evm_abi:decode_abi(Bin,InABI),
		Data1=maps:to_list(
				lists:foldl(
				  fun([A,B],Acc) ->
						  maps:put(A,[B|maps:get(A,Acc,[])],Acc)
				  end, #{}, Data)),
		Res=bron_kerbosch:max_clique(Data1),
		?LOG_INFO("BronKerbosch(~p)=x ~p",[Data1, Res]),
		BinRes=contract_evm_abi:encode_abi([Res],[{<<"max_clique">>,{darray,uint256}}]),
		{1, BinRes, GasLimit-100, State0}
	catch Ec:Ee:S ->
			  ?LOG_ERROR("decode_abi error: ~p:~p@~p/~p~n",[Ec,Ee,hd(S),hd(tl(S))]),
			  {0, <<"badarg">>, GasLimit-100, State0}
	end;

bronkerbosch_service(_From, _CallData, GasLimit, State0, _Opts) ->
	{0, <<"badarg">>, GasLimit-100, State0}.

%% byPath(string[])
settings_service(_From, <<3410561484:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	?LOG_ERROR("Unimplemented function ~p at ~p:~w",[?FUNCTION_NAME, ?MODULE, ?LINE]),
	[{<<"key">>,_Path}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,{darray,string}}]),
	%SRes=GetFun({settings,Path}),
	throw({fix_me,?MODULE,?LINE}),
	SRes=#{},
	RBin=contract_evm:enc_settings1(SRes),
	{1,RBin, GasLimit-100, State0};

%% isNodeKnown(bytes)
settings_service(_From, <<3802961955:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	?LOG_ERROR("Unimplemented function ~p at ~p:~w",[?FUNCTION_NAME, ?MODULE, ?LINE]),
	[{<<"key">>,PubKey}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,bytes}]),
	true=is_binary(PubKey),
	%Sets=settings:clean_meta(GetFun({settings,[]})),
	throw({fix_me,?MODULE,?LINE}),
	Sets=#{},
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
	{1,RBin, GasLimit-100, State0};

settings_service(_From, _, GasLimit, State0, _Opts) ->
	{0, <<"badarg">>, GasLimit-100, State0}.

%% get_signatures(uint256 height)
block_service(_From, <<1489993744:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  ?LOG_ERROR("Unimplemented function ~p at ~p:~w",[?FUNCTION_NAME, ?MODULE, ?LINE]),
  io:format("=== get_signatures: ~p~n",[Bin]),
  try
    [{<<"key">>,_N}]=contract_evm_abi:decode_abi(Bin,[{<<"key">>,uint256}]),
	throw({fix_me,?MODULE,?LINE}),
    %#{sign:=Signatures}=GetFun({get_block, N}),
	Signatures=[],	

    Data=lists:sort([ PubKey || #{beneficiary :=  PubKey } <- Signatures]),

    logger:notice("=== get_block: ~p",[Data]),
    RBin=contract_evm_abi:encode_abi([Data], [{<<>>, {darray,bytes}}]),
    {1,RBin, GasLimit-100, State0}
  catch Ec:Ee ->
          logger:info("decode_abi error: ~p:~p~n",[Ec,Ee]),
          {0, <<"badarg">>, GasLimit-100, State0}
  end;

block_service(_From, _, GasLimit, State0, _Opts) ->
  {0, <<"badarg">>, GasLimit-100, State0}.

