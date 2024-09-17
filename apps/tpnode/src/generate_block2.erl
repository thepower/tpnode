-module(generate_block2).

-include("include/tplog.hrl").

-export([generate_block/5, generate_block/6]).

generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData) ->
  generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, GetAddr, ExtraData, []).

generate_block(PreTXL, {Parent_Height, Parent_Hash}, GetSettings, _GetAddr, ExtraData, Options) ->
	LedgerName = case lists:keyfind(ledger_pid, 1, Options) of
					 {ledger_pid, N} when is_atom(N) ->
						 N;
					 _Default ->
						 mledger
				 end,

	Entropy=proplists:get_value(entropy, Options, <<>>),
	MeanTime=proplists:get_value(mean_time, Options, 0),

	State0=maps:merge(
			 process_txs:upgrade_settings(
			   % chainsettings:by_path([<<"current">>]),
			   maps:get(<<"current">>,GetSettings(settings)),
			   fun mledger:getfun/2,
			   LedgerName
			  ),
			 #{
			   entropy=>Entropy,
			   mean_time=>MeanTime,
			   parent=>Parent_Hash,
			   height=>Parent_Height+1,
			   transaction_receipt => [],
			   block_logs => [],
			   transaction_index=>0
			  }),
	#{transaction_receipt:=Receipt,
	  patch := Patch,
	  process_state  := #{ acc:= _GAcc, cumulative_gas := CumulativeGas},
	  block_logs := Logs
	 } = process_all(PreTXL, State0),
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

	%io:format("Patch ~p~n",[Patch]),
	NewBal=patch2bal(Patch, #{}),
	%io:format("Bal ~p~n",[NewBal]),
	{ok, LedgerHash} = mledger:apply_patch(LedgerName,
									 mledger:patch_pstate2mledger(
									   Patch
									  ),
									 check),
	BlkData=#{
            txs=>PreTXL, %Success, %[{TxID,TxBody}|_]
			receipt => Receipt,
            parent=>Parent_Hash,
            mychain=>GetSettings(mychain),
            height=>Parent_Height+1,
            bals=>NewBal,
            failed=>[],
            temporary=>proplists:get_value(temporary,Options),
            ledger_hash=>LedgerHash,
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
  ?LOG_INFO("Created block ~w ~s...: txs: ~w, bals: ~w, LH: ~s, ch: ~p tmp: ~p time: ~p",
             [
              Parent_Height+1,
              block:blkid(maps:get(hash, Blk)),
              length(PreTXL),
              maps:size(NewBal),
              case LedgerHash of
                undefined ->
                   "undefined";
                 <<H:8/binary,_/binary>> ->
                   [hex:encode(H),"..."]
              end,
              GetSettings(mychain),
              proplists:get_value(temporary,Options),
              MeanTime
             ]),
  ?LOG_DEBUG("Hdr ~p",[maps:get(header,Blk)]),
  #{block=>Blk,
    failed=>[],
    emit=>[],
    log=>Logs
   }.

process_all([], #{transaction_receipt:=Rec, block_logs := BL0} = Acc) ->
	#{transaction_receipt=>lists:reverse(Rec),
	  patch => pstate:patch(Acc),
	  process_state => Acc,
	  block_logs => lists:reverse(BL0)
	 };

process_all([{TxID,TxBody}|Rest], #{transaction_receipt:=Rec ,
									transaction_index:=Index,
									block_logs := BL0
								   } = State0) ->
	{Ret,RetData,State1}=process_txs:process_tx(TxBody, State0, #{}),

	Rec1=[
		  [Index,
		   TxID,
		   maps:get(hash,TxBody,<<0:256/big>>),
		   Ret,
		   RetData,
		   maps:get(last_tx_gas, State1),
		   maps:get(cumulative_gas, State1),
		   lists:reverse(maps:get(log,State1))
		  ] | Rec],

	BL1=lists:foldr(
		  fun(LL, Acc) ->
				  [msgpack:pack([TxID|LL])|Acc]
		  end, BL0, maps:get(log,State1)),

	process_all(Rest, State1#{
						transaction_receipt:=Rec1,log=>[],
						transaction_index=>Index+1,
						block_logs => BL1
					   }).

patch2bal([], Map) -> Map;
patch2bal([{Address,seq,[],_OldValue,NewValue}|Rest], Map) ->
	ABal=maps:get(Address, Map, mbal:new()),
	ABal1=mbal:put(seq, NewValue, ABal),
	patch2bal(Rest, maps:put(Address, ABal1, Map));

patch2bal([{Address,code,[],_OldValue,NewValue}|Rest], Map) ->
	ABal=maps:get(Address, Map, mbal:new()),
	ABal1=mbal:put(code, NewValue, ABal),
	patch2bal(Rest, maps:put(Address, ABal1, Map));

patch2bal([{Address,balance,Key,_OldValue,NewValue}|Rest], Map) ->
	ABal=maps:get(Address, Map, mbal:new()),
	ABal1=mbal:put(amount, Key, NewValue, ABal),
	patch2bal(Rest, maps:put(Address, ABal1, Map));

patch2bal([{Address,storage,Key,_OldValue,NewValue}|Rest], Map) ->
	ABal=maps:get(Address, Map, mbal:new()),
	ABal1=mbal:put(state, Key, NewValue, ABal),
	patch2bal(Rest, maps:put(Address, ABal1, Map)).

