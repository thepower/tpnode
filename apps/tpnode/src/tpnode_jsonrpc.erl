-module(tpnode_jsonrpc).
-include("include/tplog.hrl").
-export([handle/2]).
-export([handle/3]).
-export([show_tx/1]).

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

handle(Command, Data, Context) ->
%  ?LOG_INFO("jsonrpc context ~p",[Context]),
  ?LOG_INFO("jsonrpc ~s ~p",[Command,Data]),
  h(Command, Data, Context).

handle(Command, Data) ->
  ?LOG_INFO("jsonrpc ~s ~p",[Command,Data]),
  h(Command, Data, #{}).

h(<<"net_version">>,[],_) ->
  %?LOG_INFO("Got req for net_version",[]),
  i2hex(chain_id());

h(<<"eth_getTransactionByHash">>,[TxHash0|_], _Context) ->
  %?LOG_INFO("Got req for eth_getTransactionByHash ~s",[TxHash0]),
  case
  gen_server:call(blockchain_reader,{txhash, hex:decode(TxHash0) ,true})
  of
    badarg ->
      throw({jsonrpc2, 10001, <<"badarg">>});
    not_found ->
      null;
    #{block:=BlkHash,
      hei:=BlkHei,
      hash:=TxHash,
      index:=Idx,
      receipt:=Rec,
      tx:=TxContainer
     } ->
      [_,TxID,TxHash,_Res,_Ret,_Gas,_BlkGas,_Logs|_]=Rec,
      Tx0=show_tx(tx:unpack(TxContainer)),
      THash=hex:encodex(TxHash),
      BHash=hex:encodex(BlkHash),
      TIdx=i2hex(Idx),
      Tx0#{
        <<"txID">> => TxID,
        <<"blockHash">> => BHash,
        <<"blockNumber">> => i2hex(BlkHei),
        <<"transactionIndex">> => TIdx,
        <<"hash">> => THash
       };
      Other ->
      ?LOG_ERROR("Other res ~p",[Other]),
      throw({jsonrpc2, 10001, <<"error">>})
  end;

h(<<"eth_getTransactionReceipt">>,[TxHash0], _Context) ->
  %?LOG_INFO("Got req for eth_getTransactionReceipt ~s",[TxHash0]),
  case
  gen_server:call(blockchain_reader,{txhash, hex:decode(TxHash0) ,true})
  of
    badarg ->
      throw({jsonrpc2, 10001, <<"badarg">>});
    not_found ->
      null;
    #{block:=BlkHash,
      hei:=BlkHei,
      hash:=TxHash,
      index:=Idx,
      receipt:=Rec,
      tx:=TxBody
     } ->
      Tx=#{kind:=Kind}=tx:unpack(TxBody),
      [_,TxID,TxHash,Res,Ret,Gas,BlkGas,Logs|BloomOrNot]=Rec,
      THash=hex:encodex(TxHash),
      BHash=hex:encodex(BlkHash),
      TIdx=i2hex(Idx),
      To0=maps:get(to,Tx,undefined),
      Bloom=case BloomOrNot of
              [] ->
                case Logs of
                  [] -> hex:encodex(<<0:2048/big>>);
                  [_|_] ->
                    Int=lists:foldl(
                          fun([<<"evm">>,_To1, From, _Data, Topics],Acc) ->
                              A1=eth_bloom:bloom_filter(From,Acc),
                              lists:foldl(fun eth_bloom:bloom_filter/2, A1, Topics);
                             ([<<"evm:",_Reason/binary>>,_To,_From,_],Acc) ->
                              Acc
                          end,
                          0,
                          Logs),
                    hex:encodex(<<Int:2048/big>>)
                end;
              [Yes] ->
                hex:encodex(Yes)
            end,

      #{
        <<"txID">> => TxID,
        <<"blockHash">> => BHash,
        <<"blockNumber">> => i2hex(BlkHei),
        <<"contractAddress">> => if Kind == deploy andalso Res==1 ->
                                      hex:encodex(Ret);
                                    Kind == ether andalso To0==<<>> ->
                                      hex:encodex(Ret);
                                    true ->
                                      null
                                 end,
        <<"return">> => hex:encodex(Ret),
        <<"cumulativeGasUsed">> => i2hex(BlkGas),
        <<"effectiveGasPrice">> => i2hex(Gas),
        <<"from">> => address:encode_ether(maps:get(from,Tx,<<0:160/big>>)),
        <<"gasUsed">> => i2hex(Gas),
        <<"logs">> =>
        lists:filtermap(
          fun([<<"evm">>,To1, _From, Data, Topics]) ->
              {true,
              #{ address => hex:encodex(To1),
                 topics => [ hex:encodex(<<(binary:decode_unsigned(T)):256/big>>) || T <- Topics ],
                 data => hex:encodex(Data),
                 blockNumber => i2hex(BlkHei),
                 transactionHash => THash,
                 transactionIndex => TIdx,
                 blockHash => BHash,
                 logIndex => i2hex(1),
                 removed => false
               }};
             ([<<"evm:",_Reason/binary>>,_To,_From,_]) ->
             false
          end, Logs),
        <<"logsBloom">> =>  Bloom,
        <<"status">> => i2hex(Res),
        <<"to">> => to_hex_or_null(maps:get(to,Tx,<<>>)),
        <<"transactionHash">> => THash,
        <<"transactionIndex">> => TIdx,
        <<"type">> =>  <<"0x2">>
       };
    Other ->
      ?LOG_ERROR("Other res ~p",[Other]),
      throw({jsonrpc2, 10001, <<"error">>})
  end;


h(<<"eth_sendRawTransaction">>,[Tx], _Context) ->
    %?LOG_INFO("Got req for eth_sendRawTransaction with ~p",[Tx]),
    #{hash:=Hash}=Decode=tx:construct_tx(#{tx=>hex:decode(Tx),
                             chain_id=>chain_id()
                            }),
    ?LOG_INFO("Got req for eth_sendRawTransaction with ~p",
              [maps:with( [kind,from,to,seq], Decode)]),
    case txpool:new_tx(Decode) of
      {ok,TxID} ->
        ?LOG_INFO("TxID ~s hash ~s",[TxID, hex:encodex(Hash)]),
        hex:encodex(Hash);
      {error, Reason} ->
        ?LOG_INFO("Err ~p",[Reason]),
        throw({jsonrpc2, 10001, list_to_binary(io_lib:format("~p",[Reason]))})
    end;

h(<<"eth_getTransactionCount">>,[Address, Block], _Context) ->
    D=get_ledger(Address, seq, [], Block),
    %?LOG_INFO("Got req for eth_getTransactionCount for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{seq,[],S}] ->
            i2hex(S+1);
        [] ->
            i2hex(0)
    end;

h(<<"eth_getStorageAt">>,[Address, Position, Block], _Context) ->
    D=get_ledger(Address, state, binary:encode_unsigned(hex2i(Position)), Block),
%    ?LOG_INFO("Got req for eth_getStorageAt for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{state,_,Value}] ->
            b2hex(Value);
        [] ->
            b2hex(<<>>)
    end;

h(<<"eth_getCode">>,[Address, Block], _Context) ->
    D=get_ledger(Address, code, [], Block),
%    ?LOG_INFO("Got req for eth_getCode for ~p/~p = ~p",[Address, Block, D]),
    case D of
        [{code,[],S}] ->
            b2hex(S);
        [] ->
            b2hex(<<>>)
    end;

h(<<"eth_estimateGas">>,[_Params,_Block,_Patched]=Params, _Context) ->
    PTX=eth_call(Params, _Context),
    case PTX of
      {1,_RetData,GasUsed,_} ->
        ?LOG_INFO("Ret ~w~n",[_RetData]),
        i2hex((GasUsed)+21000);
      {0,RetData, _GasLeft, _} ->
        throw({jsonrpc2, 32000, <<"execution reverted">>, hex:encodex(RetData)});
      _Err ->
        ?LOG_INFO("Res err: ~p",[size(_Err)]),
            throw({jsonrpc2, 10000, <<"evm_run unexpected result">>})
    end;

h(<<"eth_call">>,[_Params,_Block,_Patched]=Params, _Context) ->
  PTX=eth_call(Params, _Context),
  case PTX of
    {1,RetData,GasUsed,_} ->
      ?LOG_INFO("Gas burned ~w",[GasUsed]),
      hex:encodex(RetData);
    {0,RetData, _GasLeft, _} ->
      throw({jsonrpc2, 32000, <<"execution reverted">>, hex:encodex(RetData)});
    _Err ->
      ?LOG_INFO("Res err: ~p",[_Err]),
      throw({jsonrpc2, 10000, <<"evm_run unexpected result">>})
  end;

h(<<"eth_call">>,[{Params},_Block], _Context) ->
  h(<<"eth_call">>,[{Params},_Block,{[]}], _Context);

h(<<"eth_call">>,[{Params}], _Context) ->
  h(<<"eth_call">>,[{Params},<<"latest">>,{[]}], _Context);

h(<<"eth_call">>,_Args, _Context) ->
  ?LOG_INFO("err: eth_call ~p",[_Args]),
  throw({jsonrpc2, 32000, <<"incorrect arguments">>});

h(<<"eth_estimateGas">>,[{Params},_Block], _Context) ->
  h(<<"eth_estimateGas">>,[{Params},_Block,{[]}], _Context);

h(<<"eth_estimateGas">>,[{Params}], _Context) ->
  h(<<"eth_estimateGas">>,[{Params},<<"latest">>,{[]}], _Context);

h(<<"eth_estimateGas">>,_Args, _Context) ->
  ?LOG_INFO("err: eth_call ~p",[_Args]),
  throw({jsonrpc2, 32000, <<"incorrect arguments">>});

h(<<"eth_getBlockByHash">>,[Hash|Details], Context) ->
  display_block(
    case Hash of
      <<"latest">> ->
        blockchain_reader:get_block(last_permanent);
      <<N/binary>> ->
        blockchain_reader:get_block(hex:decode(N), self)
    end, Details, Context);

h(<<"eth_getBlockByNumber">>,[Number|Details], Context) ->
  display_block(
    case Number of
      <<"0x",N/binary>> ->
        blockchain_reader:get_block(binary_to_integer(N,16));
      <<"latest">> ->
        blockchain_reader:get_block(last_permanent)
    end, Details, Context);

h(<<"eth_getBalance">>,[<<Address/binary>>,Block,Token], _Context) ->
    D=get_ledger_bal(Address, Block),
    %?LOG_INFO("Got req for eth_getBalance for token ~s address ~p blk ~p = ~p",[Token, Address, Block, D]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(Token,Map,0));
        [] ->
            i2hex(0)
    end;

h(<<"eth_getBalance">>,[<<Address/binary>>,Block], _Context) ->
    D=get_ledger_bal(Address, Block),
    %?LOG_INFO("Got req for eth_getBalance for address ~p blk ~p = ~p",[Address, Block, D]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(<<"SK">>,Map,0));
        [] ->
            i2hex(0)
    end;

h(<<"eth_getBalance">>,[<<Address/binary>>], _Context) ->
    D=get_ledger_bal(Address,<<"latest">>),
    %?LOG_INFO("Got req for eth_getBalance for address ~p",[Address]),
    case D of
        [{amount,[],Map}] ->
            i2hex(maps:get(<<"SK">>,Map,0));
        [] ->
            i2hex(0)
    end;


h(<<"eth_blockNumber">>,_, _Context) ->
    LBHei=maps:get(height,maps:get(header,blockchain:last_permanent_meta())),
    i2hex(LBHei);

h(<<"eth_chainId">>,[], _Context) ->
  %?LOG_INFO("Got req for eth_chainId = ~s / ~w",[i2hex(chain_id()),(chain_id())]),
  i2hex(chain_id());

h(<<"eth_gasPrice">>,[], _Context) ->
  try
    #{<<"gas">> := Gas,<<"tokens">> := Tokens}
    = mledger:getfun({lstore,<<0>>,[<<"gas">>,<<"SK">>]},mledger),
    ?LOG_INFO("eth_gasPrice ~p",[Tokens/Gas]),
    i2hex(trunc(Tokens/Gas))
  catch Ec:Ee ->
          ?LOG_INFO("eth_gasPrice error ~p:~p",[Ec,Ee]),
          i2hex(1)
  end;

h(<<"eth_getLogs">>,[{PList}], _Context) ->
    handle(<<"eth_getLogs">>,maps:from_list(PList));

h(<<"eth_getLogs">>, #{<<"blockHash">>:=HexBlockHash}=Map, _Context) ->
  %?LOG_INFO("eth_getLogs"),
    %Address=proplists:get_value(<<"address">>,PList,<<>>),
    %FromBlock=proplists:get_value(<<"fromBlock">>,PList,<<>>),
    %ToBlock=proplists:get_value(<<"toBlock">>,PList,<<>>),
    BlockHash=hex2bin(HexBlockHash),
    Topics=[ hex2bin(T) || T <- maps:get(<<"topics">>,Map,[]) ],
    Addresses=[ hex2bin(A) || A <- maps:get(<<"address">>,Map,[]) ],
    Block=logs_db:get(BlockHash),
    logger:info("eth_getLogs ~p(~p)~n",[Topics,BlockHash]),
    process_log(Block,Topics,Addresses);

h(<<"eth_getLogs">>, #{}=Map, _Context) ->
  %?LOG_INFO("eth_getLogs"),
    #{header:=#{height:=LBH}}=blockchain:last_permanent_meta(),
    FromBlock=case maps:get(<<"fromBlock">>,Map,undefined) of
                  undefined -> LBH;
                  HexB -> hex2i(HexB)
              end,
    ToBlock=case maps:get(<<"toBlock">>,Map,undefined) of
              <<"latest">> -> LBH;
              undefined -> LBH;
              HexB1 -> hex2i(HexB1)
              end,
    logger:info("Request logs from ~w .. ~w",[FromBlock,ToBlock]),
    if(ToBlock<FromBlock) ->
          throw(invalid_params);
      true ->
          ok
    end,
    Topics=lists:map(
             fun(T) ->
                 I=binary:decode_unsigned(hex:decode(T)),
                 <<I:256/big>>
             end,
             case maps:get(<<"topics">>,Map,[]) of
               N when is_binary(N) ->
                 [N];
               N when is_list(N) ->
                 N
             end
            ),

    Addresses=lists:map(
                fun(T) ->
                    I=binary:decode_unsigned(hex:decode(T)),
                    binary:encode_unsigned(I)
                end,
                case maps:get(<<"address">>,Map,[]) of
                  N2 when is_binary(N2) ->
                    [N2];
                  N2 when is_list(N2) ->
                    N2
                end
               ),

    Res=search_log(Topics, Addresses, FromBlock, ToBlock, 20000),
    Res;

h(<<"eth_sendTransaction">>, [{Param}|_], _Context) ->
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

  #{<<"gas">> := Gas,<<"tokens">> := Tokens}
  = mledger:getfun({lstore,<<0>>,[<<"gas">>,<<"SK">>]},mledger),
  GasPrice=trunc(Tokens/Gas),

  Tx=eth:encode_tx2(
       #{chain=>chain_id(),
         nonce=>seq(From),
         gasPrice=>GasPrice,
         gasLimit=>hex2i(proplists:get_value(<<"gas">>,Param,<<"0xc350">>)),
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

h(<<"eth_accounts">>, _Params, _Context) ->
  ?LOG_INFO("eth_accounts ~p",[_Params]),
  %throw({jsonrpc2, -32042, <<"Method not supported">>});
  [ hex:encodex(element(1,eth:identity_from_private(hex:decode(X)))) ||
    X <- application:get_env(tpnode,eth_accounts,[])
  ];

h(Method,_Params, _Context) ->
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

process_log2(Receipts, BloomRequired, Filter, Addr, #{blockhash:=BHash, blocknumber:=BHei}) ->
  lists:filtermap(
    fun([TxNo,TxID,TxHash,Res,Ret,Gas,_Gas2,Logs|Other]) ->
        Allow=case Other of
                [] ->
                  true;
                [Bloom|_] ->
                  binary:decode_unsigned(Bloom) band BloomRequired == BloomRequired
              end,
        if Allow ->
             R1=lists:foldl(
                  fun([<<"evm">>, EFrom, To, Data,Topics],Acc) ->
                      [{[
                         {address,b2hex(EFrom)},
                         {blockHash, b2hex(BHash)},
                         {blockNumber, i2hex(BHei)},
                         {transactionId, TxID},
                         {transactionHash, b2hex(TxHash)},
                         {transactionIndex, i2hex(TxNo)},
                         {logIndex, i2hex(1)},
                         {data, b2hex(Data)},
                         {topics, [ b2hex(ET) || ET <- Topics]},
                         {removed, false}
                        ]}|Acc];
                     (_,Acc) ->
                      Acc
                  end,
                  [], Logs),
             if(R1==[]) ->
                 false;
               true ->
                 {true, R1}
             end;
           true ->
             false
        end;
       (_) ->
        false
    end,
    Receipts);

process_log2([],_Bloom,_Filter,_Addr,_) ->
    [].


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

get_ledger(Address, Key, Path, <<"pending">>) ->
  case hex:decode(Address) of
    <<0:96/big,Addr:8/binary>> ->
      mledger:get_kpvs(Addr, Key, Path);
    Addr ->
      mledger:get_kpvs(Addr, Key, Path)
  end;
get_ledger(Address, Key, Path, <<"latest">>) ->
  case hex:decode(Address) of
    <<0:96/big,Addr:8/binary>> ->
      mledger:get_kpvs(Addr, Key, Path);
    Addr ->
      mledger:get_kpvs(Addr, Key, Path)
  end;
get_ledger(Address, Key, Path, Block) ->
  case hex:decode(Address) of
    <<0:96/big,Addr:8/binary>> ->
      mledger:get_kpvs_height(Addr, Key, Path, hex2i(Block));
    Addr ->
      mledger:get_kpvs_height(Addr, Key, Path, hex2i(Block))
  end.

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


display_block(noblock, _, _) -> %this might come from rewind
  null;
display_block(not_found, _, _) ->
  null;
display_block(#{hash:=Hash,header:=#{height:=Hei,parent:=Parent}=Hdr}=Block, Details, Context) ->
  %Rec=maps:get(receipt,Block,[]),
  Roots=maps:get(roots,Hdr,[]),
  Miner = <<160,0,0,0,10,0,0,1>>,
  Txs=maps:get(txs,Block,[]),
  PWTx=case Context of
         #{<<"pwrtx">> := <<"1">>} -> true;
         _ -> false
       end,
  BlockHash=hex:encodex(Hash),
  BlockNumber=i2hex(Hei),
  {[
    {<<"baseFeePerGas">>,<<"0x0">>},
    {<<"difficulty">>,<<"0x2">>}, %QUANTITY
    {<<"totalDifficulty">>,<<"0x12">>}, %QUANTITY
    {<<"extraData">>,hex:encodex(<<"preved">>)}, %DATA
    {<<"gasLimit">>,<<"0x1c5502a">>}, %QUANTITY
    {<<"gasUsed">>,<<"0x79ccd3">>}, %QUANTITY
    {<<"logsBloom">>, %DATA, 256 Bytes - the bloom filter for the logs of the block. null when its pending block.
     hex:encodex(proplists:get_value(bloom,Roots,<<0:2048/big>>))},
    {<<"miner">>,address:encode_ether(Miner)}, %DATA, 20 Bytes
    {<<"nonce">>,<<"0x0000000000000001">>}, %DATA, 8 Bytes
    {<<"number">>,BlockNumber}, %QUANTITY - the block number. null when its pending block.
    {<<"hash">>,BlockHash}, %DATA, 32 Bytes - hash of the block. null when its pending block.
    {<<"mixHash">>,hex:encodex(<<1:256/big>>)},
    {<<"stateRoot">>,hex:encodex(proplists:get_value(ledger_hash,Roots,<<0:256/big>>))}, %DATA, 32 Bytes
    {<<"parentHash">>,hex:encodex(Parent)}, %DATA, 32 Bytes - hash of the parent block.
    {<<"transactionsRoot">>,hex:encodex(proplists:get_value(txroot,Roots,<<0:256/big>>))}, %DATA, 32 Bytes
    {<<"receiptsRoot">>,hex:encodex(proplists:get_value(receipt_root,Roots,<<0:256/big>>))}, %DATA, 32 Bytes
    {<<"sha3Uncles">>,hex:encodex(<<1:256/big>>)}, %DATA, 32 Bytes - SHA3 of the uncles
    {<<"size">>,<<"0x41c7">>}, %QUANTITY
    {<<"timestamp">>,i2hex( %QUANTITY
                       binary:decode_unsigned(
                         proplists:get_value(mean_time,Roots,<<>>)) div 1000)},
    %transactions Array - Array of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
    {<<"transactions">>,
     case Details of
       [true] ->
         Tx0=#{
           <<"blockHash">> => BlockHash,
           <<"blockNumber">> => BlockNumber
          },
         {Txs1,_}=lists:foldr(
           fun({<<"~afterBlock">>,_},A) ->
               A;
              %({_TxID,#{kind:=ether,body:=B}},A) ->
              % [ hex:encodex(B) | A ];
              ({TxID,#{kind:=Kind,body:=_,hash:=TxHash}=Tx},{A,N}) when PWTx orelse Kind==ether ->
              % [ hex:encodex(tx:pack(Tx)) | A ];
               {[maps:merge(Tx0#{<<"txID">> => TxID,
                                 <<"hash">> => hex:encodex(TxHash),
                                 <<"transactionIndex">> => i2hex(N) %TODO: FIX ME!!!
                                },show_tx(Tx)) | A ],N+1};
              (_,A) ->
               A
           end, {[],0}, Txs),
         Txs1;
       _ ->
         lists:foldr(
           fun
             ({<<"~afterBlock">>,_},A) ->
               A;
             ({_TxID,#{kind:=ether,hash:=H,body:=_}},A) ->
               [ hex:encodex(H) | A ];
              ({_TxID,#{kind:=_,hash:=H,body:=_}},A) ->
               case Context of
                 #{<<"pwrtx">> := <<"1">>} ->
                   [ hex:encodex(H) | A ];
                 _ ->
                   A
               end
           end, [], Txs)
         %[ hex:encodex(TxHash) || [_,_,TxHash|_] <- Rec ]
     end},
    {<<"uncles">>,[]}
   ]}.

seq(Address) ->
  case mledger:db_get_one(mledger,Address,seq,[],[]) of
    {ok, V} -> V+1;
    undefined -> 0
  end.

to_hex_or_null(<<>>) -> null;
to_hex_or_null(Bin) ->
  address:encode_ether(Bin).

show_tx(#{chain_id:=CID, body:=TxBody}) ->
  Tx0=maps:from_list(
        lists:filtermap(
          fun({K,V}) when is_integer(V) ->
              {true,{atom_to_binary(K,utf8),i2hex(V)}};
             ({to,V}) ->
              {true,{<<"to">>,to_hex_or_null(V)}};
             ({v,<<>>}) ->
              {true,{<<"v">>,<<"0x0">>}};
             ({v,<<0>>}) ->
              {true,{<<"v">>,<<"0x0">>}};
             ({v,<<1>>}) ->
              {true,{<<"v">>,<<"0x1">>}};
             ({pubkey,V}) when is_binary(V) ->
              {true,{<<"publicKey">>,hex:encodex(V)}};
             ({K,V}) when is_binary(V) ->
              {true,{atom_to_binary(K,utf8),hex:encodex(V)}};
             (_) ->
              false end,
          eth:decode_tx(CID,TxBody) )),
  %      #{
  %       "gas": "0xf478",
  %       "yParity": "0x1"
  %      }

  Tx0;

show_tx(#{kind:=_,from:=From,seq:=Nonce}=Tx) ->
  %  <<"txID">> => TxID,
  %  <<"blockHash">> => hex:encodex(BlkHash),
  %  <<"blockNumber">> => i2hex(BlkHei),
  %  <<"transactionIndex">> => i2hex(Idx),
  %  <<"hash">> => hex:encodex(TxHash),

  #{
    <<"from">> => address:encode_ether(From),
    <<"gas">> => case tx:get_payload(Tx,gas) of %TODO: fixme, calculate gas amount
                   #{amount := N,cur := <<"SK">>} ->
                     i2hex(N);
                   _ ->
                     i2hex(0)
                 end,
    <<"gasPrice">> => i2hex(100),
    <<"input">> => hex:encodex(contract_evm:tx_cd(Tx)),
    <<"nonce">> => i2hex(Nonce),
    <<"to">> => to_hex_or_null(maps:get(to,Tx,null)),
    <<"value">> => case tx:get_payload(Tx,transfer) of %TODO: fixme, calculate gas amount
                     #{amount := N,cur := <<"SK">>} ->
                       i2hex(N);
                     _ ->
                       i2hex(0)
                   end,
    <<"v">> => i2hex(1),
    <<"r">> => i2hex(1),
    <<"s">> => i2hex(1)
   }.

eth_call([{Params},_Block,_Patched], _Context) ->
    To=decode_addr(proplists:get_value(<<"to">>,Params,null),null,<<>>),
    Data=hex:decode(proplists:get_value(<<"data">>,Params)),
    From=decode_addr(proplists:get_value(<<"from">>,Params,null),null,<<0>>),
    S0=process_txs:new_state(fun mledger:getfun/2, mledger),
    Gas=2000000,
    R0=case To of
      <<>> -> %deploy
        Tx=tx:construct_tx(#{from=>From,
                             seq=>1,
                             kind=>deploy,
                             txext=>#{
                                      "code"=>Data,
                                      "vm"=>"evm"
                                     },
                             ver=>2,
                             t=>0,
                             payload=>[]
                            }),
        process_txs:process_tx(Tx, Gas, S0#{cur_tx=>Tx},#{});
      _ -> %generic
        Tx=tx:construct_tx(
             #{ver=>2,
               kind=>generic,
               from=>From,
               to=>To,
               payload=>[],
               seq=>1,
               t=>erlang:system_time(second)}),
        process_txs:process_itx(From,
                                To,
                                0,
                                Data,
                                Gas,
                                S0#{cur_tx=>Tx},
                                [])
    end,
    case R0 of
      {Code,RetData,GasLeft,S1} ->
        {Code,RetData,Gas-GasLeft,S1};
      Any -> Any
    end.

search_log(Topics, Addresses, FromBlock, ToBlock, MaxCnt) ->
  T0=erlang:system_time(millisecond),
  BloomRequired=lists:foldl(fun eth_bloom:bloom_filter/2, 0, Topics++Addresses),
  {_,Res}=lists:foldl(
            fun
              (_,{Cnt,_}) when Cnt>MaxCnt ->
                throw({jsonrpc2, 32005, <<"query returned too much results">>});
              (Number,{Cnt,Acc}) ->
                T1=erlang:system_time(millisecond),
                if(T1-T0) > 10000 ->
                    throw({jsonrpc2, 32005, <<"query timeout exceeded">>});
                  true -> ok
                end,
                case blockchain_reader:get_block(Number) of
                  #{header:=Hdr,receipt:=Reciept,hash:=Hash} ->
                    Match=case proplists:get_value(<<"bloom">>,maps:get(roots,Hdr)) of
                            undefined -> true;
                            X when is_binary(X) ->
                              binary:decode_unsigned(X) band BloomRequired == BloomRequired
                          end,
                    if Match ->
                         Logs=process_log2(Reciept, BloomRequired, Topics, Addresses,
                                           #{
                                             blockhash=>Hash,
                                             blocknumber=>maps:get(height,Hdr)
                                            }),
                         NC=length(Acc),
                         {Cnt+NC, Acc++Logs};
                       true ->
                         {Cnt,Acc}
                    end;
                  _ ->
                    {Cnt,Acc}
                end

            end, {0,[]}, lists:seq(FromBlock,ToBlock)),
  Res.
