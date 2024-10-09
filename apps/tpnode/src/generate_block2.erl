-module(generate_block2).

-include("include/tplog.hrl").

-export([generate_block/4]).

generate_block(PreTXL0, {Parent_Height, Parent_Hash}, ExtraData, Options) ->
	LedgerName = case lists:keyfind(ledger_pid, 1, Options) of
					 {ledger_pid, N} when is_atom(N) ->
						 N;
					 _Default ->
						 mledger
				 end,

	{PreTXL1, Failed1} = ensure_verified(PreTXL0, LedgerName),

	Entropy=proplists:get_value(entropy, Options, <<>>),
	MeanTime=proplists:get_value(mean_time, Options, 0),
	MyChain=proplists:get_value(chain,Options,65535),
	NoAfterblock=proplists:get_value(no_afterblock,Options,false),

	State0=case lists:keyfind(migrate_settings, 1, Options) of
			   {migrate_settings, Settings} ->
				   process_txs:upgrade_settings_persist(
					 maps:get(<<"current">>,Settings),
					 fun mledger:getfun/2,
					 LedgerName
					);
			   false ->
				   process_txs:new_state(
					 fun mledger:getfun/2,
					 LedgerName
					)
		   end,

	PreTXL
	= if PreTXL1==[] orelse NoAfterblock==true->
			 PreTXL1;
		 true ->
			 case pstate:get_state(<<0>>, lstore,
								   [ <<"autorun">>, <<"afterBlock">> ],
								   State0) of
				 {AutoRunAddr, _, _S1} when is_binary(AutoRunAddr) ->
					 PreTXL1++[{<<"~afterBlock">>,
								maps:merge(
								  tx:construct_tx(
									#{
									  call => #{args => [],function => "afterBlock()"},
									  from => <<0>>,
									  kind => generic,
									  payload => [],
									  seq => Parent_Height+1,
									  t => MeanTime,
									  to => AutoRunAddr,
									  txext => #{},
									  ver => 2}),
								  #{
									sig => [],
									sigverify => #{invalid => 0, pubkeys => [<<>>], valid => 1}
								   })}];
				 _ -> PreTXL1
			 end
	  end,

	State1=maps:merge(State0,
					  #{
						entropy=>Entropy,
						mean_time=>MeanTime,
						parent=>Parent_Hash,
						height=>Parent_Height+1,
						transaction_receipt => [],
						block_logs => [],
						failed => Failed1,
						transaction_index=>0,
						chainid=>MyChain+1000000
					   }),


	#{transaction_receipt:=Receipt,
	  patch := Patch,
	  failed := Failed2,
	  process_state  := #{ acc:= _GAcc, cumulative_gas := CumulativeGas}=PS,
	  block_logs := Logs
	 } = process_all(PreTXL, State1),
	%[Receipt, Patch].

	Roots=if Logs==[] ->
             [
              {entropy, Entropy},
              {mean_time, <<MeanTime:64/big>>},
			  {cumulative_gas, <<CumulativeGas:64/big>>}
             ];
           true ->
             LogsHash=crypto:hash(sha256, Logs),
             [
              {entropy, Entropy},
              {log_hash, LogsHash},
              {mean_time, <<MeanTime:64/big>>},
			  {cumulative_gas, <<CumulativeGas:64/big>>}
             ]
        end,

	%NewBal=patch2bal(Patch, #{}),
	%io:format("Bal ~p~n",[NewBal]),
	{ok, LedgerHash} = mledger:apply_patch(LedgerName,
									 mledger:patch_pstate2mledger(
									   Patch
									  ),
									 check),
	%io:format("Block receipt ~p~n",[Receipt]),
	%
	BlkData=#{
            txs=>PreTXL, %Success, %[{TxID,TxBody}|_]
			receipt => Receipt,
            parent=>Parent_Hash,
            mychain=>MyChain,
            height=>Parent_Height+1,
            %bals=>NewBal,
            failed=>Failed2,
            temporary=>proplists:get_value(temporary,Options),
            ledger_hash=>LedgerHash,
			ledger_patch=>Patch,
            settings=>[],
            extra_roots=>Roots,
            extdata=>ExtraData
           },
  Blk=block:mkblock2(BlkData),
  ?LOG_DEBUG("BLK ~p",[BlkData]),

  % TODO: Remove after testing
  % Verify myself
  % Ensure block may be packed/unapcked correctly
  case block:verify(block:unpack(block:pack(Blk))) of
    {true, _} -> ok;
    false ->
      ?LOG_ERROR("Block is not verifiable after repacking!!!!"),
      file:write_file("log/blk_repack_error.txt",
                      io_lib:format("~w.~n", [Blk])
                     ),

      case block:verify(Blk) of
        {true, _} -> ok;
        false ->
          ?LOG_ERROR("Block is not verifiable at all!!!!")
      end

  end,

  _T6=erlang:system_time(),
  ?LOG_INFO("Created block ~w ~s...: txs: ~w, patch: ~w, LH: ~s, ch: ~p tmp: ~p time: ~p",
             [
              Parent_Height+1,
              block:blkid(maps:get(hash, Blk)),
              length(PreTXL),
			  length(Patch),
              case LedgerHash of
                undefined ->
                   "undefined";
                 <<H:8/binary,_/binary>> ->
                   [hex:encode(H),"..."]
              end,
              MyChain,
              proplists:get_value(temporary,Options),
              MeanTime
             ]),
  ?LOG_DEBUG("Hdr ~p",[maps:get(header,Blk)]),
  ?LOG_DEBUG("Block patch ~p",[Patch]),
  case lists:keyfind(extract_state,1,Options) of
	  false ->
		  #{block=>Blk,
			failed=>Failed2,
			emit=>[],
			log=>Logs
		   };
	  {extract_state,raw} ->
		  #{block=>Blk,
			failed=>Failed2,
			emit=>[],
			log=>Logs,
			extracted_state => pstate:extract_state(PS)
		   };
	  {extract_state,_} ->
		  #{block=>Blk,
			failed=>Failed2,
			emit=>[],
			log=>Logs,
			extracted_state => block:patch2bal( pstate:extract_state(PS), #{})
		   }
  end.

process_all([], #{transaction_receipt:=Rec, block_logs := BL0, failed:=Failed} = Acc) ->
	#{transaction_receipt=>lists:reverse(Rec),
	  patch => pstate:patch(Acc),
	  process_state => Acc,
	  failed => Failed,
	  block_logs => lists:reverse(BL0)
	 };

process_all([{TxID,TxBody}|Rest], #{transaction_receipt:=Rec ,
									transaction_index:=Index,
									height := Hei,
									block_logs := BL0,
									failed := Failed0
								   } = State0) ->
	try
		State1=case TxBody of
				   #{from:=From,seq:=Seq} when From=/=<<0>> ->
					   {Seq0,_,State0b}=pstate:get_state(From, seq, [], State0),
					   ?LOG_INFO("Process generic ~s ~p / ~p",[TxID, Seq0, Seq]),
					   if Seq0==<<>> -> ok;
						  Seq>Seq0 -> ok;
						  true -> throw(bad_seq)
					   end,
					   State0b;
				   _ ->
					   State0
			   end,

		{Ret,RetData,State2}=process_txs:process_tx(TxBody, State1, #{}),
		?LOG_INFO("Proc ~s res ~w: ~s",[TxID,Ret,hex:encode(RetData)]),
		State3=case TxBody of
				   #{from:=From2,seq:=USeq} when From2=/=<<0>> ->
					   State2b=pstate:set_state(From2, seq, [], USeq, State2),
					   pstate:set_state(From2, lastblk, <<"tx">>, Hei, State2b);
				   _ -> State2
			   end,

		Rec1=[
			  [Index,
			   TxID,
			   maps:get(hash,TxBody,<<0:256/big>>),
			   Ret,
			   RetData,
			   maps:get(last_tx_gas, State3,0),
			   maps:get(cumulative_gas, State3),
			   lists:reverse(maps:get(log,State3))
			  ] | Rec],

		BL1=lists:foldr(
			  fun(LL, Acc) ->
					  [msgpack:pack([TxID|LL])|Acc]
			  end, BL0, maps:get(log,State3)),

		process_all(Rest, State3#{
							transaction_receipt:=Rec1,log=>[],
							transaction_index=>Index+1,
							block_logs => BL1
						   })
	catch throw:bad_seq ->
			  process_all(Rest,
						  State0#{
							failed=>[{TxID,<<"bad_seq">>}|Failed0]
						   })
	end.



ensure_verified([], _) ->
	{[], []};

ensure_verified([{TxID, TxBody=#{sigverify:=_}}|Rest], LedgerName) ->
	{PreS, PreF} = ensure_verified(Rest, LedgerName),
	{[{TxID, TxBody}|PreS], PreF};

ensure_verified([{TxID, TxBody}|Rest], LedgerName) ->
	{PreS, PreF} = ensure_verified(Rest, LedgerName),
	case tx:verify(TxBody,[{ledger,LedgerName}]) of
		{ok, Verified} ->
			{[{TxID, Verified}|PreS], PreF};
		bad_sig ->
			{PreS, [{TxID,<<"bad_sig">>}|PreF]}
	end.

