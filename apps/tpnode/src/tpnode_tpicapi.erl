-module(tpnode_tpicapi).
-export([init/2]).

%% API
init(Req0, _) ->
  Method = cowboy_req:method(Req0),
  Path = cowboy_req:path_info(Req0),
  try
    case handle(Method, Path, Req0) of
      {{Code, Body},Req1} ->
        {ok, cowboy_req:reply(Code, #{}, Body, Req1), #{} };
      {{Code, Headers, Body},Req1} ->
        {ok, cowboy_req:reply(Code, Headers, Body, Req1), #{} };
      {Code, Body} ->
        {ok, cowboy_req:reply(Code, #{}, Body, Req0), #{} };
      {Code, Headers, Body} ->
        {ok, cowboy_req:reply(Code, Headers, Body, Req0), #{} }
    end
  catch error:function_clause:FC ->
          case FC of
            [{tpnode_tpicapi,handle,_Args,_Where}|_] ->
              {ok, cowboy_req:reply(400, #{}, <<"Bad Request">>, Req0), #{} };
            _ ->
              erlang:raise(error,function_clause,FC)
          end;
        throw:{bad_symbol,_} ->
          {ok, cowboy_req:reply(400, #{}, <<"Bad Request:hex">>, Req0), #{} };
        throw:bad_length ->
          {ok, cowboy_req:reply(400, #{}, <<"Bad Request:hex">>, Req0), #{} };
        throw:{return,RCode,RBody} ->
          {ok, cowboy_req:reply(RCode, #{}, RBody, Req0), #{} }
  end.

%% -- [ pick_block ] --

handle(<<"GET">>, [<<"pick_block">>,Hash], _Req) ->
  handle(<<"GET">>, [<<"pick_block">>,Hash,<<"self">>], _Req);

handle(<<"GET">>, [<<"pick_block">>,THash,TRel], _Req) ->
  Hash=case THash of
         <<"last">> -> last;
         _ -> hex:decode(THash)
       end,
  Rel=case TRel of
         <<"self">> -> self;
         <<"prev">> -> prev;
         <<"child">> -> child;
        _ ->
          throw({return,400,<<"Bad Request:rel">>})
       end,
  case blockchain:rel(Hash, Rel) of
    #{hash:=BHash,header:=#{}}=Map ->
      {200, #{
              <<"hash">> =>hex:encode(BHash),
              <<"content-type">> =><<"binary/tp-block">>
             }, block:pack(Map)};
    noblock ->
      {404, <<"not found">>}
  end;

%% -- [ sync ] --

handle(<<"GET">>,[<<"sync">>,<<"request">>], _Req) ->
  {200,
   #{<<"content-type">> =><<"application/msgpack">>},
   msgpack:pack(gen_server:call(blockchain_reader,sync_req))
  };

%% -- [ discovery ] --

handle(<<"GET">>,[<<"discovery">>,<<"tpicpeer">>,_BChain]=Path,Req) ->
  case Req of
    #{cert:=Cert} when is_binary(Cert) ->
      handle(get, Path ,Req);
    _ ->
      {403, <<"unauth">>}
  end;

handle(<<"GET">>,[<<"discovery">>,Service,BChain], Req) ->
  handle(get,[<<"discovery">>,Service,BChain], Req);

handle(get,[<<"discovery">>,Service,BChain], _Req) ->
  Chain=binary_to_integer(BChain),
  List=gen_server:call(discovery,{lookup_raw,Service,Chain}),
  Body=msgpack:pack(List),
  {200, #{ <<"content-type">> => <<"application/msgpack">> }, Body};

%% -- [ txstorage ] --

handle(<<"GET">>,[<<"txstorage">>,TxID], _Req) ->
  case tpnode_txstorage:get_txm(TxID) of
    {ok, #{body:=Body,
           origin:=Origin,
           valid:=Valid}} ->
      {200, #{ <<"content-type">> =><<"binary/tp-tx">>,
               <<"origin">> => if Origin==me ->
                                    hex:encode(nodekey:get_pub());
                                  true ->
                                    hex:encode(Origin)
                               end,
               <<"valid">> => integer_to_binary(Valid)
             }, Body};
    error ->
      {404, <<"not found">>}
  end;

handle(<<"PATCH">>,[<<"txstorage">>,TxID], #{cert:=Cert}=_Req) when is_binary(Cert) ->
  #{pubkey:=PubKey}=tpic2:extract_cert_info(public_key:pkix_decode_cert(Cert,otp)),
  case tpnode_txstorage:get_txm(TxID) of
    {ok, #{origin:=Origin, valid:=_Valid}} when Origin==PubKey ->
      case gen_server:call(txstorage,
                           #{
                             from=>PubKey,
                             null => <<"txsync_refresh">>,
                             <<"txid">> => TxID
                            }) of
        ok ->
          {200, <<"ok">>};
        {error, not_found} ->
          {404, <<"not found">>}
      end;
    {ok, #{origin:=_Origin, valid:=_Valid}} ->
      {403, <<"unathorized">>};
    error ->
      {404, <<"not found">>}
  end;

handle(<<"PUT">>,[<<"txstorage">>, TxID], #{cert:=Cert,has_body:=true}=Req) when is_binary(Cert) ->
  {ok, Body, Req1} = cowboy_req:read_body(Req),
  #{pubkey:=PubKey}=tpic2:extract_cert_info(public_key:pkix_decode_cert(Cert,otp)),
  case gen_server:call(txstorage,
                       #{
                         from=>PubKey,
                         null => <<"txsync_push">>,
                         <<"txid">> => TxID,
                         <<"body">> => Body
                        }) of
    ok ->
      {{200, <<"ok">>},Req1};
    {error, body_mismatch} ->
      {{400, <<"body_mismatch">>},Req1}
  end;

% -- [ tx ] --

handle(<<"PUT">>, [<<"tx">>,<<"multi">>], #{has_body := true} = Req) ->
  {ok, Body, Req1} = cowboy_req:read_body(Req),
  { case maps:get(<<"content-type">>,Req1,undefined) of
      <<"application/msgpack">> ->
        {ok,Lst} = msgpack:unpack(Body),
        if(is_list(Lst)) -> ok;
          true -> throw({return,400,<<"nolist">>})
        end,
        Res=lists:map(
              fun(Bin) when is_binary(Bin) ->
                  case txpool:new_tx(Bin) of
                    {ok, TxID} ->
                      TxID;
                    {error, Err} ->
                      [<<"error">>,
                       iolist_to_binary(io_lib:format("~p", [Err]))
                      ]
                  end
              end, Lst),
        {200, #{<<"content-type">> =><<"application/msgpack">>}, msgpack:pack(Res) };
      _ ->
        {400, <<"unexpected content-type">>}
    end, Req};

%
handle(<<"PUT">>, [<<"tx">>], #{has_body := true} = Req) ->
  {ok, Body, Req1} = cowboy_req:read_body(Req),
  { case txpool:new_tx(Body) of
      {ok, TxID} ->
        {200,TxID};
      {error, Err} ->
        {500,
         iolist_to_binary(io_lib:format("~p", [Err]))
        }
    end, Req1};

% -- [ status ] --

handle(<<"GET">>,[<<"status">>], #{cert:=Cert}) when is_binary(Cert) ->
  #{pubkey:=PubKey}=tpic2:extract_cert_info(public_key:pkix_decode_cert(Cert,otp)),
  {200,#{
        <<"client">> =>hex:encode(PubKey)
        },
   <<"status">>};

handle(<<"GET">>,[<<"status">>], _Req) ->
  {200, <<"status">>}.


