-module(tpnode_preconf_api).
-include("include/tplog.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([h/3,
         after_filter/1,
         before_filter/1,
         log/3
        ]).


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.


before_filter(Req) ->
  case cowboy_req:method(Req) of
    <<"OPTIONS">> ->
      Req;
    _ ->
      % check authentication header:
      case cowboy_req:header(<<"authorization">>, Req) of
        undefined ->
          logger:info("No authorization header found in request"),
          {reply, 403, #{}, <<"Unauthorized">>, Req};
        Auth ->
          PwHash=crypto:hash(sha256,Auth),
          case application:get_env(tpnode, conf_secret, none) of
            Hash1 when Hash1==PwHash ->
              Req;
            _ ->
              logger:info("Invalid authorization header found in request"),
              {reply, 403, #{}, <<"Unauthorized">>, Req}
          end
      end
  end.

after_filter(Req) ->
  Origin=cowboy_req:header(<<"origin">>, Req, <<"*">>),
  Req1=cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                  Origin, Req),
  Req2=cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                  <<"GET, POST, OPTIONS">>, Req1),
  Req3=cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                  <<"86400">>, Req2),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                             <<"content-type,authorization">>, Req3).

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};

h(<<"GET">>, [<<"info">>], _Req) ->
  {pub,ed25519, Pub} = tpecdsa:rawkey(nodekey:get_pub()),
  PubKey = hex:encodex(Pub),
  {200, [], #{ pubkey => PubKey,
               hostname => list_to_binary([
                                           application:get_env(tpnode,hostname,"localhost")
                                          ])
             }
  };

h(<<"POST">>, [<<"dh">>], Req) ->
  {PubKey, PrivKey} = crypto:generate_key(ecdh, x25519),
  #{<<"pubkey">>:=UserPubB64}=apixiom:bodyjs(Req),
  UserPub= base64:decode(UserPubB64),
  case size(UserPub) == 32 of
    true ->
      SharedSecret = crypto:compute_key(ecdh, UserPub, PrivKey, x25519),
      application:set_env(tpnode, ed_ss, SharedSecret),
      {200, [], base64:encode(PubKey)};
    false ->
      {400, [], <<"Invalid public key size">>}
  end;

h(<<"POST">>, [<<"update_hostname">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  logger:info("Update hostname from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  case Body of
    #{<<"hostname">> := Hostname} ->
      tpnode:set_override(hostname, binary_to_list(Hostname)),
      case Body of
        #{<<"role">>:= <<"new_chain">>} ->
          spawn(fun() ->
                    application:ensure_all_started(teaclient),
                    URL=tea_url(),
                    Request = URL#{
                        privkey => nodekey:get_priv(),
                        hostname=>Hostname,
                        status_update=>fun log/3},
                    io:format("Registering with tea server: ~p~n",
                              [maps:without([conn_opts],Request)]),
                    teaclient_worker:register(Request)
                end),
          ok;
        _ ->
          ok
      end,
      {200, [], <<"OK">>};
    _ ->
      io:format("Invalid request body: ~p~n", [Body]),
      {400, [], <<"Invalid request">>}
  end;

h(<<"POST">>, [<<"update_privkey">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  logger:info("Update privkey from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  case Body of
    #{<<"ciphertext">> := CipherText,
      <<"iv">> := IV
     } ->
      case application:get_env(tpnode, ed_ss, none) of
        SharedKey when is_binary(SharedKey) ->
          CipherTextBin = base64:decode(CipherText),
          IVBin = base64:decode(IV),
          TagSize = 16,
          CipherTextLen = byte_size(CipherTextBin) - TagSize,
          <<CipherBin:CipherTextLen/binary, Tag:TagSize/binary>> = CipherTextBin,

          try
            PlainBin = crypto:crypto_one_time_aead(
                         aes_256_gcm,
                         SharedKey,
                         IVBin,
                         CipherBin,
                         <<>>,      % No additional authenticated data (AAD)
                         Tag,
                         false
                        ),
            DerKey = public_key:der_encode('PrivateKeyInfo',
                        #'ECPrivateKey'{
                           version = 1,
                           privateKey = PlainBin,
                           parameters = {
                             namedCurve,
                             pubkey_cert_records:namedCurves(ed25519)
                            }
                          }
                       ),
            application:set_env(tpnode, privkey, binary_to_list(hex:encodex(DerKey))),
            Keyfile= utils:dbpath("node.key"),
            file:write_file(Keyfile,
                            [
                            io_lib:format("% For recovery thru web form use this key: ~s~n", [hex:encodex(PlainBin)]),
                            io_lib:format("{privkey,\"~s\"}.~n", [hex:encodex(DerKey)])
                            ]),
            tinymq:push(tea, list_to_binary([
                                             io_lib:format("private key saved to file ~s",[Keyfile])
                                            ])),
            application:unset_env(tpnode, pubkey),
            application:unset_env(tpnode,privkey_dec),
            tinymq:push(tea,list_to_binary([
                                            io_lib:format("new public key ~s",[hex:encodex(nodekey:get_pub())])
                                           ])),
            {200, [], <<"OK">>}
          catch
            error:badarg ->
              {400, [], <<"Decryption failed">>}
          end;
        _ ->
          {400, [], <<"no key negotiated">>}
      end;
    _ ->
      io:format("Invalid request body: ~p~n", [Body]),
      {400, [], <<"Invalid request">>}
  end;


h(<<"GET">>, [<<"tea_progress">>,T], _Req) ->
  {ok,_T0}=tinymq:subscribe(tea,binary_to_integer(T),self()),
  receive
    {Pid,Timestamp, List} when is_pid(Pid), is_integer(Timestamp), is_list(List) ->
      answer( #{t=>Timestamp, data=>List})
  after 50000 ->
      answer( #{error=> <<"timeout">>, data => null})
  end;

h(<<"POST">>, [<<"set_pw">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  io:format("set pw from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  io:format("Body: ~p~n", [Body]),
  case Body of
    #{<<"password">>:=Password} ->
      Hash=crypto:hash(sha256, Password),
      tpnode:set_override(conf_secret, Hash),
      answer( #{});
    _ ->
      err(<<"invalid_request">>, <<"Invalid request">>)
  end;

h(<<"POST">>, [<<"set_role">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  io:format("Join from ~p~n", [inet:ntoa(RemoteIP)]),
  Body=apixiom:bodyjs(Req),
  io:format("Body: ~p~n", [Body]),
  case Body of
    #{<<"role">>:=<<"tea">>,
      <<"nodeName">> := NodeName,
      <<"ceremonyToken">> := Token} ->
      application:ensure_all_started(teaclient),
      URL=tea_url(),
      spawn(fun() ->
                teaclient_worker:run(URL#{
                                       token=>Token,
                                       privkey => nodekey:get_priv(),
                                       status_update=>fun log/3,
                                       nodename=>NodeName})
            end),
      answer( #{});
    #{<<"nodeName">> := NodeName,
      <<"peerUrls">> := UpstreamUrl,
      %<<"privateKey">> => _,
      <<"role">> := <<"replica">>} ->

      tpnode:set_override(upstream,[
                                    binary_to_list(B) || B <- binary:split(UpstreamUrl,<<",">>,[global])
                                   ]),
      tpnode:set_override(name, NodeName),
      tpnode:set_override(replica, true),
      answer( #{});
    _ ->
      io:format("Body: ~p~n", [Body]),
      err(<<"invalid_request">>, <<"Invalid request">>)
  end;

h(_Method, [<<"status">>], Req) ->
  {RemoteIP, _Port}=cowboy_req:peer(Req),
  ?LOG_INFO("Join from ~p", [inet:ntoa(RemoteIP)]),
  %Body=apixiom:bodyjs(Req),

  answer( #{ client => list_to_binary(inet:ntoa(RemoteIP)) }).

%PRIVATE API

tea_url() ->
  {Host,Port,ConOpts,_Extra}=tpapi2:parse_url(
    application:get_env(tpnode,tea_server,"https://tea.thepower.io:443/")
   ),
  #{ host=>Host, port=>Port, conn_opts=>ConOpts }.

log(connected, #{}, Sub) ->
  tinymq:push(tea, <<"Connected to tea server">>),
  Sub;
log(logged_in, #{}, Sub) ->
  tinymq:push(tea,<<"Logged in to tea server">>),
  Sub;
log(registered, #{hostname := Hostname}, Sub) ->
  tinymq:push(tea,
              list_to_binary([
                              io_lib:format("Node ~s registered successfully", [Hostname])
                             ])
             ),
  Sub;

log(Kind, Data, Sub) ->
  tinymq:push(tea, #{k => Kind, d => Data}),
  Sub.

err(ErrorCode, ErrorMessage) ->
    err(ErrorCode, ErrorMessage, #{}, #{}).

err(ErrorCode, ErrorMessage, Data, Options) ->
    Required1 =
        #{
            <<"ok">> => false,
            <<"code">> => ErrorCode,
            <<"msg">> => ErrorMessage
        },

    {
        maps:get(http_code, Options, 200),
        maps:merge(Data, Required1)
    }.

answer(Data) ->
    answer(Data, #{}).

answer(Data, Options) when is_map(Data) ->
  Data2=maps:put(<<"ok">>, true, Data),
  MS=maps:with([jsx,msgpack],Options),
  case(maps:size(MS)>0) of
    true ->
      { 200, {Data2,MS} };
    false ->
      { 200, Data2 }
  end.

