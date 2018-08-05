-module(xchain_client_worker).
-export([run/1,test/1]).

%run(ConnPid, #{proto:=P}=_Sub) ->
%  lager:info("Start xcahin_pull"),
%  Cmd = xchain:pack(#{null=><<"pre_ptr">>,<<"chain">>=>5}, P),
%  gun:ws_send(ConnPid, {binary, Cmd}),
%  receive 
%    Any ->
%      lager:info("pull ~p",[Any])
%  after 10000 ->
%          lager:info("Timeout")
%  end.

test(Sub) ->
  run(Sub, fun(node_id) ->
               nodekey:node_id();
              (chain) -> 5;
              ({last, 4}) ->
               <<70,145,201,163,89,206,171,17,192,231,231,17,15,61,24,125,228,102,251,
                 114,108,13,211,169,147,149,142,17,234,181,98,105>>;
              ({last,_ChainNo}) ->
               undefined
           end).

run(Sub) ->
  run(Sub, fun(node_id) ->
               nodekey:node_id();
              (chain) ->
               blockchain:chain();
              ({last,_ChainNo}) ->
               undefined
           end).

run(#{address:=Ip, port:=Port, channels:=_Channels} = _Sub, GetFun) ->
  lager:info("xchain client connecting to ~p ~p", [Ip, Port]),
  {ok, Pid} = gun:open(Ip, Port),
  receive 
    {gun_up, Pid, http} -> ok
  after 10000 -> 
          throw('up_timeout')
  end,
  %monitor(process, ConnPid),
  Proto=case sync_get_decode(Pid, "/xchain/api/compat.mp") of 
          {200, _, #{<<"ok">>:=true,<<"version">>:=Ver}} -> Ver;
          {404, _, _} -> 0;
          _ -> 0
        end,
  {ok,U}=upgrade(Pid,Proto),
  io:format("U ~p~n",[U]),
  #{null:=<<"iam">>,
    <<"chain">>:=HisChain,
    <<"node_id">>:=_}=R2=reg(Pid, Proto, GetFun),
  io:format("R2 ~p~n",[R2]),
  MyLast=GetFun({last, HisChain}),
  R0=block_list(Pid, Proto, GetFun(chain), last, MyLast, []),
  io:format("WS ~p~n",[R0]),
  %R1=make_ws_req(Pid, Proto, #{null=><<"pre_ptr">>,<<"chain">>=>5,}),
  %io:format("WS ~p~n",[R1]),
  gun:close(Pid),
  done.

reg(Pid, Proto, GetFun) ->
  MyNodeId = GetFun(node_id),
  Chain = GetFun(chain),
  make_ws_req(Pid, Proto, #{
                     null=><<"node_id">>,
                     node_id=>MyNodeId,
                     chain=>Chain
                    }).

block_list(Pid, Proto, Chain, Last, Known, Acc) ->
  Req=if Last==last ->
           #{null=><<"last_ptr">>, <<"chain">>=>Chain};
         true ->
           #{null=><<"pre_ptr">>,  <<"chain">>=>Chain, <<"parent">>=>Last}
    end,
  R=make_ws_req(Pid, Proto, Req),
  case R of 
    #{null := N,
      <<"ok">> := true,
      <<"pointers">> := #{<<"height">> := H,
                          <<"parent">> := P,
                          <<"pre_height">> := HH,
                          <<"pre_parent">> := PP}} when N==<<"last_ptr">> orelse
                                                        N==<<"pre_ptr">> ->
      if(PP==Known) ->
          [{HH,PP},{H,P}|Acc];
        true ->
          block_list(Pid, Proto, Chain, PP, Known, [{H,P}|Acc])
      end;
    Any ->
      lager:info("Err ~p",[Any]),
      Acc
  end.

make_ws_req(Pid, Proto, Request) ->
  receive {gun_ws,Pid, {binary, _}} ->
            throw('unexpected_data')
  after 0 -> ok
  end,
  Cmd = xchain:pack(Request, Proto),
  ok=gun:ws_send(Pid, {binary, Cmd}),
  receive {gun_ws,Pid, {binary, Payload}}->
            {ok, Res} = msgpack:unpack(Payload),
            Res
  after 5000 ->
          throw('ws_timeout')
  end.

upgrade(Pid, 2) ->
  gun:ws_upgrade(Pid, "/xchain/ws",
                 [ {<<"sec-websocket-protocol">>, <<"thepower-xchain-v2">>} ]),
  receive {gun_ws_upgrade,Pid,Status,Headers} ->
            {Status, Headers}
  after 10000 ->
          throw(upgrade_timeout)
  end.

sync_get_decode(Pid, Url) ->
  {Code,Header, Body}=sync_get(Pid, Url),
  case proplists:get_value(<<"content-type">>,Header) of
    <<"application/json">> ->
      {Code, Header, jsx:decode(iolist_to_binary(Body), [return_maps])};
    <<"application/msgpack">> ->
      {ok, Res}=msgpack:unpack(iolist_to_binary(Body)),
      {Code, Header, Res};
    _ ->
      {Code, Header, Body}
  end.

sync_get(Pid, Url) ->
  Ref=gun:get(Pid,Url),
  sync_get_continue(Pid, Ref, {0,[],[]}).

sync_get_continue(Pid, Ref, {PCode,PHdr,PBody}) ->
  {Fin,NS}=receive 
             {gun_response,Pid,Ref,IsFin, Code, Headers} ->
               {IsFin, {Code,Headers,PBody} };
             {gun_data,Pid,Ref, IsFin, Payload} ->
               {IsFin, {PCode,PHdr,PBody++[Payload]}}
           after 10000 ->
                   throw(get_timeout)
           end,
  case Fin of
    fin ->
      NS;
    nofin ->
      sync_get_continue(Pid, Ref, NS)
  end.

%process(#{connection:=Pid,req_ref:=Ref}=Sub) ->
%  receive 
%    {gun_response,Pid,Ref,nofin, Code, Headers} ->
%      process(Sub#{
%                got=>#{
%                  code=>Code,
%                  hdr=>Headers,
%                  payload=>[]
%                 }});
%    {gun_data,Pid,Ref,nofin, Payload} ->
%      #{got:=#{payload:=PrePayload}=Got}=Sub,
%      process(Sub#{got=>Got#{
%                          payload=>[Payload|PrePayload]
%                 }});
%    {gun_data,Pid,Ref,fin, Payload} ->
%      #{got:=#{payload:=PrePayload}=Got}=Sub,
%      process(Sub#{got=>Got#{
%                          payload=>[Payload|PrePayload]
%                         }});
%    Any -> io:format("Unhandled response ~p",[Any]),
%           gun:close(Pid),
%           receive {'DOWN',_,process,Pid, shutdown} -> 
%                     Sub
%           after 2000 ->
%                   Sub
%           end
%  after 5000 ->
%          timeout
%  end.

