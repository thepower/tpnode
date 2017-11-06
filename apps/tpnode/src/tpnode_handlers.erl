-module(tpnode_handlers).
%-compile(export_all).

-export([handle/3,before_filter/1,after_filter/1,after_filter/2,h/3]).
-export([prettify_block/1]).

before_filter(Req) ->
	apixiom:before_filter(Req).

after_filter(_,_) -> ok.

after_filter(Req) ->
	{Origin,Req0}=cowboy_req:header(<<"origin">>,Req,<<"*">>),
	%{AllHdrs,_}=cowboy_req:headers(Req),
	%lager:info("Hdr ~p",[AllHdrs]),
	Req1=cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, Origin, Req0),
	Req2=cowboy_req:set_resp_header(<<"Access-Control-Allow-Methods">>, <<"GET, POST, OPTIONS">>, Req1),
	Req3=cowboy_req:set_resp_header(<<"Access-Control-Allow-Credentials">>, <<"true">>, Req2),
	Req4=cowboy_req:set_resp_header(<<"Access-Control-Max-Age">>, <<"86400">>, Req3),
	Req5=cowboy_req:set_resp_header(<<"Access-Control-Allow-Headers">>, <<"Content-Type">>, Req4),
	cowboy_req:set_resp_header(<<"Content-Type">>, <<"application/json">>, Req5).

handle(Method, [<<"api">>|Path], Req) ->
	apixiom:handle(Method, Path, Req, ?MODULE);

handle(<<"GET">>, [], _Req) ->
    [<<"<h1>There is no web here, only API!</h1>">>];

handle(<<"GET">>, Path, _Req) ->
    File=lists:flatten(lists:join("/",[binary_to_list(P) || P<-Path])),
    case file:read_file("static/"++File) of
        {error,enoent} ->
            {404, "Not found"};
        {error,eisdir} ->
            {403, "Denied"};
        {ok, Payload} ->
            Payload
    end.
	

h(Method, [<<"longpoll">>|_]=Path, Req) ->
	tower_lphandler:h(Method, Path, Req); 

h(Method, [<<"event">>|_]=Path, Req) ->
	tower_lphandler:h(Method, Path, Req); 

h(<<"GET">>, [<<"address">>,Addr], _Req) ->
    Info=maps:map(
           fun(_K,V) ->
                   maps:put(lastblk,
                            bin2hex:dbin2hex(
                              maps:get(lastblk,V,<<0,0,0,0,0,0,0,0>>)
                             ),V)
           end,gen_server:call(blockchain,{get_addr, Addr})),

    {200,
     [{<<"Content-Type">>, <<"application/json">>}],
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
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        block => Block
      }
    };


h(<<"POST">>, [<<"benchmark">>,N], _Req) ->
    %{{RemoteIP,_Port},_}=cowboy_req:peer(Req),
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
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        address=>Res
      }
    };


h(<<"POST">>, [<<"register">>], Req) ->
    {{RemoteIP,_Port},_}=cowboy_req:peer(Req),
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
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        address=>Address,
        info=>Res
      }
    };



h(<<"POST">>, [<<"tx">>,<<"new">>], Req) ->
    {{RemoteIP,_Port},_}=cowboy_req:peer(Req),
    Body=apixiom:bodyjs(Req),
    lager:info("New tx from ~s: ~p",[inet:ntoa(RemoteIP), Body]),
    BinTx=case maps:get(<<"tx">>,Body,undefined) of
              <<"0x",BArr/binary>> ->
                  hex:parse(BArr);
              Any -> 
                  base64:decode(Any)
          end,
    lager:info_unsafe("New tx ~p",[BinTx]),
    case txpool:new_tx(BinTx) of
        {ok, Tx} -> 
            {200,
             [{<<"Content-Type">>, <<"application/json">>}],
             #{ result => <<"ok">>,
                txid => Tx
              }
            };
        {error, Err} ->
            {500,
             [{<<"Content-Type">>, <<"application/json">>}],
             #{ result => <<"error">>,
                error => iolist_to_binary(io_lib:format("bad_tx:~s",[Err]))
              }
            }
    end;

h(<<"OPTIONS">>, _, _Req) ->
    {200, [], ""};

h(_Method, [<<"status">>], Req) ->
    {{RemoteIP,_Port},_}=cowboy_req:peer(Req),
    lager:info("Join from ~p",[inet:ntoa(RemoteIP)]),
    %Body=apixiom:bodyjs(Req),

    {200,
     [{<<"Content-Type">>, <<"application/json">>}],
     #{ result => <<"ok">>,
        client => list_to_binary(inet:ntoa(RemoteIP))
      }
    }.

%PRIVATE API

prettify_block(#{hash:=BlockHash,
                 header:=#{ parent:=BlockParent, txs:=TXs }=BlockHeader,
                 sign:=Signs
                }=Block0) ->
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
             header=>BlockHeader#{
                       parent=>bin2hex:dbin2hex(BlockParent),
                       txs=>bin2hex:dbin2hex(TXs)
                      },
             sign=>lists:map(
                     fun({Public,Signature}) ->
                             #{ nodeid=>address:pub2addr(node,Public),
                                public_key=> bin2hex:dbin2hex(Public),
                                signature=> bin2hex:dbin2hex(Signature)
                              }
                     end, Signs),
             bals=>Bals
            },
    case maps:get(child,Block1,undefined) of
        undefined -> Block1;
        Child ->
            maps:put(child,bin2hex:dbin2hex(Child),Block1)
    end.

