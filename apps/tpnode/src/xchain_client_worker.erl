-module(xchain_client_worker).
-export([start_link/1,start_link/2,run/2,ws_mode/3]).

start_link(Sub) ->
  GetFun=fun(node_id) ->
               nodekey:node_id();
              (chain) ->
               blockchain:chain();
              ({apply_block,Block}) ->
               txpool:inbound_block(Block);
              ({last,_ChainNo}) ->
               undefined
           end,
  Pid=spawn(xchain_client_worker,run,[Sub#{parent=>self()}, GetFun]),
  link(Pid),
  {ok, Pid}.

start_link(Sub,test) ->
  GetFun=fun(node_id) ->
             nodekey:node_id();
            (chain) -> 5;
            ({apply_block,#{txs:=TL,header:=H}=_Block}) ->
             io:format("TXS ~b HDR: ~p~n",[length(TL),maps:get(height,H)]),
             {ok,<<"x">>};
            ({last, 4}) ->
             <<70,145,201,163,89,206,171,17,192,231,231,17,15,61,24,125,228,102,251,
               114,108,13,211,169,147,149,142,17,234,181,98,105>>;
            ({last,_ChainNo}) ->
             undefined;
            (Any) ->
             io:format("-------~n ERROR ~n~p~n-------~n",[Any]),
             undefined
         end,
  Pid=spawn(xchain_client_worker,run,[Sub#{parent=>self()}, GetFun]),
  link(Pid),
  {ok, Pid}.

run(#{parent:=Parent, address:=Ip, port:=Port} = Sub, GetFun) ->
  {ok, _} = application:ensure_all_started(gun),
  process_flag(trap_exit, true),
  try
    lager:info("xchain client connecting to ~p ~p", [Ip, Port]),
    {ok, Pid} = gun:open(Ip, Port),
    receive
      {gun_up, Pid, http} -> ok
    after 10000 ->
            throw('up_timeout')
    end,
    Proto=case sync_get_decode(Pid, "/xchain/api/compat.mp") of
            {200, _, #{<<"ok">>:=true,<<"version">>:=Ver}} -> Ver;
            {404, _, _} -> 0;
            _ -> 0
          end,
    {ok,UpgradeHdrs}=upgrade(Pid,Proto),
    lager:debug("Conn upgrade ~p",[UpgradeHdrs]),
    #{null:=<<"iam">>,
      <<"chain">>:=HisChain,
      <<"node_id">>:=_}=reg(Pid, Proto, GetFun),
    MyLast=GetFun({last, HisChain}),
    MyChain=GetFun(chain),
    BlockList=tl(block_list(Pid, Proto, GetFun(chain), last, MyLast, [])),
    lists:foldl(
      fun({_Height, BlockParent},Acc) ->
          #{null:=<<"owblock">>,
            <<"ok">>:=true,
            <<"block">>:=Blk}=pick_block(Pid, Proto, MyChain, BlockParent),
          #{txs:=_TL,header:=#{height:=H}}=Block=block:unpack(Blk),
          ok=GetFun({apply_block, Block}),
          io:format("RB ~p~n",[H]),
          Acc+1
      end, 0, BlockList),
    [<<"subscribed">>,_]=make_ws_req(Pid, Proto,
                                     #{null=><<"subscribe">>,
                                       <<"channel">>=>xchain:pack_chid(MyChain)}
                                    ),
    %io:format("SubRes ~p~n",[SubRes]),
    ok=gun:ws_send(Pid, {binary, xchain:pack(#{null=><<"ping">>}, Proto)}),
    ws_mode(Pid,Sub#{proto=>Proto},GetFun),
    gun:close(Pid),
    done
  catch Ec:Ee ->
          Parent ! {wrk_down, self(), error},
          S=erlang:get_stacktrace(),
          lager:error("xchain client error ~p:~p @ ~p",[Ec,Ee,hd(S)])
  end.

ws_mode(Pid, #{parent:=Parent, proto:=Proto}=Sub, GetFun) ->
  receive
    {'EXIT',_,_Reason} ->
      lager:error("Linked process went down. Giving up...."),
      Cmd = xchain:pack(#{null=><<"goodbye">>, <<"r">>=><<"noparent">>}, Proto),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      Parent ! {wrk_down, self(), noparent},
      exit;
    {state, CPid} ->
      CPid ! {Pid, Sub},
      ?MODULE:ws_mode(Pid, Sub, GetFun);
    stop ->
      Cmd = xchain:pack(#{null=><<"goodbye">>, <<"r">>=><<"stop">>}, Proto),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      Parent ! {wrk_down, self(), stop},
      done;
    {send_msg, Payload} ->
      Cmd = xchain:pack(Payload, Proto),
      gun:ws_send(Pid, {binary, Cmd}),
      ?MODULE:ws_mode(Pid, Sub, GetFun);
    {gun_ws, Pid, {binary, Bin}} ->
      Cmd = xchain:unpack(Bin, Proto),
      lager:debug("XChain client got ~p",[Cmd]),
      Sub1=xchain_client_handler:handle_xchain(Cmd, Pid, Sub),
      ?MODULE:ws_mode(Pid, Sub1, GetFun);
    {gun_down,Pid,ws,closed,[],[]} ->
      lager:error("Gun down. Giving up...."),
      Parent ! {wrk_down, self(), gundown},
      giveup;
    Any ->
      lager:notice("XChain client unknown msg ~p",[Any]),
      ?MODULE:ws_mode(Pid, Sub, GetFun)
  after 60000 ->
          ok=gun:ws_send(Pid, {binary, xchain:pack(#{null=><<"ping">>}, Proto)}),
          ?MODULE:ws_mode(Pid, Sub, GetFun)
  end.

reg(Pid, Proto, GetFun) ->
  MyNodeId = GetFun(node_id),
  Chain = GetFun(chain),
  make_ws_req(Pid, Proto, #{
                     null=><<"node_id">>,
                     node_id=>MyNodeId,
                     chain=>Chain
                    }).

pick_block(Pid, Proto, Chain, Parent) ->
  make_ws_req(Pid, Proto, #{null=><<"owblock">>,
                            <<"chain">>=>Chain,
                            <<"parent">>=>Parent
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
