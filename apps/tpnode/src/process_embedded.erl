-module(process_embedded).
-export([block_service/5,
		 settings_service/5,
		 lstore_service/5,
		 chkey_service/5,
		 bronkerbosch_service/5,
		 native_minter_service/5,
		 patcher_service/5
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
				2 -> if(size(ValB)>32) -> throw('badarg'); true -> ok end,
					 [{Path,set,binary:decode_unsigned(ValB)}];
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

%% max_clique_mask(uint256[2][]) returns (uint256)
bronkerbosch_service(_From, <<16#E3D9F8D0:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
	InABI=[{<<>>,{darray,{{fixarray,2},uint256}}}],
	try
		[{<<>>,Data}]=contract_evm_abi:decode_abi(Bin,InABI),
		Data1=lists:foldl(
				fun([A,B],Acc) ->
						[{A, bron_kerbosch:unpack_bitmask(B)}|Acc]
				end, [], Data),
		Res=bron_kerbosch:max_clique(Data1),
		Res1=lists:foldl(
			   fun(I,A) ->
					   A bor (1 bsl I)
			   end, 0, Res),
		?LOG_INFO("BronKerbosch(~p)=x ~p -> ~p",[Data1, Res, Res1]),
		BinRes=contract_evm_abi:encode_abi([Res1],[{<<"max_clique">>,uint256}]),
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

%% mint_native(address,string,uint64)
native_minter_service(From, <<16#E0CD84EC:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  InABI=[{<<"addr">>,address}, {<<"token">>,string}, {<<"amount">>,uint64}],
  try
	  [{<<"addr">>,MintTo1},{<<"token">>,Cur},{<<"amount">>,Amount}]=contract_evm_abi:decode_abi(Bin,InABI),
	  MintTo = if is_binary(MintTo1) -> MintTo1;
				  is_integer(MintTo1) -> binary:encode_unsigned(MintTo1)
			   end,
	  case pstate:get_state(<<0>>, lstore, [<<"minter">>,From,Cur], State0) of
		  {1, _Cached, State1} ->

			  {Dst0, _, State2} = pstate:get_state(MintTo, balance, Cur, State1),
			  Dst1=Dst0+Amount,
			  ?LOG_INFO("mint by ~s -> ~s ~w ~s",[hex:encodex(From),hex:encodex(MintTo),Amount,Cur]),
			  State3=pstate:set_state(MintTo, balance, Cur, Dst1, State2),
			  %contract_evm_abi:sigb256(<<"NativeMint(address,string,uint64)">>)
			  LogEntry=[<<"evm">>,<<"MINTER">>,From,Bin,
						[<<223,67,179,1,144,157,250,96,127,99,234,161,65,4,228,111,32,207,178,17,173, 130,254,237,238,33,245,76,27,152,125,32>>]],
			  State4=State3#{log=>[LogEntry|maps:get(log,State3)]},
			  {1, <<1:256/big>>, GasLimit-10000, State4};
		  {_, _, State1} ->
			  {0, <<"denied">>, GasLimit-50000, State1}
	  end
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
		  {0, <<"badarg">>, GasLimit-100, State0}
  end;

%% mint_native(address,string,uint256)
native_minter_service(From, <<16#E03E94EF:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  InABI=[{<<"addr">>,address}, {<<"token">>,string}, {<<"amount">>,uint256}],
  try
	  [{<<"addr">>,MintTo1},{<<"token">>,Cur},{<<"amount">>,Amount}]=contract_evm_abi:decode_abi(Bin,InABI),
	  MintTo = if is_binary(MintTo1) -> MintTo1;
				  is_integer(MintTo1) -> binary:encode_unsigned(MintTo1)
			   end,
	  case pstate:get_state(<<0>>, lstore, [<<"minter">>,From,Cur], State0) of
		  {1, _Cached, State1} ->

			  {Dst0, _, State2} = pstate:get_state(MintTo, balance, Cur, State1),
			  Dst1=Dst0+Amount,
			  ?LOG_INFO("mint by ~s -> ~s ~w ~s",[hex:encodex(From),hex:encodex(MintTo),Amount,Cur]),
			  State3=pstate:set_state(MintTo, balance, Cur, Dst1, State2),
			  %contract_evm_abi:sigb256(<<"NativeMint(address,string,uint256)">>)
			  LogEntry=[<<"evm">>,<<"MINTER">>,From,Bin,
                  [<<195,251,140,242,50,187,173,157,98,122,173,76,161,83,33,20,168,114,62,66,79,
                     202,61,66,238,146,219,212,32,75,0,101>>]],
			  State4=State3#{log=>[LogEntry|maps:get(log,State3)]},
			  {1, <<1:256/big>>, GasLimit-10000, State4};
		  {_, _, State1} ->
			  {0, <<"denied">>, GasLimit-50000, State1}
	  end
  catch Ec:Ee:S ->
          ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
		  {0, <<"badarg">>, GasLimit-100, State0}
  end;

native_minter_service(_From, _CallData, GasLimit, State0, _Opts) ->
	{0, <<"badarg">>, GasLimit-100, State0}.

%% allow_patching()
patcher_service(_From, <<16#4858d4af:32/big>>, GasLimit, #{offchain:=true}=State0, _Opts) ->
    {1, <<>>, GasLimit-100, State0#{patcher_simulation=>true}};
patcher_service(_From, <<16#4858d4af:32/big>>, _GasLimit, State0, _Opts) ->
    {0, <<"disabled">>, 0, State0};

%% patch_ledger((address,uint8,uint256,uint256,bytes)[])
patcher_service(_From, <<16#e71d7bc1:32/big,Bin/binary>>, GasLimit, State0, _Opts) ->
  %% this function is used to patch the ledger, to be able to apply patch node must have
  %% transaction hash in the config file, else it will be rejected.
  %% The reason of appearance of this function is to be able to merge data from other chains
  %% as well as testing purposes.
  %% it's possible to patch such fields as (id numbers from mledger's field_to_id)
  %% 1  balance  uint256 -> uint256)
  %% 2  nonce    -       -> uint256 use big numbers with caution, blockscout can't handle them
  %% 3  code     -       -> bytes
  %% 4  storage  uint256 -> uint256
  %% 5  pubkey   -       -> bytes
  %% function signature
  %% ledger_patch((
  %%     address account_address,
  %%     uint8 field,
  %%     uint256 key,
  %%     uint256 int_value,
  %%     bytes bin_value
  %% )[])

  Allowed=case State0 of
            #{patcher_simulation:=true,offchain:=true} ->
              true;
            #{cur_tx:=#{hash:=TxHash0}} ->
              lists:member( hex:encode(TxHash0), application:get_env(tpnode,allow_patch,[]));
            _ -> false
          end,
  if Allowed==false ->
       case State0 of
         #{offchain:=_} ->
           ok;
         #{cur_tx:=#{hash:=TxHash}} ->
           ?LOG_ERROR("patching denied for tx ~s",[hex:encode(TxHash)]);
         _ -> ok
       end,
       {0, <<"denied">>, 0, State0};
     Allowed==true ->
       InABI=[{<<>>,
               {darray,{tuple,[{<<"account">>,address},
                               {<<"field">>,uint8},
                               {<<"key">>,uint256},
                               {<<"int_val">>,uint256},
                               {<<"bin_val">>,bytes}]}}}],
       try
         [{_,Array}]=contract_evm_abi:decode_abi(Bin,InABI),
         State2=lists:foldl(
                  fun ([{_,Address},{_,1},{_,Key},{_,IntVal},{_,<<>>}], Acc) ->
                      pstate:set_state(Address, balance, binary:encode_unsigned(Key), IntVal, Acc);
                      ([{_,Address},{_,2},{_,0},{_,IntVal},{_,<<>>}], Acc) ->
                      pstate:set_state(Address, seq, [], IntVal, Acc);
                      ([{_,Address},{_,3},{_,0},{_,0},{_,Code}], Acc) ->
                      pstate:set_state(Address, code, [], Code, Acc);
                      ([{_,Address},{_,4},{_,Key},{_,IntVal},{_,<<>>}], Acc) ->
                      pstate:set_state(Address, storage,
                                       binary:encode_unsigned(Key),
                                       binary:encode_unsigned(IntVal), Acc);
                      ([{_,Address},{_,5},{_,0},{_,0},{_,PubKey}], Acc) ->
                      pstate:set_state(Address, pubkey, [], PubKey, Acc)
                  end, State0, Array),
         {1, <<(length(Array)):256/big>>, GasLimit-100, State2}
       catch Ec:Ee:S ->
               ?LOG_ERROR("decode_abi error: ~p:~p@~p~n",[Ec,Ee,S]),
               {0, <<"error">>, GasLimit-100, State0}
       end
  end;

patcher_service(_From, _CallData, GasLimit, State0, _Opts) ->
  {0, <<"badarg">>, GasLimit-100, State0}.
