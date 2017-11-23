-module(tpnode_httpapi).

-export([h/3,after_filter/1,prettify_block/1]).

after_filter(Req) ->
    Origin=cowboy_req:header(<<"origin">>,Req,<<"*">>),
    Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
    Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, POST, OPTIONS">>, Req1),
    Req3=cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req2),
    Req4=cowboy_req:set_resp_header(<<"access-control-max-age">>, <<"86400">>, Req3),
    cowboy_req:set_resp_header(<<"access-control-allow-headers">>, <<"content-type">>, Req4).

h(Method, [<<"api">>|Path], Req) ->
    lager:info("Path ~p",[Path]),
    h(Method,Path,Req);

h(<<"GET">>, [<<"address">>,Addr], _Req) ->
    Info=maps:map(
           fun(_K,V) ->
                   maps:put(lastblk,
                            bin2hex:dbin2hex(
                              maps:get(lastblk,V,<<0,0,0,0,0,0,0,0>>)
                             ),V)
           end,gen_server:call(blockchain,{get_addr, Addr},20000)),

    {200,
     #{ result => <<"ok">>,
        address=>Addr,
        info=>Info
      }
    };

h(<<"GET">>, [<<"block">>,BlockId], _Req) ->
    BlockHash0=if(BlockId == <<"last">>) -> last;
                true ->
                    hex:parse(BlockId)
              end,
    Block=prettify_block(gen_server:call(blockchain,{get_block,BlockHash0})),
    
       {200,
     #{ result => <<"ok">>,
        block => Block
      }
    };


h(<<"POST">>, [<<"benchmark">>,N], _Req) ->
    Addresses=lists:map(
        fun(_) ->
                address:pub2addr(0,crypto:strong_rand_bytes(16))
        end, lists:seq(1, binary_to_integer(N))),
    {ok,Config}=application:get_env(tpnode,tpfaucet),
    Tokens=proplists:get_value(tokens,Config),
    Coin= <<"FTT">>,
    #{key:=Key, addr:=Adr}=proplists:get_value(Coin,Tokens,undefined),
    #{seq:=Seq0}=gen_server:call(blockchain,{get_addr,Adr,Coin}),
    BinKey=address:parsekey(Key),

    {_,Res}=lists:foldl(fun(Address,{Seq,Acc}) ->
                                Tx=#{
                                  amount=>1,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{
                                               message=> <<"Preved, ", Address/binary>>
                                              }),
                                  from=>Adr,
                                  to=>Address,
                                  seq=>Seq,
                                  timestamp=>os:system_time()
                                 },
                                NewTx=tx:sign(Tx,BinKey),
                                case txpool:new_tx(NewTx) of
                                    {ok, TxID} ->
                                        {Seq+1,
                                         [#{addr=>Address,tx=>TxID}|Acc]
                                        };
                                    {error, Error} ->
                                        lager:error("Can't make tx: ~p",[Error]),
                                        {Seq+1,Acc}
                                end
                        end,{Seq0+1,[]},Addresses),
        {200,
     #{ result => <<"ok">>,
        address=>Res
      }
    };

h(<<"GET">>, [<<"give">>,<<"me">>,<<"money">>,<<"to">>,Address], Req) ->
    {RemoteIP,_Port}=cowboy_req:peer(Req),
    {ok,Config}=application:get_env(tpnode,tpfaucet),
    Faucet=proplists:get_value(register,Config),
    Tokens=proplists:get_value(tokens,Config),
    Res=lists:foldl(fun({Coin,Amount},Acc) ->
                        case proplists:get_value(Coin,Tokens,undefined) of
                            undefined -> Acc;
                            #{key:=Key,
                              addr:=Adr} ->
                                #{seq:=Seq}=gen_server:call(blockchain,{get_addr,Adr,Coin}),
                                Tx=#{
                                  amount=>Amount,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{
                                               message=> <<"Welcome, ", Address/binary>>,
                                               ipaddress => list_to_binary(inet:ntoa(RemoteIP))
                                              }),
                                  from=>Adr,
                                  to=>Address,
                                  seq=>Seq+1,
                                  timestamp=>os:system_time()
                                 },
                                lager:info("Sign tx ~p",[Tx]),
                                NewTx=tx:sign(Tx,address:parsekey(Key)),
                                case txpool:new_tx(NewTx) of
                                    {ok, TxID} ->
                                        [#{c=>Coin,s=>Amount,tx=>TxID}|Acc];
                                    {error, Error} ->
                                        lager:error("Can't make tx: ~p",[Error]),
                                        Acc
                                end
                        end
                end,[],Faucet),
    {200,
     #{ result => <<"ok">>,
        address=>Address,
        info=>Res
      }
    };



h(<<"POST">>, [<<"test">>,<<"request_fund">>], Req) ->
    Body=apixiom:bodyjs(Req),
    lager:info("B ~p",[Body]),
    Address=maps:get(<<"address">>,Body),
    ReqAmount=maps:get(<<"amount">>,Body,10),
    {ok,Config}=application:get_env(tpnode,tpfaucet),
    Faucet=proplists:get_value(register,Config),
    Tokens=proplists:get_value(tokens,Config),
    Res=lists:foldl(fun({Coin,CAmount},Acc) ->
                        case proplists:get_value(Coin,Tokens,undefined) of
                            undefined -> Acc;
                            #{key:=Key,
                              addr:=Adr} ->
                                Amount=min(CAmount,ReqAmount),
                                #{seq:=Seq}=gen_server:call(blockchain,{get_addr,Adr,Coin}),
                                Tx=#{
                                  amount=>Amount,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{
                                               message=> <<"Test fund">>
                                              }),
                                  from=>Adr,
                                  to=>Address,
                                  seq=>Seq+1,
                                  timestamp=>os:system_time()
                                 },
                                lager:info("Sign tx ~p",[Tx]),
                                NewTx=tx:sign(Tx,address:parsekey(Key)),
                                case txpool:new_tx(NewTx) of
                                    {ok, TxID} ->
                                        [#{c=>Coin,s=>Amount,tx=>TxID}|Acc];
                                    {error, Error} ->
                                        lager:error("Can't make tx: ~p",[Error]),
                                        Acc
                                end
                        end
                end,[],Faucet),
    {200,
     #{ result => <<"ok">>,
        address=>Address,
        info=>Res
      }
    };




h(<<"POST">>, [<<"register">>], Req) ->
    {RemoteIP,_Port}=cowboy_req:peer(Req),
    Body=apixiom:bodyjs(Req),
    Address=maps:get(<<"address">>,Body),
    {ok,Config}=application:get_env(tpnode,tpfaucet),
    Faucet=proplists:get_value(register,Config),
    Tokens=proplists:get_value(tokens,Config),
    Res=lists:foldl(fun({Coin,Amount},Acc) ->
                        case proplists:get_value(Coin,Tokens,undefined) of
                            undefined -> Acc;
                            #{key:=Key,
                              addr:=Adr} ->
                                #{seq:=Seq}=gen_server:call(blockchain,{get_addr,Adr,Coin}),
                                Tx=#{
                                  amount=>Amount,
                                  cur=>Coin,
                                  extradata=>jsx:encode(#{
                                               message=> <<"Welcome, ", Address/binary>>,
                                               ipaddress => list_to_binary(inet:ntoa(RemoteIP))
                                              }),
                                  from=>Adr,
                                  to=>Address,
                                  seq=>Seq+1,
                                  timestamp=>os:system_time()
                                 },
                                lager:info("Sign tx ~p",[Tx]),
                                NewTx=tx:sign(Tx,address:parsekey(Key)),
                                case txpool:new_tx(NewTx) of
                                    {ok, TxID} ->
                                        [#{c=>Coin,s=>Amount,tx=>TxID}|Acc];
                                    {error, Error} ->
                                        lager:error("Can't make tx: ~p",[Error]),
                                        Acc
                                end
                        end
                end,[],Faucet),
    {200,
     #{ result => <<"ok">>,
        address=>Address,
        info=>Res
      }
    };



h(<<"POST">>, [<<"tx">>,<<"new">>], Req) ->
    {RemoteIP,_Port}=cowboy_req:peer(Req),
    Body=apixiom:bodyjs(Req),
    lager:debug("New tx from ~s: ~p",[inet:ntoa(RemoteIP), Body]),
    BinTx=case maps:get(<<"tx">>,Body,undefined) of
              <<"0x",BArr/binary>> ->
                  hex:parse(BArr);
              Any -> 
                  base64:decode(Any)
          end,
    %lager:info_unsafe("New tx ~p",[BinTx]),
    case txpool:new_tx(BinTx) of
        {ok, Tx} -> 
            {200,
             #{ result => <<"ok">>,
                txid => Tx
              }
            };
        {error, Err} ->
            lager:info("error ~p",[Err]),
            {500,
             #{ result => <<"error">>,
                error => iolist_to_binary(io_lib:format("bad_tx:~p",[Err]))
              }
            }
    end;

h(<<"OPTIONS">>, _, _Req) ->
    {200, [], ""};

h(_Method, [<<"status">>], Req) ->
    {RemoteIP,_Port}=cowboy_req:peer(Req),
    lager:info("Join from ~p",[inet:ntoa(RemoteIP)]),
    %Body=apixiom:bodyjs(Req),

    {200,
     #{ result => <<"ok">>,
        client => list_to_binary(inet:ntoa(RemoteIP))
      }
    }.

%PRIVATE API

prettify_block(#{hash:=BlockHash,
                 header:=BlockHeader
                }=Block0) ->
    Signs=maps:get(sign,Block0,[]),
    Bals=maps:fold(
           fun({Addr,Cur},Val0,Acc) ->
                   Val=maps:put(lastblk,bin2hex:dbin2hex(maps:get(lastblk,Val0,<<0,0,0,0,0,0,0,0>>)),Val0),
                   maps:put(Addr,
                            maps:put(Cur,Val,
                                     maps:get(Addr,Acc,#{})
                                    ),
                            Acc)
           end, 
           #{},
           maps:get(bals,Block0,#{})
          ),
    Block1=Block0#{
             hash=>bin2hex:dbin2hex(BlockHash),
             header=>maps:map(
                       fun(parent,V) ->
                               bin2hex:dbin2hex(V);
                          (_K,V) when is_binary(V) andalso size(V) == 32 ->
                               bin2hex:dbin2hex(V);
                          (_K,V) ->
                               V
                       end, BlockHeader),
             settings=>lists:map(
                         fun({CHdr,CBody}) ->
                                 DMP=settings:dmp(CBody),
                                 %DMP=base64:encode(CBody),
                                 {bin2hex:dbin2hex(CHdr),
                                  DMP}
                         end, maps:get(settings,Block0,[])),
             sign=>lists:map(
                     fun(BSig) ->
                             #{binextra:=Hdr,
                               extra:=Extra,
                               signature:=Signature}=block:unpacksig(BSig),
                             #{ binextra => bin2hex:dbin2hex(Hdr),
                                signature => bin2hex:dbin2hex(Signature),
                                extra =>
                                lists:map(
                                  fun({K,V}) ->
                                          if(is_binary(V)) ->
                                                {K,bin2hex:dbin2hex(V)};
                                            true ->
                                                {K,V}
                                          end
                                  end, Extra
                                 )
                              }
                     end, Signs),
             bals=>Bals
            },
    case maps:get(child,Block1,undefined) of
        undefined -> Block1;
        Child ->
            maps:put(child,bin2hex:dbin2hex(Child),Block1)
    end;

prettify_block(#{hash:=<<0,0,0,0,0,0,0,0>>}=Block0) -> 
    Block0#{ hash=><<"0000000000000000">> }.

