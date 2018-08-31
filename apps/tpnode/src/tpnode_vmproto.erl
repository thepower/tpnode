%%%-------------------------------------------------------------------
%% @doc tpnode_vmproto
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_vmproto).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-08-15").

-behaviour(ranch_protocol).

-export([start_link/4, init/4, childspec/1, childspec/2, loop/1]).
-export([req/2, reply/3]).

-record(req,
        {owner,
         t1
        }).

childspec(Host, Port) ->
  [
   ranch:child_spec(
    {vm_listener,Port}, ranch_tcp,
    [{port, Port}, {max_connections, 128}, {ip, Host}],
    ?MODULE,
    []
   )
  ].


childspec(Port) ->
  [
   ranch:child_spec(
    {vm_listener,Port}, ranch_tcp,
    [{port, Port}, {max_connections, 128}],
    ?MODULE,
    []
   )
  ].

start_link(Ref, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
  {ok, Pid}.

init(Ref, Socket, Transport, _Opts) ->
  ok = ranch:accept_ack(Ref),
  inet:setopts(Socket, [{active, once},{packet,4}]),
%Transport:close(Socket),
  loop(#{socket=>Socket, transport=>Transport, myseq=>0, reqs=>#{}}).

loop(#{socket:=Socket, transport:=Transport, reqs:=Reqs}=State) ->
  receive
    {tcp, Socket, <<Seq:32/big,Data/binary>>} ->
      %lager:info("Got seq ~b payload ~p",[Seq,Data]),
      {ok,Payload}=msgpack:unpack(Data),
      S1=case Seq rem 2 of
        0 ->
          handle_req(Seq bsr 1, Payload, State);
        1 ->
          handle_res(Seq bsr 1, Payload, State)
      end,
      inet:setopts(Socket, [{active, once}]),
      ?MODULE:loop(S1);
    {tcp_closed, Socket} ->
      lager:info("Client gone"),
      maps:fold(
        fun(ReqID,#req{owner=Owner},_Acc) ->
            Owner ! {result, ReqID, {error, vm_gone}}
        end, 0, Reqs),
      Transport:close(Socket);
    {ping, From} ->
      From ! {run_req, 0},
      From ! {result, 0, pong},
      ?MODULE:loop(State);
    {run, Transaction, Ledger, Gas, From} ->
      Seq=maps:get(myseq, State, 0),
      S1=req(#{null=>"exec",
                "tx"=>Transaction,
                "ledger"=>Ledger,
                "gas"=>Gas}, State),
      From ! {run_req, Seq},
      lager:debug("run tx ~p",[Seq]),
      R=#req{owner=From,t1=erlang:system_time()},
      ?MODULE:loop(S1#{reqs=>maps:put(Seq,R,Reqs)});
    Any ->
      lager:info("unknown message ~p",[Any]),
      ?MODULE:loop(State)
  end.

handle_req(Seq, #{null:="hello"}=Request, State) ->
  lager:debug("Got seq ~b hello ~p",[Seq, Request]),
  reply(Seq, Request, State),
  ok=gen_server:call(tpnode_vmsrv,{register, self(), Request}),
  State;

handle_req(Seq, Request, State) ->
  lager:info("Got req seq ~b payload ~p",[Seq, Request]),
  State.

handle_res(Seq, Result, #{reqs:=Reqs}=State) ->
  case maps:find(Seq, Reqs) of
    error ->
      lager:info("Got res seq ~b payload ~p",[Seq, Result]),
      State;
    {ok, #req{owner=Pid, t1=T1}} ->
      lager:debug("Got res seq ~b payload ~p",[Seq, Result]),
      Pid ! {result, Seq, {ok, Result, #{t=>erlang:system_time()-T1}}},
      State#{reqs=>maps:remove(Seq, Reqs)}
  end. 

req(Payload, #{myseq:=MS}=State) ->
  Seq=MS bsl 1,
  send(Seq, Payload, State#{myseq=>MS+1}).

reply(Seq, Payload, State) ->
  send(Seq bor 1, Payload, State).

send(Seq, Payload, #{socket:=Socket, transport:=Transport}=State) when is_map(Payload) ->
  lager:debug("Sending seq ~b : ~p",[Seq, Payload]),
  Data=msgpack:pack(Payload),
  if is_binary(Data) ->
       F=lists:flatten(io_lib:format("log/vmproto_req_~w.bin",[Seq])),
       file:write_file(F,Data),
       ok;
     true ->
       lager:error("Can't encode ~p",[Payload]),
       throw('badarg')
  end,
  Transport:send(Socket, <<Seq:32/big,Data/binary>>),
  State.

