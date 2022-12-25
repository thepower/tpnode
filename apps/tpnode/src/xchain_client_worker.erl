-module(xchain_client_worker).
-include("include/tplog.hrl").
-export([start_link/1,start_link/2,run/2,ws_mode/3]).

start_link(Sub) ->
  GetFun=fun(node_id) ->
             nodekey:node_id();
            (chain) ->
             blockchain:chain();
            ({apply_block,#{hash:=_H}=Block}) ->
             txpool:inbound_block(Block);
            ({last,ChainNo}) ->
             Last=chainsettings:by_path([
                                         <<"current">>,
                                         <<"sync_status">>,
                                         xchain:pack_chid(ChainNo),
                                         <<"block">>]),
             ?LOG_INFO("Last known to ch ~b: ~p",[ChainNo,Last]),
             Last
         end,
  Pid=spawn(xchain_client_worker,run,[Sub#{parent=>self()}, GetFun]),
  link(Pid),
  {ok, Pid}.

start_link(Sub,test) ->
  GetFun=fun(node_id) ->
             nodekey:node_id();
            (chain) -> 5;
            ({apply_block,#{txs:=TL,header:=H}=_Block}) ->
             io:format("TXS ~b Hei: ~p~n",[length(TL),maps:get(height,H)]),
             ok;
            ({last, 4}) ->
             hex:parse("A3366B6B16F58D684415EE150B055E9309578C954D0480CF25E796EB83D6FFEA");
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
    ?LOG_INFO("xchain client connecting to ~p ~p", [Ip, Port]),
    {ok, Pid} = gun:open(Ip, Port),
    receive
      {gun_up, Pid, _Http} ->
        ok;
      {gun_down, Pid, _Protocol, closed, _, _} ->
        throw(up_error)
    after 20000 ->
            gun:close(Pid),
            throw('up_timeout')
    end,
    Proto=case sync_get_decode(Pid, "/xchain/api/compat.mp") of
            {200, _, #{<<"ok">>:=true,<<"version">>:=Ver}} -> Ver;
            {404, _, _} -> throw('xchain_protocol_does_not_supported');
            _ -> 0
          end,
    {[<<"websocket">>],UpgradeHdrs}=upgrade(Pid,Proto),
    ?LOG_DEBUG("Conn upgrade hdrs: ~p",[UpgradeHdrs]),
    #{null:=<<"iam">>,
      <<"chain">>:=HisChain,
      <<"node_id">>:=NodeID}=reg(Pid, Proto, GetFun),
    Parent ! {wrk_up, self(), NodeID},
    Known=GetFun({last, HisChain}),
    MyChain=GetFun(chain),
    BlockList=block_list(Pid, Proto, GetFun(chain), last, Known, []),
    lists:foldl(
      fun({He,Ha},_) ->
          ?LOG_INFO("Blk ~b hash ~p~n",[He,Ha])
      end, 0, BlockList),
    lists:foldl(
      fun(_,Acc) when is_atom(Acc) ->
          Acc;
         ({_Height, BlkID},0) when BlkID == Known ->
          ?LOG_INFO("Skip known block ~s",[hex:encode(BlkID)]),
          0;
         ({_Height, BlkID},_) when BlkID == Known ->
          ?LOG_INFO("Skip known block ~s",[hex:encode(BlkID)]),
          error;
         ({0, <<0,0,0,0,0,0,0,0>>}, Acc) ->
          Acc;
         ({_Height, BlkID},Acc) ->
          ?LOG_INFO("Pick block ~s",[hex:encode(BlkID)]),
          case pick_block(Pid, Proto, MyChain, BlkID) of
            #{null:=<<"owblock">>,
              <<"ok">>:=true,
              <<"block">>:=Blk} ->
              #{txs:=_TL,header:=_}=Block=block:unpack(Blk),
              ok=GetFun({apply_block, Block}),
              Acc+1;
            #{null := <<"owblock">>,<<"ok">> := false} ->
              ?LOG_INFO("Fail block ~s",[hex:encode(BlkID)]),
              fail
          end
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
  catch
    throw:up_timeout ->
      Parent ! {wrk_down, self(), error},
      ?LOG_DEBUG("connection to ~p was timed out", [Sub]),
      pass;
    Ec:Ee:S ->
          Parent ! {wrk_down, self(), error},
          %S=erlang:get_stacktrace(),
          ?LOG_ERROR("xchain client error ~p:~p",[Ec,Ee]),
          lists:foreach(
            fun(SE) ->
                ?LOG_ERROR("@ ~p", [SE])
            end, S)
  end.

ws_mode(Pid, #{parent:=Parent, proto:=Proto}=Sub, GetFun) ->
  receive
    {'EXIT',_,shutdown} ->
      Cmd = xchain:pack(#{null=><<"goodbye">>, <<"r">>=><<"shutdown">>}, Proto),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
      exit;
    {'EXIT',_,Reason} ->
      ?LOG_ERROR("Linked process went down ~p. Giving up....",[Reason]),
      Cmd = xchain:pack(#{null=><<"goodbye">>, <<"r">>=><<"deadparent">>}, Proto),
      gun:ws_send(Pid, {binary, Cmd}),
      gun:close(Pid),
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
    {gun_ws, Pid, _Ref, {binary, Bin}} ->
      Cmd = xchain:unpack(Bin, Proto),
      ?LOG_DEBUG("XChain client got ~p",[Cmd]),
      Sub1=xchain_client_handler:handle_xchain(Cmd, Pid, Sub),
      ?MODULE:ws_mode(Pid, Sub1, GetFun);
    {gun_down,Pid,ws,closed,[],[]} ->
      ?LOG_ERROR("Gun down. Giving up...."),
      Parent ! {wrk_down, self(), gundown},
      giveup;
    Any ->
      ?LOG_NOTICE("XChain client unknown msg ~p",[Any]),
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

block_list(_, _, _, Last, Known, Acc) when Last==Known ->
  Acc;

block_list(Pid, Proto, Chain, Last, Known, Acc) ->
  Req=if Last==last ->
           ?LOG_DEBUG("Blocklist last",[]),
           #{null=><<"last_ptr">>, <<"chain">>=>Chain};
         true ->
           ?LOG_DEBUG("Blocklist ~s",[hex:encode(Last)]),
           #{null=><<"pre_ptr">>,  <<"chain">>=>Chain, <<"block">>=>Last}
    end,
  R=make_ws_req(Pid, Proto, Req),
  ?LOG_DEBUG("Got block_list resp ~p",[R]),
  case R of
    #{null := N,
      <<"ok">> := true,
      <<"pointers">> := #{<<"height">> := H,
                          <<"hash">> := P,
                          <<"pre_height">> := HH,
                          <<"pre_hash">> := PP}} 
      when is_binary(P) 
           andalso 
           (N==<<"last_ptr">> orelse N==<<"pre_ptr">>) ->
      if(PP==Known) ->
          [{HH,PP},{H,P}|Acc];
        (P==Known) ->
          [{H,P}|Acc];
        true ->
          block_list(Pid, Proto, Chain, PP, Known, [{HH,PP},{H,P}|Acc])
      end;
    #{null := N,
      <<"ok">> := true,
      <<"pointers">> := #{<<"pre_height">> := HH,
                          <<"pre_hash">> := PP}} when N==<<"last_ptr">> orelse
                                                      N==<<"pre_ptr">> ->
      if(PP==Known) ->
          [{HH,PP}|Acc];
        true ->
          block_list(Pid, Proto, Chain, PP, Known, [{HH,PP}|Acc])
      end;
    #{null := N,
      <<"ok">> := true,
      <<"pointers">> := #{<<"height">> := H,
                          <<"hash">> := P}} 
      when is_binary(P) 
           andalso 
           (N==<<"last_ptr">> orelse N==<<"pre_ptr">>) ->
      [{H,P}|Acc];
    Any ->
      ?LOG_INFO("Err ~p",[Any]),
      ?LOG_INFO("Acc is  ~p",[Acc]),
      Acc
  end.

make_ws_req(Pid, Proto, Request) ->
  receive {gun_ws,Pid, _, {binary, _}} ->
            throw('unexpected_data')
  after 0 -> ok
  end,
  Cmd = xchain:pack(Request, Proto),
  ok=gun:ws_send(Pid, {binary, Cmd}),
  receive {gun_ws,Pid, _Ref, {binary, Payload}}->
            {ok, Res} = msgpack:unpack(Payload),
            Res
  after 5000 ->
          throw('ws_timeout')
  end.

upgrade(Pid, 2) ->
  gun:ws_upgrade(Pid, "/xchain/ws",
                 [ {<<"sec-websocket-protocol">>, <<"thepower-xchain-v2">>} ]),
  receive {gun_upgrade,Pid,_Ref,Status,Headers} ->
            {Status, Headers};
          {gun_down, Pid, _Protocol, closed, [], []} ->
            gun:close(Pid),
            throw(upgrade_error);
          {gun_response, Pid, _Ref, _Fin, ErrorCode, _Headers} ->
            gun:close(Pid),
            throw({upgrade_error, ErrorCode})
  after 10000 ->
          gun:close(Pid),
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
