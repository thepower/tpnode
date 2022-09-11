-module(vm_erltest).
-export([run/2,client/2,loop/1,eval/2]).

run(Host, Port) ->
  spawn(?MODULE,client,[Host, Port]).

client(Host, Port) ->
  {ok, Socket} = gen_tcp:connect(Host, Port, [{packet,4},binary]),
  inet:setopts(Socket, [{active, once}]),
  State=#{myseq=>0,
          transport=>gen_tcp,
          socket=>Socket
         },
  S1=tpnode_vmproto:req(#{null => "hello","lang" => "erltest","ver" => 1}, State),
  loop(S1).

loop(#{socket:=Socket, transport:=Transport}=State) ->
  inet:setopts(Socket, [{active, once}]),
  receive
    stop ->
      Transport:close(Socket);
    {tcp, Socket, <<Seq:32/big,Data/binary>>} ->
      {ok,Payload}=msgpack:unpack(Data),
      S1=case Seq rem 2 of
           0 ->
             handle_req(Seq, Payload, State);
           1 ->
             handle_res(Seq bsr 1, Payload, State)
         end,
      ?MODULE:loop(S1)
  after 60000 ->
          ?MODULE:loop(State)
  end.

handle_res(Seq, Payload, State) ->
  logger:info("Res ~b ~p",[Seq,Payload]),
  State.

handle_req(Seq, #{null:="exec",
                  "gas":=Gas,
                  "ledger":=Ledger,
                  "tx":=BTx}=Req, State) ->
  %io:format("Req ~p",[Req]),
  T1=erlang:system_time(),
  Tx=tx:unpack(BTx),
  Code=case maps:get(kind, Tx) of
         deploy ->
           maps:get("code",maps:get(txext,Tx));
         generic ->
           maps:get(<<"code">>,Ledger)
       end,
  %logger:info("Req ~b ~p",[Seq,maps:remove(body,Tx)]),
  MapBind0=#{
             'Gas'=>Gas,
             'Ledger'=>Ledger,
             'Tx'=>Tx
            },
  MapBind1=case maps:get("mean_time",Req,undefined) of
            Int when is_integer(Int) ->
               maps:put('MeanTime',Int, MapBind0);
             _ ->
               MapBind0
           end,

  MapBind2=case maps:get("entropy",Req,undefined) of
            Bin when is_binary(Bin) ->
               maps:put('Entropy',Bin, MapBind1);
             _ ->
               maps:put('Entropy',<<>>, MapBind1)
           end,

  Bindings=maps:fold(
             fun erl_eval:add_binding/3,
             erl_eval:new_bindings(),
             MapBind2),
  try
  T2=erlang:system_time(),
  Ret=eval(Code, Bindings),
  T3=erlang:system_time(),
  logger:debug("Ret ~p",[Ret]),
  case Ret of
    {ok, RetVal, NewState, NewGas, NewTxs} ->
      T4=erlang:system_time(),
      tpnode_vmproto:reply(Seq, #{
                             null => "exec",
                             "gas" => NewGas,
                             "ret" => RetVal,
                             "state" => msgpack:pack(NewState),
                             "txs" => NewTxs,
                             "dt"=>[T2-T1,T3-T2,T4-T3]
                            },State);
    _ ->
      T4=erlang:system_time(),
      tpnode_vmproto:reply(Seq,
                           #{
                             null => "exec",
                             "dt"=> [T2-T1,T3-T2,T4-T3],
                             "gas" => Gas,
                             "ret" => "error"
                            },
                           State)
  end
  catch Ec:Ee:S ->
          %S=erlang:get_stacktrace(),
          io:format("Error ~p:~p~n", [Ec, Ee]),
          lists:foreach(fun(SE) ->
                            io:format("@ ~p~n", [SE])
                        end, S),

          tpnode_vmproto:reply(Seq,
                               #{
                                 null => "exec",
                                 "error"=> iolist_to_binary(
                                             io_lib:format("crashed ~p:~p",[Ec,Ee])
                                            )
                                },
                               State)
  end;

handle_req(Seq, Payload, State) ->
  logger:info("Req ~b ~p",[Seq,Payload]),
  State.



eval(Source, Bindings) ->
  SourceStr = binary_to_list(Source),
  {ok, Tokens, _} = erl_scan:string(SourceStr),
  {ok, Parsed} = erl_parse:parse_exprs(Tokens),
  case erl_eval:exprs(Parsed, Bindings) of
    {value, Result, _} -> Result;
    Any ->
      logger:error("Error ~p",[Any]),
      throw('eval_error')
  end.

