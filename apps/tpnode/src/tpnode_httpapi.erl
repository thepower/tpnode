-module(tpnode_httpapi).

-export([h/3, after_filter/1,
         prettify_block/2,
         prettify_block/1,
         prettify_bal/2,
         prettify_tx/2,
         postbatch/1,
         packer/2,
         binjson/1]).

-export([answer/0, answer/1, answer/2, err/1, err/2, err/3, err/4]).


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.



add_address(Address, Map1) ->
    HexAddress = <<"0x",(hex:encode(Address))/binary>>,
    TxtAddress = naddress:encode(Address),

    maps:merge(Map1, #{
        <<"address">> => HexAddress,
        <<"txtaddress">> => TxtAddress
    }).


err(ErrorCode) ->
    err(ErrorCode, <<"">>, #{}, #{}).

err(ErrorCode, ErrorMessage) ->
    err(ErrorCode, ErrorMessage, #{}, #{}).

err(ErrorCode, ErrorMessage, Data) ->
    err(ErrorCode, ErrorMessage, Data, #{}).

err(ErrorCode, ErrorMessage, Data, Options) ->
    Required0 =
        #{
            <<"ok">> => false,
            <<"code">> => ErrorCode,
            <<"msg">> => ErrorMessage
        },

    % add address if it exists
    Required1 = case maps:is_key(address, Options) of
        true ->
            add_address(
                maps:get(address, Options),
                Required0
            );
        _ ->
            Required0
    end,
    {
        maps:get(http_code, Options, 200),
        maps:merge(Data, Required1)
    }.

answer() ->
    answer(#{}).

answer(Data) ->
    answer(Data, #{}).

answer(Data, Options) when is_map(Data) ->
  Data1 =
  case maps:is_key(address, Options) of
    true ->
      add_address(
        maps:get(address, Options),
        Data
       );
    _ ->
      Data
  end,
  Data2=maps:put(<<"ok">>, true, Data1),
  MS=maps:with([jsx,msgpack],Options),
  case(maps:size(MS)>0) of
    true ->
      {
       200,
       {Data2,MS}
      };
    false ->
      {
       200,
       Data2
      }
  end.



after_filter(Req) ->
  Origin=cowboy_req:header(<<"origin">>, Req, <<"*">>),
  Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                  Origin, Req),
  Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                  <<"GET, POST, OPTIONS">>, Req1),
%  Req3=cowboy_req:set_resp_header(<<"access-control-allow-credentials">>,
%                                  <<"true">>, Req2),
  Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                  <<"86400">>, Req2),
  Req5=cowboy_req:set_resp_header(<<"tpnode-name">>, nodekey:node_name(), Req4),
  Req6=cowboy_req:set_resp_header(<<"tpnode-id">>, nodekey:node_id(), Req5),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                             <<"content-type">>, Req6).

h(Method, [<<"playground">>|Path], Req) ->
  httpapi_playground:h(Method, Path, Req);

h(Method, [<<"api">>|Path], Req) ->
  h(Method, Path, Req);

h(<<"GET">>, [<<"node">>, <<"status">>], _Req) ->
%  {Chain, Hash, Header1} = case catch gen_server:call(blockchain, status) of
%                             {A, B, C} -> {A, B, C};
%                             _Err ->
%                               lager:info("Error ~p", [_Err]),
%                               {-1, <<0, 0, 0, 0, 0, 0, 0, 0>>, #{}}
%                           end,
  Chain=chainsettings:get_val(mychain),
  #{hash:=Hash,
    header:=Header1}=Blk=blockchain:last_meta(),
  Temp=maps:get(temporary,Blk,false),
  BinPacker=packer(_Req,hex),
  Header=maps:map(
           fun(roots, V) ->
               [ if is_binary(RV) ->
                      {N, BinPacker(RV)};
                   true ->
                      {N, RV}
                 end || {N,RV} <- V ];
              (_, V) when is_binary(V) -> BinPacker(V);
              (_, V) -> V
           end, Header1),
  Peers=lists:map(
          fun(#{addr:=_Addr, auth:=Auth, state:=Sta, authdata:=AD}) ->
              #{auth=>Auth,
                state=>Sta,
                node=>proplists:get_value(nodeid, AD, null)
               };
             (#{addr:=_Addr}) ->
              #{auth=>unknown,
                state=>unknown
               }
          end, tpic:peers()),
  SynPeers=gen_server:call(synchronizer, peers),
  {Ver, _BuildTime}=tpnode:ver(),
  answer(
    #{ result => <<"ok">>,
      status => #{
        nodeid=>nodekey:node_id(),
        nodename=>nodekey:node_name(),
        public_key=>BinPacker(nodekey:get_pub()),
        blockchain=>#{
          chain=>Chain,
          hash=>BinPacker(Hash),
          header=>Header,
          temporary=>Temp
         },
        xchain_inbound => try
                            gen_server:call(xchain_dispatcher, peers)
                          catch _:_ -> #{ error => true }
                          end,
        xchain_outbound => try
                             gen_server:call(xchain_client, peers)
                           catch _:_ -> #{ error => true }
                           end,
        tpic_peers=>Peers,
        sync_peers=>SynPeers,
        ver=>list_to_binary(Ver)
       }
    });

h(<<"GET">>, [<<"contract">>, TAddr, <<"call">>, Method | Args], _Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> ->
             hex:parse(Hex);
           _ ->
             naddress:decode(TAddr)
         end,
    Ledger=ledger:get([Addr]),
    case maps:is_key(Addr, Ledger) of
      false ->
          err(
              10011,
              <<"Not found">>,
              #{ result => <<"not_found">> }
              #{ address => Addr, http_code => 404 }
          );
      true ->
        Info=maps:get(Addr, Ledger),
        VMName=maps:get(vm, Info),
        {ok,List}=smartcontract:get(VMName,Method,Args,Info),
        answer(
           #{result => List},
           #{address => Addr}
        )
    end
  catch throw:{error, address_crc} ->
      err(
          10012,
          <<"Invalid address">>,
          #{
              result => <<"error">>,
              error => <<"invalid address">>
          }
      )
  end;

h(<<"GET">>, [<<"contract">>, TAddr], _Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> ->
             hex:parse(Hex);
           _ ->
             naddress:decode(TAddr)
         end,
    Ledger=ledger:get([Addr]),
    case maps:is_key(Addr, Ledger) of
      false ->
          err(
              10009,
              <<"Not found">>,
              #{ result => <<"not_found">> }
              #{ address => Addr, http_code => 404 }
          );
      true ->
        Info=maps:get(Addr, Ledger),
        VMName=maps:get(vm, Info),
        {ok,CN,CD}=smartcontract:info(VMName),
        {ok,List}=smartcontract:getters(VMName),

        answer(
         #{
            contract=>CN,
            descr=>CD,
            getters=>List
          },
          #{ address => Addr })
    end
  catch throw:{error, address_crc} ->
      err(
          10010,
          <<"Invalid address">>,
          #{
              result => <<"error">>,
              error => <<"invalid address">>
          }
      )
  end;

h(<<"GET">>, [<<"where">>, TAddr], _Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> ->
             hex:parse(Hex);
           _ ->
             naddress:decode(TAddr)
         end,
    #{block:=Blk}=naddress:parse(Addr),
    MyChain=blockchain:chain(),
    if
        (MyChain == Blk) ->
            case ledger:get(Addr) of
                not_found ->
                    err(
                        10000,
                        <<"Not found">>,
                        #{result=><<"not_found">>},
                        #{address => Addr, http_code => 404}
                    );
                #{} ->
                    answer(
                        #{
                            result => <<"found">>,
                            chain => Blk,
                            chain_nodes => get_nodes(Blk)
                        },
                        #{address => Addr}
                    )
            end;
        true ->
            answer(
                #{
                    result => <<"other_chain">>,
                    chain => Blk,
                    chain_nodes => get_nodes(Blk)
                },
                #{ address => Addr }
            )
    end
  catch throw:{error, address_crc} ->
          err(
              10001,
              <<"Invalid address">>,
              #{ result => <<"error">>, error=> <<"invalid address">>},
              #{http_code => 400}
          );
        throw:bad_addr ->
            err(
                10002,
                <<"Invalid address (2)">>,
                #{result => <<"error">>, error=> <<"invalid address">>},
                #{http_code => 400}
            )
  end;

h(<<"GET">>, [<<"nodes">>, Chain], _Req) ->
    answer(#{
        chain_nodes => get_nodes(binary_to_integer(Chain, 10))
    });

h(<<"GET">>, [<<"address">>, TAddr, <<"state",F/binary>>|Path], _Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> -> hex:parse(Hex);
           _ -> naddress:decode(TAddr)
         end,
    Ledger=ledger:get([Addr]),
    case maps:is_key(Addr, Ledger) of
      false ->
          err(
              10003,
              <<"Not found">>,
              #{result => <<"not_found">>},
              #{http_code => 404}
          );
      true ->
        Info=maps:get(Addr, Ledger),
        State=maps:get(state, Info, <<>>),
        case Path of
          [] ->
            lager:info("F ~p",[F]),
            case F of <<>> ->
                        {200, [{"Content-Type","binary/octet-stream"}], State};
                      <<"json">> ->
                        {ok,S}=msgpack:unpack(State),
                        S1=maps:fold(
                          fun(K,V,Acc) ->
                              maps:put(
                                base64:encode(K),
                                base64:encode(V),
                                Acc)
                          end, #{
                            notice => <<"Only for Sasha">>
                           }, S),
                        {200, [{"Content-Type","application/json"}], S1}
            end;
          [Key] ->
            K=case Key of
                   <<"0x", HexK/binary>> -> hex:parse(HexK);
                   _ -> base64:decode(Key)
                 end,
            {ok,S}=msgpack:unpack(State),
            Val=maps:get(K,S,<<>>),
            {200, [{"Content-Type","binary/octet-stream"}], Val}
        end
    end
  catch
    throw:{error, address_crc} ->
              err(
                  10004,
                  <<"Invalid address">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              );
          throw:bad_addr ->
              err(
                  10005,
                  <<"Invalid address (2)">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              )
  end;


h(<<"GET">>, [<<"address">>, TAddr, <<"code">>], _Req) ->
  try
    Addr=case TAddr of
           <<"0x", Hex/binary>> -> hex:parse(Hex);
           _ -> naddress:decode(TAddr)
         end,
    Ledger=ledger:get([Addr]),
    case maps:is_key(Addr, Ledger) of
      false ->
          err(
              10003,
              <<"Not found">>,
              #{result => <<"not_found">>},
              #{http_code => 404}
          );
      true ->
        Info=maps:get(Addr, Ledger),
        Code=maps:get(code, Info, <<>>),
        {200, [{"Content-Type","binary/octet-stream"}], Code}
    end
  catch
    throw:{error, address_crc} ->
              err(
                  10004,
                  <<"Invalid address">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              );
          throw:bad_addr ->
              err(
                  10005,
                  <<"Invalid address (2)">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              )
  end;


h(<<"GET">>, [<<"address">>, TAddr], _Req) ->
  QS=cowboy_req:parse_qs(_Req),
  try
    BinPacker=packer(_Req,hex),
    Addr=case TAddr of
           <<"0x", Hex/binary>> ->
             hex:parse(Hex);
           _ ->
             naddress:decode(TAddr)
         end,
    Ledger=ledger:get([Addr]),
    case maps:is_key(Addr, Ledger) of
      false ->
          err(
              10003,
              <<"Not found">>,
              #{result => <<"not_found">>},
              #{http_code => 404}
          );
      true ->
        Info=maps:get(Addr, Ledger),
        InfoL=case maps:is_key(lastblk, Info) of
                false ->
                  #{};
                true ->
                  LastBlk=maps:get(lastblk, Info),
                  #{preblk=>LastBlk}
              end,
        InfoU=case maps:is_key(ublk, Info) of
                false ->
                  InfoL;
                true ->
                  UBlk=maps:get(ublk, Info),
                  InfoL#{lastblk=>UBlk}
              end,
        Info1=maps:merge(maps:remove(ublk, Info), InfoU),
        Info2=maps:map(
                fun
                  (lastblk, V) -> BinPacker(V);
      (ublk, V) -> BinPacker(V);
      (pubkey, V) ->
                    case proplists:get_value(<<"pubkey">>, QS) of
                      <<"b64">> -> base64:encode(V);
                      <<"pem">> -> tpecdsa:export(V,pem);
                      <<"raw">> -> V;
                      _ -> BinPacker(V)
                    end;
      (preblk, V) -> BinPacker(V);
      (view, View) ->
                    [ list_to_binary(M) || M<- View];
      (code, V) -> size(V);
      (state, V) -> size(V);
      (_, V) -> V
                end, Info1),
        Info3=try
                Contract=maps:get(vm, Info2),
                lager:error("C1 ~p",[Contract]),
                CV=smartcontract:info(Contract),
                lager:error("C2 ~p",[CV]),
                {ok, VN, VD} = CV,
                maps:put(contract, [VN,VD], Info2)
              catch _:_ ->
%%                      lager:error("NC"),
                      Info2
              end,

        answer(
         #{ result => <<"ok">>,
            info=>Info3
          },
         #{address => Addr}
        )
    end
  catch throw:{error, address_crc} ->
              err(
                  10004,
                  <<"Invalid address">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              );
          throw:bad_addr ->
              err(
                  10005,
                  <<"Invalid address (2)">>,
                  #{result => <<"error">>},
                  #{http_code => 400}
              )
  end;

h(<<"GET">>, [<<"blockinfo">>, BlockId], _Req) ->
  BinPacker=packer(_Req,hex),
  BlockHash0=if(BlockId == <<"last">>) -> last;
               true ->
                 hex:parse(BlockId)
             end,
  case gen_server:call(blockchain, {get_block, BlockHash0}) of
    undefined ->
        err(
            1,
            <<"Not found">>,
            #{result => <<"not_found">>},
            #{http_code => 404}
        );
    #{txs:=Txl}=GoodBlock ->
      ReadyBlock=maps:put(
                   txs_count,
                   length(Txl),
                   maps:without([txs,bals],GoodBlock)
                  ),
      Block=prettify_block(ReadyBlock, BinPacker),
      answer(
       #{ result => <<"ok">>,
          block => Block
        })
  end;

h(<<"GET">>, [<<"binblock">>, BlockId], _Req) ->
  BlockHash0=if(BlockId == <<"last">>) -> last;
               true -> hex:parse(BlockId)
             end,
  case gen_server:call(blockchain, {get_block, BlockHash0}) of
    undefined ->
        err(
            10006,
            <<"Not found">>,
            #{result => <<"not_found">>},
            #{http_code => 404}
        );
    GoodBlock ->
      {200,
       [{<<"content-type">>,<<"binary/tp-block">>}],
       block:pack(GoodBlock)
      }
  end;

h(<<"GET">>, [<<"txtblock">>, BlockId], _Req) ->
  BlockHash0=if(BlockId == <<"last">>) -> last;
               true -> hex:parse(BlockId)
             end,
  case gen_server:call(blockchain, {get_block, BlockHash0}) of
    undefined ->
        err(
            10006,
            <<"Not found">>,
            #{result => <<"not_found">>},
            #{http_code => 404}
        );
    GoodBlock ->
      {200,
       [{<<"content-type">>,<<"text/plain">>}],
       iolist_to_binary(
         io_lib:format("~p.~n",[GoodBlock])
        )
      }
  end;

h(<<"GET">>, [<<"block">>, BlockId], _Req) ->
  QS=cowboy_req:parse_qs(_Req),
  BinPacker=packer(_Req,hex),
  Address=case proplists:get_value(<<"addr">>, QS) of
            undefined -> undefined;
            Addr -> naddress:decode(Addr)
          end,

  BlockHash0=if(BlockId == <<"last">>) -> last;
               true ->
                 hex:parse(BlockId)
             end,
  case gen_server:call(blockchain, {get_block, BlockHash0}) of
    undefined ->
        err(
            10006,
            <<"Not found">>,
            #{result => <<"not_found">>},
            #{http_code => 404}
        );
    GoodBlock ->
      ReadyBlock=if Address == undefined ->
                      GoodBlock;
                    is_binary(Address) ->
                      filter_block(
                        GoodBlock,
                        Address)
                 end,
      Block=prettify_block(ReadyBlock, BinPacker),
      EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
              Conf1=jsx_config:list_to_config(Conf),
              jsx_parser:resume([{Type, BinPacker(Str)}|Tokens],
                                State, Handler, Stack, Conf1)
          end,
      answer(
        #{ result => <<"ok">>,
           block => Block
         },
        #{jsx=>[ strict, {error_handler, EHF} ]}
       )
  end;

h(<<"GET">>, [<<"settings">>], _Req) ->
  Settings=settings:clean_meta(chainsettings:by_path([])),
  EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
          Conf1=jsx_config:list_to_config(Conf),
          jsx_parser:resume([{Type, base64:encode(Str)}|Tokens],
                            State, Handler, Stack, Conf1)
      end,
  answer(
    #{ result => <<"ok">>,
       settings => Settings
     },
    #{jsx=>[ strict, {error_handler, EHF} ]}
   );

h(<<"POST">>, [<<"register">>], Req) ->
  {_RemoteIP, _Port}=cowboy_req:peer(Req),
  Body=apixiom:bodyjs(Req),
  PKey=case maps:get(<<"public_key">>, Body) of
         <<"0x", BArr/binary>> ->
           hex:parse(BArr);
         Any ->
           base64:decode(Any)
       end,

  BinTx=tx:pack( #{ type=>register,
                    register=>PKey,
                    pow=>maps:get(<<"pow">>,Body,<<>>),
                    timestamp=>maps:get(<<"timestamp">>,Body,0)
                  }),

  case txpool:new_tx(BinTx) of
    {ok, Tx} ->
      answer(
       #{ result => <<"ok">>,
          notice => <<"method deprecated">>,
          pkey=>bin2hex:dbin2hex(PKey),
          txid => Tx
        }
      );
    {error, Err} ->
      lager:info("error ~p", [Err]),
      ErrorMsg = iolist_to_binary(io_lib:format("bad_tx:~p", [Err])),
      Data =
       #{ result => <<"error">>,
          notice => <<"method deprecated">>,
          pkey=>bin2hex:dbin2hex(PKey),
          tx=>base64:encode(BinTx),
          error => ErrorMsg
        },
      err(
          10007,
          ErrorMsg,
          Data,
          #{http_code=>500}
      )
  end;

h(<<"GET">>, [<<"tx">>, <<"status">>, TxID], _Req) ->
  R=txstatus:get_json(TxID),
  answer(#{res=>R});

h(<<"POST">>, [<<"tx">>, <<"batch">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  lager:debug("New batch from ~s", [inet:ntoa(RemoteIP)]),
  {ok, ReqBody, _NewReq} = cowboy_req:read_body(Req),
  R=postbatch(ReqBody),
  answer(
    #{ result => <<"ok">>,
       reslist => R
     }
   );

h(<<"POST">>, [<<"tx">>, <<"new">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  Body=apixiom:bodyjs(Req),
  lager:debug("New tx from ~s: ~p", [inet:ntoa(RemoteIP), Body]),
  BinTx=if Body == undefined ->
             {ok, ReqBody, _NewReq} = cowboy_req:read_body(Req),
             ReqBody;
           is_map(Body) ->
             case maps:get(<<"tx">>, Body, undefined) of
               <<"0x", BArr/binary>> ->
                 hex:parse(BArr);
               Any ->
                 base64:decode(Any)
             end
        end,
  %lager:info_unsafe("New tx ~p", [BinTx]),
  case txpool:new_tx(BinTx) of
    {ok, Tx} ->
      answer(
       #{ result => <<"ok">>,
          txid => Tx
        }
      );
    {error, Err} ->
      lager:info("error ~p", [Err]),
      err(
          10008,
          iolist_to_binary(io_lib:format("bad_tx:~p", [Err])),
          #{},
          #{http_code=>500}
      )
  end;

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};

h(_Method, [<<"status">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  lager:info("Join from ~p", [inet:ntoa(RemoteIP)]),
  %Body=apixiom:bodyjs(Req),

  answer( #{ client => list_to_binary(inet:ntoa(RemoteIP)) }).

%PRIVATE API

% ----------------------------------------------------------------------

filter_block(Block, Address) ->
  maps:map(
    fun(bals, B) ->
        maps:with([Address], B);
       (txs, B) ->
        [ {TxID, TX} || {TxID, #{from:=F, to:=T}=TX} <- B, F==Address orelse T==Address ];
       (_, V) -> V
    end, Block).

% ----------------------------------------------------------------------

prettify_bal(V, BinPacker) ->
  FixedBal=case maps:is_key(lastblk, V) of
             false ->
               maps:remove(ublk, V);
             true ->
               LastBlk=maps:get(lastblk, V),
               maps:put(lastblk,
                        BinPacker(LastBlk),
                        maps:remove(ublk, V)
                       )
           end,
  maps:map(
    fun(pubkey, PubKey) ->
        BinPacker(PubKey);
       (state, PubKey) ->
        BinPacker(PubKey);
       (view, View) ->
        [ list_to_binary(M) || M<- View];
       (code, PubKey) ->
        BinPacker(PubKey);
       (_BalKey, BalVal) ->
        BalVal
    end, FixedBal).

prettify_block(Block) ->
  prettify_block(Block, fun(Bin) -> bin2hex:dbin2hex(Bin) end).

prettify_block(#{}=Block0, BinPacker) ->
  maps:map(
    fun(sign, Signs) ->
        show_signs(Signs, BinPacker, true);
       (hash, BlockHash) ->
        BinPacker(BlockHash);
       (child, BlockHash) ->
        BinPacker(BlockHash);
       (bals, Bal) ->
        maps:fold(
          fun(BalAddr, V, A) ->
              PrettyBal=prettify_bal(V,BinPacker),
              maps:put(BinPacker(BalAddr), PrettyBal, A)
          end, #{}, Bal);
       (header, BlockHeader) ->
        maps:map(
          fun(parent, V) ->
              BinPacker(V);
             (_K, V) when is_binary(V) andalso size(V) == 32 ->
              BinPacker(V);
             (_K, V) ->
              V
          end, BlockHeader);
       (settings, Settings) ->
        lists:map(
          fun({CHdr, CBody}) ->
              %DMP=settings:dmp(CBody),
              %DMP=base64:encode(CBody),
              {CHdr, maps:map(
                       fun(patch, Payload) ->
                           settings:dmp(Payload);
                          (signatures, Sigs) ->
                           show_signs(Sigs, BinPacker, true);
                          (_K, V) -> V
                       end, CBody)}
          end,
          Settings
         );
       (inbound_blocks, IBlocks) ->
        lists:map(
          fun({BHdr, BBody}) ->
              {BHdr,
               prettify_block(BBody, BinPacker)
              }
          end,
          IBlocks
         );

       (tx_proof, Proof) ->
        lists:map(
          fun({CHdr, CBody}) ->
              {CHdr, prettify_mproof(CBody,BinPacker)}
          end,
          Proof
         );
       (txs, TXS) ->
        lists:map(
          fun({TxID, Body}) ->
              {TxID,prettify_tx(Body, BinPacker)}
          end, TXS);
       (_, V) ->
        V
    end, Block0);

prettify_block(#{hash:=<<0, 0, 0, 0, 0, 0, 0, 0>>}=Block0, BinPacker) ->
  Block0#{ hash=>BinPacker(<<0:64/big>>) }.

prettify_mproof(M, BinPacker) ->
  lists:map(
    fun(E) when is_binary(E) -> BinPacker(E);
       (E) when is_tuple(E) -> prettify_mproof(E, BinPacker);
       (E) when is_list(E) -> prettify_mproof(E, BinPacker)
    end,
    if is_tuple(M) ->
         tuple_to_list(M);
       is_list(M) ->
         M
    end).

% ----------------------------------------------------------------------
str2bin(List) when is_list(List) ->
  unicode:characters_to_binary(List).

prettify_tx(#{ver:=2}=TXB, BinPacker) ->
  maps:map(
    fun(from, <<Val:8/binary>>) ->
        BinPacker(Val);
       (to, <<Val:8/binary>>) ->
        BinPacker(Val);
       (body, Val) ->
        BinPacker(Val);
       (keysh, Val) ->
        BinPacker(Val);
       (call, Val) ->
         Bin=msgpack:pack(Val),
         {ok, R}=msgpack:unpack(Bin,[{spec,new},{unpack_str, as_binary}]),
         R;
       (sigverify, Fields) ->
        maps:map(
          fun(pubkeys, Val) ->
              [ BinPacker(Sig) || Sig <- Val ];
             (_,Val) ->
              Val
          end, Fields);
       (extdata, V1) ->
        maps:fold(
          fun(<<"addr">>,V2,Acc) ->
              [{<<"addr.txt">>,naddress:encode(V2)},
               {<<"addr">>,BinPacker(V2)} |Acc];
              (K2,V2,Acc) ->
              [{K2,V2}|Acc]
          end, [], V1);
       (txext, <<>>) -> %TODO: remove this temporary fix
        #{};
       (txext, V1) ->
        maps:fold(
          fun(K2,V2,Acc) when is_list(K2), is_list(V2) ->
              [{str2bin(K2),str2bin(V2)}|Acc];
             (K2,V2,Acc) when is_list(K2) ->
              [{str2bin(K2),V2}|Acc];
              (K2,V2,Acc) when is_binary(K2) ->
              [{K2,V2}|Acc]
          end, [], V1);
       (sig, [_|_]=V1) ->
        %[ unpacksig4json(Sig,BinPacker) || Sig <- V1 ];
        show_signs(V1, BinPacker, false);
       (_, V1) -> V1
    end, maps:without([public_key, signature], TXB));

prettify_tx(TXB, BinPacker) ->
   maps:map(
     fun(register, Val) ->
         BinPacker(Val);
        (from, <<Val:8/binary>>) ->
         BinPacker(Val);
        (to, <<Val:8/binary>>) ->
         BinPacker(Val);
        (address, Val) ->
         BinPacker(Val);
        (invite, Val) ->
         BinPacker(Val);
        (pow, Val) ->
         BinPacker(Val);
        (sig, #{}=V1) ->
         [
          {BinPacker(SPub),
           BinPacker(SPri)} || {SPub, SPri} <- maps:to_list(V1) ];
        (_, V1) -> V1
     end, maps:without([public_key, signature], TXB)).


% ----------------------------------------------------------------------

show_signs(Signs, BinPacker, IsNode) ->
  lists:map(
    fun(BSig) ->
        #{binextra:=Hdr,
          extra:=Extra,
          signature:=Signature}=bsig:unpacksig(BSig),
        UExtra=lists:map(
                 fun({K, V}) ->
                     if(is_binary(V)) ->
                         {K, BinPacker(V)};
                       true ->
                         {K, V}
                     end
                 end, Extra
                ),
        NodeID=proplists:get_value(pubkey, Extra, <<>>),
        R1=#{ binextra => BinPacker(Hdr),
           signature => BinPacker(Signature),
           extra =>UExtra
         },
        if IsNode ->
             R1#{
               '_nodeid' => nodekey:node_id(NodeID),
               '_nodename' => try chainsettings:is_our_node(NodeID)
                              catch _:_ -> null
                              end
              };
           true ->
             R1
        end
    end, Signs).

% ----------------------------------------------------------------------

get_nodes(Chain) when is_integer(Chain) ->
    Nodes = discovery:lookup(<<"apipeer">>, Chain),
    NodesHttps = discovery:lookup(<<"apispeer">>, Chain),

%%    io:format("Nodes: ~p~n", [Nodes]),
%%    io:format("NodesHttps: ~p~n", [NodesHttps]),

    % sanitize data types
    Nodes1 = lists:map(
        fun(Addr) when is_map(Addr) ->
            maps:map(
                fun(address, Ip) ->
                    utils:make_binary(Ip);
                    (hostname, Name) ->
                    utils:make_binary(Name);
                    (_, V) ->
                        V
                end,
                Addr
            );
            (V) ->
                V
        end,
      NodesHttps ++ Nodes
    ),

%%    io:format("nodes1: ~p~n", [Nodes1]),

    AddToList =
        fun(List, NewItem) ->
            case NewItem of
                unknown ->
                    List;
                _ ->
                    [NewItem | List]
            end
        end,
    Result = lists:foldl(
        fun(Addr, NodeMap) when is_map(Addr) ->
            Port = maps:get(port, Addr, unknown),
            Host0 = add_port(maps:get(hostname, Addr, unknown), Port),
            Ip0 = add_port(maps:get(address, Addr, unknown), Port),
            Proto =
              case utils:make_binary(maps:get(proto, Addr, unknown)) of
                <<"api">> -> <<"http">>;
                <<"apis">> -> <<"https">>;
                _ -> unknown
              end,

            Host = add_proto(Host0, Proto),
            Ip = add_proto(Ip0, Proto),

            case maps:get(nodeid, Addr, unknown) of
                unknown -> NodeMap;
                NodeId ->
                    NodeRecord = maps:get(NodeId, NodeMap, #{}),
                    Hosts = maps:get(host, NodeRecord, []),
                    Ips = maps:get(ip, NodeRecord, []),
                    NodeRecord1 = maps:put(
                        host,
                        AddToList(Hosts, Host),
                        NodeRecord
                    ),
                    NodeRecord2 = maps:put(
                        ip,
                        AddToList(Ips, Ip),
                        NodeRecord1
                    ),
                    maps:put(NodeId, NodeRecord2, NodeMap)
            end;
            (Invalid, NodeMap) ->
                lager:error("invalid address: ~p", Invalid),
                NodeMap
        end,
        #{},
        Nodes1
    ),
    remove_duplicates(Result).


% #{<<"node_id">> => #{ host => [], ip => []}}
remove_duplicates(NodeMap) ->
  Worker =
    fun(_NodeId, KeyMap) ->
      Sorter =
        fun
          (host, V) ->
            lists:usort(V);
          (ip, V) ->
            lists:usort(V);
          (_, V) ->
            V
        end,

      maps:map(Sorter, KeyMap)
    end,
  maps:map(Worker, NodeMap).



% ----------------------------------------------------------------------

add_port(unknown, _Port) ->
    unknown;
add_port(_Ip, unknown) ->
    unknown;
add_port(Ip, Port)
    when is_binary(Ip) andalso is_integer(Port) ->
        case inet:parse_address(binary_to_list(Ip)) of
            {ok, {_,_,_,_}} ->
                <<Ip/binary, ":", (integer_to_binary(Port))/binary>>;
            {ok, _} ->
                <<"[", Ip/binary, "]:", (integer_to_binary(Port))/binary>>;
            _ ->
              <<Ip/binary, ":", (integer_to_binary(Port))/binary>>
        end;

add_port(Ip, Port) ->
    lager:error("Invalid ip address (~p) or port (~p)", [Ip, Port]),
    unknown.

% ----------------------------------------------------------------------

add_proto(unknown, _Proto) ->
  unknown;

add_proto(_Ip, unknown) ->
  unknown;

add_proto(Ip, Proto) when is_binary(Ip) ->
  <<Proto/binary, "://", Ip/binary>>;

add_proto(Ip, Proto) ->
  lager:error("Invalid ip address (~p) or proto (~p)", [Ip, Proto]),
  unknown.

% ----------------------------------------------------------------------

packer(Req,Default) ->
  QS=cowboy_req:parse_qs(Req),
  case proplists:get_value(<<"bin">>, QS) of
    <<"b64">> -> fun(Bin) -> base64:encode(Bin) end;
    <<"hex">> -> fun(Bin) -> hex:encode(Bin) end;
    <<"raw">> -> fun(Bin) -> Bin end;
    _ -> case Default of
           hex -> fun(Bin) -> hex:encode(Bin) end;
           b64 -> fun(Bin) -> base64:encode(Bin) end
         end
  end.

% ----------------------------------------------------------------------

binjson(Term) ->
  EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
%          io:format("State ~p~n",[State]),
%          io:format("Handler ~p~n",[Handler]),
%          io:format("Stack ~p~n",[Handler]),
%          io:format("~p~n",[{Type, Str}]),
%          io:format("~p~n",[Tokens]),
%          io:format("C0 ~p~n",[Conf]),
%          Conf1=jsx_config:parse_config(Conf--[strict_commas]),
          Conf1=jsx_config:list_to_config(Conf),
%          io:format("C1 ~p~n",[Conf1]),
          jsx_parser:resume([{Type, base64:encode(Str)}|Tokens],
                            State, Handler, Stack, Conf1)
      end,
   jsx:encode(
     Term,
     [ strict, {error_handler, EHF} ]
    ).

postbatch(<<>>) ->
  [];

postbatch(<<Size:32/big,Body:Size/binary,Rest/binary>>) ->
  case txpool:new_tx(Body) of
    {ok, Tx} ->
      [Tx | postbatch(Rest) ];
    {error, Err} ->
      lager:info("error ~p", [Err]),
      [iolist_to_binary(io_lib:format("bad_tx:~p", [Err])) | postbatch(Rest)]
  end.

