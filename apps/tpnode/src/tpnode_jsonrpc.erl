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
    ?LOG_ERROR("Got req for eth_sendRawTransaction with ~p",[Params]),
    throw(server_error);

handle(<<"eth_getTransactionCount">>,[Address,_Block]) ->
    ?LOG_ERROR("Got req for eth_getTransactionCount for ~p",[Address]),
    i2hex(0);

handle(<<"eth_call">>,[{Params},_]) ->
    ?LOG_ERROR("Got req for eth_call arg1 ~p",[Params]),
    To=proplists:get_value(<<"to">>,Params),
    Data=proplists:get_value(<<"data">>,Params),
    From=proplists:get_value(<<"from">>,Params,<<"0x">>),
  case tpnode_evmrun:evm_run(
         hex:decode(To),
         <<"0x0">>,
         [hex:decode(Data)],
         #{caller=>hex:decode(From),gas=>2000000}
        ) of
    #{bin:=Bin}=_es ->
          <<"0x",(binary:encode_hex(Bin))/binary>>;
      _ ->
          throw(server_error)
  end;


handle(<<"eth_getBlockByNumber">>,Params) ->
    ?LOG_ERROR("Got req for eth_getBlockByNumber args ~p",[Params]),
    {[{<<"difficulty">>,<<"0x1">>},
      {<<"extraData">>,<<"0x">>},
      {<<"gasLimit">>,<<"0x79f39e">>},
      {<<"gasUsed">>,<<"0x79ccd3">>},
      {<<"logsBloom">>,<<"0x">>},
      {<<"miner">>,<<"0x">>},
      {<<"nonce">>,<<"0x1">>},
      {<<"number">>,<<"0x5bad55">>},
      {<<"hash">>,<<"0xb3b20624f8f0f86eb50dd04688409e5cea4bd02d700bf6e79e9384d47d6a5a35">>},
      {<<"mixHash">>,<<"0x3d1fdd16f15aeab72e7db1013b9f034ee33641d92f71c0736beab4e67d34c7a7">>},
      {<<"stateRoot">>,<<"0xf5208fffa2ba5a3f3a2f64ebd5ca3d098978bedd75f335f56b705d8715ee2305">>},
      {<<"parentHash">>,<<"0x61a8ad530a8a43e3583f8ec163f773ad370329b2375d66433eb82f005e1d6202">>},
      {<<"receiptsRoot">>,<<"0x5eced534b3d84d3d732ddbc714f5fd51d98a941b28182b6efe6df3a0fe90004b">>},
      {<<"transactionsRoot">>,<<"0xf98631e290e88f58a46b7032f025969039aa9b5696498efc76baf436fa69b262">>},
      {<<"totalDifficulty">>,<<"0x12ac11391a2f3872fcd">>},
      {<<"sha3Uncles">>,<<"0x">>},
      {<<"size">>,<<"0x41c7">>},
      {<<"timestamp">>,<<"0x5b541449">>},
      {<<"transactions">>,[
                           <<"0x8784d99762bccd03b2086eabccee0d77f14d05463281e121a62abfebcf0d2d5f">>,
                           <<"0x241d89f7888fbcfadfd415ee967882fec6fdd67c07ca8a00f2ca4c910a84c7dd">>
                          ]},
      {<<"uncles">>,[]}
     ]};

handle(<<"eth_getBalance">>,[<<"0x",Address/binary>>,BlkId]) ->
    ?LOG_ERROR("Got req for eth_getBalance for address ~p blk ~p",[Address,BlkId]),
    i2hex(trunc(123.0e18));

handle(<<"eth_blockNumber">>,[]) ->
    LBHei=maps:get(height,maps:get(header,blockchain:last_permanent_meta())),
    i2hex(LBHei);

handle(<<"eth_chainId">>,[]) ->
    Chid=maps:get(chain,maps:get(header,blockchain:last_permanent_meta()))+1000000000,
    i2hex(Chid);

handle(<<"eth_gasPrice">>,[]) ->
    i2hex(10);

handle(<<"eth_getLogs">>,[{PList}]) ->
    io:format("PL ~p~n",[maps:from_list(PList)]),
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
    lists:foldl(
      fun(Number,Acc) ->
              Block=logs_db:get(Number),
              if is_map(Block) ->
                     Acc++process_log(Block, Topics, Addresses);
                 true ->
                     Acc
              end
      end, [], lists:seq(FromBlock,ToBlock));

handle(Method,_Params) ->
    ?LOG_ERROR("Method ~s not found",[Method]),
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


