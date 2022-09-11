-module(tpnode_ws).
-export([init/2]).
-export([
         websocket_init/1, websocket_handle/2,
         websocket_info/2
        ]).

init(Req, _Opts) ->
  logger:debug("WS Upgrade req ~p",[Req]),
  case Req of
    #{headers:=#{<<"sec-websocket-protocol">> := <<"thepower-nodesync-v1">>}=H} ->
      {cowboy_websocket, Req, #{headers=>H,p=>v1}, #{ idle_timeout => 600000 }};
    _ ->
      {cowboy_websocket, Req, v0, #{ idle_timeout => 600000 }}
  end.

websocket_init(v0) ->
  logger:debug("init websocket v0",[]),
  {ok, 100};

websocket_init(S0=#{p:=v1}) ->
  logger:info("init websocket v1 ~p at pid ~p",[S0,self()]),
  Msg=msgpack:pack(
        #{null=><<"banner">>,
          protocol=><<"thepower-nodesync-v1">>,
          <<"tpnode-name">> => nodekey:node_name(),
          <<"tpnode-id">> => nodekey:node_id()
         }
       ),
  {reply, {binary, Msg}, S0}.

websocket_handle(ping, State) ->
  {reply, pong, State};

websocket_handle({text, <<"ping">>}, State) ->
  {reply, {text, <<"pong">>}, State};

websocket_handle({text, _Msg}, 0) ->
  {reply, {text, jsx:encode(#{ error=><<"subs limit reached">> })}, 0};

websocket_handle({text, Msg}, State) when is_integer(State) ->
  try
    JS=jsx:decode(Msg, [return_maps]),
    logger:info("WS ~p", [JS]),
    Ret=case JS of
          #{<<"sub">>:= <<"block">>} ->
            gen_server:cast(tpnode_ws_dispatcher, {subscribe, {block, json, full}, self()}),
            [new_block, full, json];
          #{<<"sub">>:= <<"blockstat">>} ->
            gen_server:cast(tpnode_ws_dispatcher, {subscribe, {block, json, stat}, self()}),
            [new_block, stat, json];
          #{<<"sub">>:= <<"tx">>} ->
            gen_server:cast(tpnode_ws_dispatcher, {subscribe, tx, self()}),
            [tx, any];
          #{<<"sub">>:= <<"addr">>, <<"addr">>:=Address, <<"get">>:=G} ->
            Get=lists:filtermap(
                  fun(<<"tx">>) -> {true, tx};
                     (<<"bal">>) -> {true, bal};
                     (_) -> false
                  end, binary:split(G, <<", ">>, [global])),
            gen_server:cast(tpnode_ws_dispatcher,
                            {subscribe, address, Address, Get, self()}
                           ),
            [address, Address, Get];
          _ ->
            undefined
        end,
    {reply, {text,
             jsx:encode(#{
                          ok=>true,
                          subscribe=>Ret,
                          moresubs=>State-1
                         })}, State-1 }
  catch _:_ ->
          logger:error("WS error ~p", [Msg]),
          {ok, State}
  end;

websocket_handle(_Any, State) when is_integer(State) ->
  {reply, {text, << "whut?">>}, State};

websocket_handle({text, _}, #{p:=v1}=State) ->
  {reply, {text, << "no text expected by this protocol">>}, State};

websocket_handle({binary, Bin}, #{p:=v1}=State) ->
    case msgpack:unpack(Bin) of
      {ok, #{}=M} ->
        logger:debug("Bin ~p",[M]),
        handle_msg(M, State);
      {error, _}=E ->
        logger:debug("parse error1: ~p",[E]),
        {reply, {text, <<"parsing error">>}, State};
      E ->
        logger:debug("parse error2: ~p",[E]),
        {reply, {text, <<"unknown error">>}, State}
    end.

websocket_info({message, Msg}, #{p:=v1}=State) ->
  EMsg=msgpack:pack(Msg),
  {reply, {binary, EMsg}, State};

websocket_info({message, Msg}, State) when is_integer(State) ->
  {reply, {text, Msg}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
  {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
  logger:info("websocket info ~p", [_Info]),
  {ok, State}.

handle_msg(#{null:= <<"ping">>}, State) ->
  {ok, State};

handle_msg(#{null:= <<"subscribe">>, since:=BlockHash}, State) when is_binary(BlockHash) ->
  gen_server:cast(tpnode_ws_dispatcher, {subscribe, {block, term, stat}, self()}),
  {reply, {binary, msgpack:pack(#{null=><<"ACK">>})}, State};

handle_msg(#{null:= <<"logs_request">>, <<"height">>:=H}, State) when is_integer(H) ->
  case logs_db:get(H) of
    undefined ->
      {reply, {binary, msgpack:pack(#{null=><<"logs_request_nak">>})}, State};
    #{blkid:=Hash, height:=Hei, logs:=Logs} ->
      {reply, {binary, msgpack:pack(
                         #{
                           null=><<"block_logs">>,
                           <<"hash">> => Hash,
                           <<"height">> => Hei,
                           <<"logs">> => Logs
                          })}, State}
  end;

handle_msg(#{null:= <<"logs_request">>, <<"hash">>:=H}, State) when is_binary(H) ->
  case logs_db:get(H) of
    undefined ->
      {reply, {binary, msgpack:pack(#{null=><<"logs_request_nak">>})}, State};
    #{blkid:=Hash, height:=Hei, logs:=Logs} ->
      {reply, {binary, msgpack:pack(
                         #{
                           null=><<"block_logs">>,
                           <<"hash">> => Hash,
                           <<"height">> => Hei,
                           <<"logs">> => Logs
                          })}, State}
  end;

handle_msg(#{null:= <<"logs_subscribe">>}, State) ->
  Filter=[],
  #{hash:=Hash, header:=#{height:=Hei}}=blockchain:last_permanent_meta(),
  gen_server:cast(tpnode_ws_dispatcher, {subscribe, logs, self(), Filter}),
  Bin=msgpack:pack(#{
                     null=><<"logs_subscribe_ack">>,
                     last=>#{
                             hash => Hash,
                             height => Hei
                            }
                    }),
  {reply, {binary, Bin}, State};

handle_msg(#{null:= <<"subscribe">>}, State) ->
  gen_server:cast(tpnode_ws_dispatcher, {subscribe, {block, term, stat}, self()}),
  {reply, {binary, msgpack:pack(#{null=><<"subscribe_ack">>})}, State};

handle_msg(Msg, State) ->
  logger:info("unhandled WSv1 msg ~p",[Msg]),
  {ok, State}.

