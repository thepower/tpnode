%%%-------------------------------------------------------------------
%% @doc tpnode_vmproto
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_vmproto).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-08-15").
-include("include/tplog.hrl").

-behaviour(ranch_protocol).

-export([start_link/4, init/4, childspec/1, childspec/2, loop/1]).
-export([req/2, reply/3]).

-record(req,
        {owner,
         t1
        }).

childspec(Host, Port) ->
  PC=[{port,Port}], %, {max_connections, 128}
  CC=#{
       connection_type => supervisor,
       socket_opts => %[inet6,{ipv6_v6only,true},{port,43381}]
       case Host of
         any ->
           PC;
         _ ->
           [{ip,Host}|PC]
       end
      },
  [
   ranch:child_spec(vm_listener, %{vm_listener,Port},
                    ranch_tcp,
                    CC,
                    ?MODULE,
                    [])
  ].


childspec(Port) ->
  childspec(any, Port).

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
      %?LOG_INFO("Got seq ~b payload ~p",[Seq,Data]),
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
      ?LOG_INFO("Client gone"),
      maps:fold(
        fun(ReqID,#req{owner=Owner},_Acc) ->
            Owner ! {result, ReqID, {error, vm_gone}}
        end, 0, Reqs),
      Transport:close(Socket);
    {ping, From} ->
      From ! {run_req, 0},
      From ! {result, 0, pong},
      ?MODULE:loop(State);
    {run, Transaction, Ledger, Gas, From, ExtraFields} = _ALL ->
      Seq=maps:get(myseq, State, 0),
      S1=req(
           maps:merge(
             ExtraFields,
             #{null=>"exec",
               "tx"=>Transaction,
               "ledger"=>Ledger,
               "gas"=>Gas}
            ), State),
      From ! {run_req, Seq},
      ?LOG_DEBUG("run tx ~p",[Seq]),
      R=#req{owner=From,t1=erlang:system_time()},
      ?MODULE:loop(S1#{reqs=>maps:put(Seq,R,Reqs)});
    Any ->
      ?LOG_INFO("unknown message ~p",[Any]),
      ?MODULE:loop(State)
  end.

handle_req(Seq, #{null:="hello"}=Request, State) ->
  ?LOG_DEBUG("Got seq ~b hello ~p",[Seq, Request]),
  reply(Seq, Request, State),
  ok=gen_server:call(tpnode_vmsrv,{register, self(), Request}),
  State;

handle_req(Seq, Request, State) ->
  ?LOG_INFO("Got req seq ~b payload ~p",[Seq, Request]),
  State.

handle_res(Seq, Result, #{reqs:=Reqs}=State) ->
  case maps:find(Seq, Reqs) of
    error ->
      ?LOG_INFO("Got res seq ~b payload ~p",[Seq, Result]),
      State;
    {ok, #req{owner=Pid, t1=T1}} ->
      ?LOG_DEBUG("Got res seq ~b payload ~p",[Seq, Result]),
      Pid ! {result, Seq, {ok, Result, #{t=>erlang:system_time()-T1}}},
      State#{reqs=>maps:remove(Seq, Reqs)}
  end. 

req(Payload, #{myseq:=MS}=State) ->
  Seq=MS bsl 1,
  send(Seq, Payload, State#{myseq=>MS+1}).

reply(Seq, Payload, State) ->
  send(Seq bor 1, Payload, State).

send(Seq, Payload, #{socket:=Socket, transport:=Transport}=State) when is_map(Payload) ->
  ?LOG_DEBUG("Sending seq ~b : ~p",[Seq, Payload]),
  Data=msgpack:pack(Payload),
  if is_binary(Data) ->
       %F=lists:flatten(io_lib:format("log/vmproto_req_~w.bin",[Seq])),
       %file:write_file(F,Data),
       Transport:send(Socket, <<Seq:32/big,Data/binary>>),
       ok;
     true ->
       ?LOG_ERROR("Can't encode ~p",[Payload]),
       throw('badarg')
  end,
  State.

