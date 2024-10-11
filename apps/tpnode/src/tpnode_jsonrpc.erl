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
  ?LOG_INFO("Got req for net_version",[]),
  i2hex(chain_id());

handle(<<"eth_getTransactionReceipt">>,[TxHash0]) ->
  ?LOG_INFO("Got req for eth_getTransactionReceipt ~s",[TxHash0]),
  case
  gen_server:call(blockchain_reader,{txhash, hex:decode(TxHash0) ,true})
  of
    badarg ->
      throw({jsonrpc2, 10001, <<"badarg">>});
    not_found ->
      throw({jsonrpc2, 10001, <<"not found">>});
    #{block:=BlkHash,
      hei:=BlkHei,
      hash:=TxHash,
      index:=Idx,
      receipt:=Rec,
      tx:=TxBody
     } ->
      Tx=#{from:=From}=tx:unpack(TxBody),
      [_,_,TxHash,Res,_Ret,Gas,BlkGas,Logs]=Rec,
      THash=hex:encodex(TxHash),
      BHash=hex:encodex(BlkHash),
      TIdx=i2hex(Idx),
      #{
        <<"blockHash">> => BHash,
        <<"blockNumber">> => i2hex(BlkHei),
        <<"contractAddress">> =>  null,
        <<"cumulativeGasUsed">> => i2hex(BlkGas),
        <<"effectiveGasPrice">> => i2hex(Gas),
        <<"from">> => hex:encodex(From),
        <<"gasUsed">> => i2hex(Gas),
        <<"logs">> =>
        lists:map(
          fun([<<"evm">>,To, _From, Data, Topics]) ->
              #{ address => hex:encodex(To),
                 topics => [ hex:encodex(T) || T <- Topics ],
                 data => hex:encodex(Data),
                 blockNumber => i2hex(BlkHei),
                 transactionHash => THash,
                 transactionIndex => TIdx,
                 blockHash => BHash,
                 logIndex => i2hex(1),
                 removed => false
               }
          end, Logs),
        <<"logsBloom">> =>  <<"0x">>,
        <<"status">> => i2hex(Res),
        <<"to">> => hex:encodex(maps:get(to,Tx,<<>>)),
        <<"transactionHash">> => THash,
        <<"transactionIndex">> => TIdx,
        <<"type">> =>  <<"0x2">>
       };
    Other ->
      ?LOG_ERROR("Other res ~p",[Other]),
      throw({jsonrpc2, 10001, <<"error">>})
  end;


handle(<<"eth_sendRawTransaction">>,[Tx]) ->
    ?LOG_INFO("Got req for eth_sendRawTransaction with ~p",[Tx]),
    #{hash:=Hash}=Decode=tx:construct_tx(#{tx=>hex:decode(Tx),
                             chain_id=>chain_id()
                            }),
    ?LOG_INFO("Got req for eth_sendRawTransaction with ~p",[Decode]),
    case txpool:new_tx(Decode) of
      {ok,TxID} ->
        ?LOG_INFO("TxID ~s hash ~s",[TxID, hex:encodex(Hash)]),
        hex:encodex(Hash);
      {error, Reason} ->
        throw({jsonrpc2, 10001, list_to_binary(io_lib:format("~p",[Reason]))})
    end;

handle(<<"eth_getTransactionCount">>,[Address, Block]) ->
    D=get_ledger(Address, seq, [], Block),
    ?LOG_INFO("Got req for eth_getTransactionCount for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{seq,[],S}] ->
            i2hex(S+1);
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

handle(<<"eth_estimateGas">>,[{Params}|_OptionalBlock]) ->
  %[{<<"from">>,<<"0xdda0e313ec6db199d1292ee536556ef3e1cadbab">>},{<<"value">>,<<"0x0">>},{<<"gasPrice">>,<<"0x1">>},{<<"data">>,<<"0x">>},{<<"to">>,<<"0xaa153647a1e5ec44f3407413e39996838d2cc032">>}]
    ?LOG_INFO("Got req for eth_call arg1 ~p",[Params]),
    %To=try
    %     decode_addr(proplists:get_value(<<"to">>,Params))
    %   catch error:function_clause ->
    %           throw({jsonrpc2, 32000, <<"missing trie node">>})
    %   end,
    %Data=hex:decode(proplists:get_value(<<"data">>,Params)),
    %From=decode_addr(proplists:get_value(<<"from">>,Params,null),null,<<0>>),
    %case tpnode_evmrun:evm_run(
    %       To,
    %       <<"0x0">>,
    %       [Data],
    %       #{caller=>From,
    %         gas=>hex2i(proplists:get_value(<<"gas">>,Params,<<"0x7D00">>)),
    %         block_height=>case Block of <<"latest">> -> undefined; _ -> hex2i(Block) end
    %        }
    %      ) of
    %    #{result:=revert, bin:=Bin}=_es ->
    %    ?LOG_INFO("Res revert"),
    %        throw({jsonrpc2, 32000, <<"execution reverted">>, hex:encodex(Bin)});
    %    #{bin:=Bin}=_es ->
    %    ?LOG_INFO("Res ok"),
    %        hex:encodex(Bin);
    %    _Err ->
    %    ?LOG_INFO("Res err: ~p",[_Err]),
    %        throw({jsonrpc2, 10000, <<"evm_run unexpected result">>})
    %end;
    i2hex(21000);

handle(<<"eth_call">>,[{Params},_Block]) ->
    ?LOG_INFO("Got req for eth_call arg1 ~p",[Params]),
    To=try
         decode_addr(proplists:get_value(<<"to">>,Params))
       catch error:function_clause ->
               throw({jsonrpc2, 32000, <<"missing trie node">>})
       end,
    Data=hex:decode(proplists:get_value(<<"data">>,Params)),
    From=decode_addr(proplists:get_value(<<"from">>,Params,null),null,<<0>>),
    S0=process_txs:new_state(fun mledger:getfun/2, mledger),
    case process_txs:process_itx(From,
                                 To,
                                 0,
                                 Data,
                                 2000000,
                                 S0#{cur_tx=>tx:construct_tx(
                                               #{ver=>2,
                                                 kind=>generic,
                                                 from=>From,
                                                 to=>To,
                                                 payload=>[],
                                                 seq=>1,
                                                 t=>erlang:system_time(second)})
                                    },
                                 []) of
      {1,RetData,_GasLeft,_} ->
        hex:encode(RetData);
      {0,RetData, _GasLeft, _} ->
        throw({jsonrpc2, 32000, <<"execution reverted">>, hex:encodex(RetData)});
      _Err ->
        ?LOG_INFO("Res err: ~p",[_Err]),
            throw({jsonrpc2, 10000, <<"evm_run unexpected result">>})
    end;

handle(<<"eth_call">>,_) ->
  ?LOG_INFO("err: eth_call"),
  throw({jsonrpc2, 32000, <<"incorrect arguments">>});

handle(<<"eth_getBlockByHash">>,[Hash|_Details]=Params) ->
  ?LOG_INFO("Got req for eth_getBlockByHash args ~p",[Params]),
  display_block(
    case Hash of
      <<"latest">> ->
        blockchain_reader:get_block(last_permanent);
      <<N/binary>> ->
        blockchain_reader:get_block(hex:decode(N), self)
    end);

handle(<<"eth_getBlockByNumber">>,[Number|_Details]=Params) ->
  ?LOG_INFO("Got req for eth_getBlockByNumber args ~p",[Params]),
  display_block(
    case Number of
      <<"0x",N/binary>> ->
        blockchain_reader:get_block(binary_to_integer(N,16));
      <<"latest">> ->
        blockchain_reader:get_block(last_permanent)
    end);

handle(<<"eth_getBalance">>,[<<Address/binary>>,Block,Token]) ->
    D=get_ledger_bal(Address, Block),
    ?LOG_INFO("Got req for eth_getBalance for token ~s address ~p blk ~p = ~p",[Token, Address, Block, D]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(Token,Map,0));
        [] ->
            i2hex(0)
    end;

handle(<<"eth_getBalance">>,[<<Address/binary>>,Block]) ->
    D=get_ledger_bal(Address, Block),
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
  ?LOG_INFO("Got req for eth_chainId = ~s / ~w",[i2hex(chain_id()),(chain_id())]),
  i2hex(chain_id());

handle(<<"eth_gasPrice">>,[]) ->
  try
    #{<<"gas">> := Gas,<<"tokens">> := Tokens}
    = mledger:getfun({lstore,<<0>>,[<<"gas">>,<<"SK">>]},mledger),
    ?LOG_INFO("eth_gasPrice ~p",[Tokens/Gas]),
    i2hex(trunc(Tokens/Gas))
  catch Ec:Ee ->
          ?LOG_INFO("eth_gasPrice error ~p:~p",[Ec,Ee]),
          i2hex(1)
  end;

handle(<<"eth_getLogs">>,[{PList}]) ->
    handle(<<"eth_getLogs">>,maps:from_list(PList));

handle(<<"eth_getLogs">>, #{<<"blockHash">>:=HexBlockHash}=Map) ->
  ?LOG_INFO("eth_getLogs"),
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
  ?LOG_INFO("eth_getLogs"),
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

handle(<<"eth_sendTransaction">>, [{Param}|_]) ->
  ?LOG_INFO("eth_sendTransaction ~p", [proplists:get_keys(Param)]),
  From=hex:decode(proplists:get_value(<<"from">>,Param,<<"0x">>)),
  Priv=lists:foldl(
         fun(Priv,undefined) ->
             P=hex:decode(Priv),
             {Addr,_,_}=eth:identity_from_private(P),
             ?LOG_INFO("From ~p and ~p",[Addr,From]),
             if(Addr==From) ->
                 P;
               true ->
                 undefined
             end;
            (_,Priv) ->
             Priv
         end, undefined,
         application:get_env(tpnode,eth_accounts,[])
        ),
  if(Priv==undefined) ->
      throw({jsonrpc2, -32042, <<"Bad from">>});
    is_binary(Priv) ->
      ok
  end,

  Tx=eth:encode_tx2(
       #{chain=>chain_id(),
         nonce=>seq(From),
         gasPrice=>100,
         gasLimit=>100000,
         to=>hex:decode(proplists:get_value(<<"to">>,Param,<<"0x">>)),
         value=>hex2i(proplists:get_value(<<"value">>,Param,<<"0x0">>)),
         data=>hex:decode(proplists:get_value(<<"data">>,Param,<<"0x">>))},
       Priv),

  #{hash:=Hash}=Decode=tx:construct_tx(#{tx=>Tx,
                                         chain_id=>chain_id()
                                        }),
  case txpool:new_tx(Decode) of
    {ok,TxID} ->
      ?LOG_INFO("TxID ~s hash ~s",[TxID, hex:encodex(Hash)]),
      hex:encodex(Hash);
    {error, Reason} ->
      throw({jsonrpc2, 10001, list_to_binary(io_lib:format("~p",[Reason]))})
  end;
  %throw({jsonrpc2, -32042, <<"Method not supported">>});

handle(<<"eth_accounts">>, _Params) ->
  ?LOG_INFO("eth_accounts ~p",[_Params]),
  %throw({jsonrpc2, -32042, <<"Method not supported">>});
  [ hex:encodex(element(1,eth:identity_from_private(hex:decode(X)))) ||
    X <- application:get_env(tpnode,eth_accounts,[])
  ];

handle(Method,_Params) ->
  ?LOG_INFO("err: ~s",[Method]),
    ?LOG_ERROR("Method ~s(~p) not found",[Method,_Params]),
    throw(method_not_found).

b2hex(B) when is_binary(B) ->
    <<"0x",(binary:encode_hex(B))/binary>>.

i2hex(I) when is_integer(I) ->
    <<"0x",(string:lowercase(integer_to_binary(I,16)))/binary>>.

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

get_ledger_bal(Address, Block) ->
  case get_ledger(Address, amount, [], Block) of
    [{amount,[],Map}] ->
      [{amount,[],Map}];
    [] ->
      case get_ledger(Address, balance, '_', Block) of
        [] ->
          [];
        List ->
          Map=lists:foldl(fun({balance,Token,Val},A) ->
                              maps:put(Token,Val,A)
                          end, #{}, List),
          [{amount,[],Map}]
      end
  end.

get_ledger(Address, Key, Path, <<"latest">>) ->
    mledger:get_kpvs(hex:decode(Address), Key, Path);
get_ledger(Address, Key, Path, Block) ->
    mledger:get_kpvs_height(hex:decode(Address), Key, Path, hex2i(Block)).

decode_addr(Null,Null,Dflt) ->
  Dflt;
decode_addr(A,_Null,_) ->
  decode_addr(A).

decode_addr(<<"0x000000000000000000000000",Addr:16/binary>>) ->
  hex:decode(Addr);
decode_addr(<<"0x",Addr:16/binary>>) ->
  hex:decode(Addr);
decode_addr(<<"0x",Addr:40/binary>>) ->
  hex:decode(Addr);
decode_addr(<<Addr:20/binary>>) ->
  naddress:decode(Addr).

chain_id() ->
  maps:get(chain,maps:get(header,blockchain:last_permanent_meta()))+1000000000.


display_block(not_found) ->
  throw(server_error);
display_block(#{hash:=Hash,header:=#{height:=Hei,parent:=Parent}=Hdr}=Block) ->
  Rec=maps:get(receipt,Block,[]),
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
    {<<"timestamp">>,i2hex(
                       binary:decode_unsigned(
                         proplists:get_value(mean_time,
                                             maps:get(roots,Hdr,[]),
                                             <<>>)))},
    {<<"transactions">>, [ hex:encodex(TxHash) || [_,_,TxHash|_] <- Rec ] },
    {<<"uncles">>,[]}
   ]}.

seq(Address) ->
  case mledger:db_get_one(mledger,Address,seq,[],[]) of
    {ok, V} -> V+1;
    undefined -> 0
  end.

