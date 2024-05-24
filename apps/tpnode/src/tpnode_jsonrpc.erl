-module(tpnode_jsonrpc).
-include("include/tplog.hrl").
-export([handle/2]).
%% -----------------------------------------------------------------
%% WARNING: This interface is highly experemental, only tiny part of
%% ethereum RPC supported yet
%% -----------------------------------------------------------------

% valid errors
%throw:E when E == method_not_found; E == invalid_params; E == internal_error; E == server_error ->
%    make_standard_error_response(E, Id);
%throw:{E, Data} when E == method_not_found; E == invalid_params; E == internal_error; E == server_error ->
%    make_standard_error_response(E, Data, Id);
%throw:{jsonrpc2, Code, Message} when is_integer(Code), is_binary(Message) ->
%    %% Custom error, without data
%    %% -32000 to -32099	Server error Reserved for implementation-defined server-errors.
%    %% The remainder of the space is available for application defined errors.
%    make_error_response(Code, Message, Id);
%throw:{jsonrpc2, Code, Message, Data} when is_integer(Code), is_binary(Message) ->
%    %% Custom error, with data
%    make_error_response(Code, Message, Data, Id);

handle(<<"net_version">>,[]) ->
  i2hex(1);

handle(<<"eth_sendRawTransaction">>,Params) ->
    ?LOG_INFO("Got req for eth_sendRawTransaction with ~p",[Params]),
    throw(server_error);

handle(<<"eth_getTransactionCount">>,[Address, Block]) ->
    D=get_ledger(Address, seq, [], Block),
    ?LOG_INFO("Got req for eth_getTransactionCount for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{seq,[],S}] ->
            i2hex(S);
        [] ->
            i2hex(0)
    end;

handle(<<"eth_getStorageAt">>,[Address, Position, Block]) ->
    D=get_ledger(Address, state, hex2bin(Position), Block),
    ?LOG_INFO("Got req for eth_getStorageAt for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{state,_,Value}] ->
            b2hex(Value);
        [] ->
            b2hex(<<>>)
    end;

handle(<<"eth_getCode">>,[Address, Block]) ->
    D=get_ledger(Address, code, [], Block),
    ?LOG_INFO("Got req for eth_getCode for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{code,[],S}] ->
            b2hex(S);
        [] ->
            b2hex(<<>>)
    end;

handle(<<"eth_call">>,[{Params},Block]) ->
    ?LOG_INFO("Got req for eth_call arg1 ~p",[Params]),
    To=proplists:get_value(<<"to">>,Params),
    Data=proplists:get_value(<<"data">>,Params),
    From=case proplists:get_value(<<"from">>,Params,null) of
             null -> <<"0x">>;
             NotNull1 -> NotNull1
         end,
    case tpnode_evmrun:evm_run(
           hex:decode(To),
           <<"0x0">>,
           [hex:decode(Data)],
           #{caller=>hex:decode(From),
             gas=>2000000,
             block_height=>case Block of <<"latest">> -> undefined; _ -> hex2i(Block) end
            }
          ) of
        #{result:=revert, bin:=Bin}=_es ->
            throw({jsonrpc2, 32000, <<"execution reverted">>, hex:encodex(Bin)});
        #{bin:=Bin}=_es ->
            hex:encodex(Bin);
        _ ->
            throw({jsonrpc2, 10000, <<"evm_run unexpected result">>})
    end;


handle(<<"eth_getBlockByNumber">>,[Number,_Details]=Params) ->
    Block=case Number of
               <<"0x",N/binary>> ->
                  blockchain_reader:get_block(binary_to_integer(N,16));
               <<"latest">> ->
                  blockchain_reader:get_block(last_permanent)
          end,
    ?LOG_INFO("Got req for eth_getBlockByNumber args ~p",[Params]),
    case Block of
        not_found ->
            throw(server_error);
        #{hash:=Hash,header:=#{height:=Hei,parent:=Parent}=Hdr}=B ->
            Txs=maps:get(txs,Block,[]),
            ?LOG_ERROR("Hdr ~p~n",[B]),
            {[
              {<<"difficulty">>,<<"0x1">>},
              {<<"extraData">>,<<"0x">>},
              {<<"gasLimit">>,<<"0x79f39e">>},
              {<<"gasUsed">>,<<"0x79ccd3">>},
              {<<"logsBloom">>,hex:encodex(proplists:get_value(log_hash,maps:get(roots,Hdr,[]),<<>>))},
              {<<"miner">>,<<"0x">>},
              {<<"nonce">>,<<"0x1">>},
              {<<"number">>,hex:encodex(Hei)},
              {<<"hash">>,hex:encodex(Hash)},
              {<<"mixHash">>,<<"0x0000000000000000000000000000000000000000000000000000000000000000">>},
              {<<"stateRoot">>,hex:encodex(proplists:get_value(ledger_hash,maps:get(roots,Hdr,[]),<<>>))},
              {<<"parentHash">>,hex:encodex(Parent)},
              {<<"transactionsRoot">>,hex:encodex(proplists:get_value(txroot,maps:get(roots,Hdr,[]),<<>>))},
              {<<"totalDifficulty">>,<<"0x1">>},
              {<<"sha3Uncles">>,<<"0x">>},
              {<<"size">>,<<"0x41c7">>},
              {<<"timestamp">>,i2hex(binary:decode_unsigned(
                                           proplists:get_value(mean_time,
                                                               maps:get(roots,Hdr,[]),
                                                               <<>>)))},
              {<<"transactions">>, [ TxID || {TxID, _} <- Txs ] },
              {<<"uncles">>,[]}
             ]}
    end;

handle(<<"eth_getBalance">>,[<<Address/binary>>,Block,Token]) ->
    D=get_ledger(Address, amount, [], Block),
    ?LOG_INFO("Got req for eth_getBalance for address ~p blk ~p = ~p",[Address, Block, D]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(Token,Map,0));
        [] ->
            i2hex(0)
    end;

handle(<<"eth_getBalance">>,[<<Address/binary>>,Block]) ->
    D=get_ledger(Address, amount, [], Block),
    ?LOG_INFO("Got req for eth_getBalance for address ~p blk ~p = ~p",[Address, Block, D]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(<<"SK">>,Map,0));
        [] ->
            i2hex(0)
    end;


handle(<<"eth_blockNumber">>,[]) ->
    LBHei=maps:get(height,maps:get(header,blockchain:last_permanent_meta())),
    i2hex(LBHei);

handle(<<"eth_chainId">>,[]) ->
    Chid=maps:get(chain,maps:get(header,blockchain:last_permanent_meta()))+1000000000,
    i2hex(Chid);

handle(<<"eth_gasPrice">>,[]) ->
    i2hex(10);

handle(<<"eth_getLogs">>,[{PList}]) ->
    handle(<<"eth_getLogs">>,maps:from_list(PList));

handle(<<"eth_getLogs">>, #{<<"blockHash">>:=HexBlockHash}=Map) ->
    %Address=proplists:get_value(<<"address">>,PList,<<>>),
    %FromBlock=proplists:get_value(<<"fromBlock">>,PList,<<>>),
    %ToBlock=proplists:get_value(<<"toBlock">>,PList,<<>>),
    BlockHash=hex2bin(HexBlockHash),
    Topics=[ hex2bin(T) || T <- maps:get(<<"topics">>,Map,[]) ],
    Addresses=[ hex2bin(A) || A <- maps:get(<<"address">>,Map,[]) ],
    Block=logs_db:get(BlockHash),
    logger:info("eth_getLogs ~p(~p)~n",[Topics,BlockHash]),
    process_log(Block,Topics,Addresses);

handle(<<"eth_getLogs">>, #{}=Map) ->
    #{header:=#{height:=LBH}}=blockchain:last_permanent_meta(),
    FromBlock=case maps:get(<<"fromBlock">>,Map,undefined) of
                  undefined -> LBH;
                  HexB -> hex2i(HexB)
              end,
    ToBlock=case maps:get(<<"toBlock">>,Map,undefined) of
                  undefined -> LBH;
                  HexB1 -> hex2i(HexB1)
              end,
    logger:info("Request logs from ~w .. ~w",[FromBlock,ToBlock]),
    if(ToBlock<FromBlock) ->
          throw(invalid_params);
      true ->
          ok
    end,
    Topics=[ hex2bin(T) || T <- maps:get(<<"topics">>,Map,[]) ],
    Addresses=[ hex2bin(A) || A <- maps:get(<<"address">>,Map,[]) ],
    T0=erlang:system_time(millisecond),
    {_,Res}=lists:foldl(
              fun
                  (_,{Cnt,_}) when Cnt>10000 ->
                      throw({jsonrpc2, 32005, <<"query returned more than 10000 results">>});
                  (Number,{Cnt,Acc}) ->
                      T1=erlang:system_time(millisecond),
                      if(T1-T0) > 10000 ->
                            throw({jsonrpc2, 32005, <<"query timeout exceeded">>});
                        true -> ok
                      end,
                      Block=logs_db:get(Number),
                      if is_map(Block) ->
                             Logs=process_log(Block, Topics, Addresses),
                             NC=length(Acc),
                             {Cnt+NC, Acc++Logs};
                         true ->
                             {Cnt,Acc}
                      end
              end, {0,[]}, lists:seq(FromBlock,ToBlock)),
    Res;

handle(Method,_Params) ->
    ?LOG_ERROR("Method ~s(~p) not found",[Method,_Params]),
    throw(method_not_found).

b2hex(B) when is_binary(B) ->
    <<"0x",(binary:encode_hex(B))/binary>>.

i2hex(I) when is_integer(I) ->
    <<"0x",(integer_to_binary(I,16))/binary>>.

hex2i(<<"0x",B/binary>>) ->
    binary_to_integer(B,16).

hex2bin(<<"0x",B/binary>>) ->
    binary:decode_hex(B).


cmp_topic([A|FTopics], [B|ETopics]) ->
    if(A=/=B) ->
          false;
      true ->
          cmp_topic(FTopics, ETopics)
    end;
cmp_topic([],_) ->
    true;
cmp_topic([_|_],[]) ->
    false.

process_log(#{logs:=Logs}=Data, Filter, Addr) ->
    lists:filtermap(
      fun(E) ->
              case msgpack:unpack(E) of
                  {ok, D} ->
                      process_log_element(D, Data, Filter, Addr)
              end
      end,
      Logs);

process_log(#{},_Filter,_Addr) ->
    [].

process_log_element([_ETxID,<<"evm">>,<<"revert">>,_EData], _Data, _Filter, _Addrs) ->
    false;
process_log_element([_ETxID,<<"evm:revert">>,EFrom,_ETo,_EData], _Data, _Filter, _Addrs) ->
    logger:info("ignore revert from ~s",[b2hex(EFrom)]),
    false;
process_log_element([ETxID,<<"evm">>,EFrom,_ETo,EData,ETopics], Data, Filter, Addrs) ->
    UAllow = if(Addrs==[]) ->
                   true;
               true ->
                   case lists:member(EFrom,Addrs) of
                       false -> false;
                       true ->
                           cmp_topic(Filter,ETopics)
                   end
             end,
    if(UAllow == false) ->
          false;
      true ->
          {true,{[
                  {address,b2hex(EFrom)},
                  {blockHash, b2hex(maps:get(blkid,Data))},
                  {blockNumber, i2hex(maps:get(height,Data))},
                  {transactionId, ETxID},
                  {transactionHash, b2hex(ETxID)},
                  {transactionIndex, i2hex(1)},
                  {logIndex, i2hex(1)},
                  {data, b2hex(EData)},
                  {topics, [ b2hex(ET) || ET <- ETopics]},
                  {removed, false}
                 ]}}
    end;

process_log_element(U, _Data, _Filter, _Addrs) ->
    logger:info("Unknown event ~p",[U]),
    false.

get_ledger(Address, Key, Path, <<"latest">>) ->
    mledger:get_kpvs(hex:decode(Address), Key, Path);
get_ledger(Address, Key, Path, Block) ->
    mledger:get_kpvs_height(hex:decode(Address), Key, Path, hex2i(Block)).
