%%%-------------------------------------------------------------------
%% @doc tpnode_vmproto
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_vmproto).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-08-15").

-behaviour(ranch_protocol).

-export([start_link/4, init/4, child_spec/1, loop/1]).
-export([test_client/0]).

-record(req,
        {owner,
         t1
        }).

child_spec(Port) ->
  ranch:child_spec(
    {wm_listener,Port}, ranch_tcp,
    [{port, Port}, {max_connections, 128}],
    ?MODULE,
    []
   ).

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
            Owner ! {result, ReqID, error}
        end, 0, Reqs),
      Transport:close(Socket);
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

%  send(2, #{null=>"exec",
%            "gas" => 11111,
%            "ledger" => <<130,164,99,111,100,101,196,0,
%                          165,115,116,97,116,101,196,69,
%                          129,196,32,88,88, 88,88,88,
%                          88,88,88,88,88,88,88,88,
%                          88,88,88,88,88,88,88,88,
%                          88,88,88,88,88,88,88,88,
%                          88,88,88,196,32,89,89,89,
%                          89,89,89,89,89,89,89,89,
%                          89,89,89,89,89,89,89,89,
%                          89,89,89,89,89,89,89,89,
%                          89,89,89,89,89>>,
%            "tx" => testtx()
%           }, State);

            %      'ledger': dumps({'code': b'', 'state': dumps({b'X'*32: b'Y'*32})}),
            %      'tx': dumps({'ver': 2, 'body': dumps({
            %        'k': 18,
            %        'f': b'\x80\x00 \x00\x02\x00\x00\x03',
            %        'p': [[0, 'XXX', 10], [1, 'FEE', 20]],
            %        'to': b'\x80\x00 \x00\x02\x00\x00\x05',
            %        's': 5,
            %        't': 1530106238743,
            %        'c': ['init', [0xBEAF]],
            %        'e': {'code': bytearray(read('../rust/test1.wasm'))}

handle_req(Seq, Request, State) ->
  lager:info("Got req seq ~b payload ~p",[Seq, Request]),
  State.

handle_res(Seq, Result, #{reqs:=Reqs}=State) ->
  case maps:find(Seq, Reqs) of
    error ->
      lager:info("Got res seq ~b payload ~p",[Seq, Result]),
      State;
    {ok, #req{owner=Pid, t1=T1}} ->
      Pid ! {result, Seq, Result, erlang:system_time()-T1},
      State#{reqs=>maps:remove(Seq, Reqs)}
  end. 

req(Payload, #{myseq:=MS}=State) ->
  Seq=MS bsl 1,
  send(Seq, Payload, State#{myseq=>MS+1}).

reply(Seq, Payload, State) ->
  send(Seq bor 1, Payload, State).

send(Seq, Payload, #{socket:=Socket, transport:=Transport}=State) when is_map(Payload) ->
  lager:debug("Sending seq ~b ~p",[Seq, Payload]),
  Data=msgpack:pack(Payload),
  %lager:info("sending ~s",[base64:encode(Data)]),
  Transport:send(Socket, <<Seq:32/big,Data/binary>>),
  State.

test_client() ->
  {ok, Socket} = gen_tcp:connect("127.0.0.1",5555,[{packet,4},binary]),
  inet:setopts(Socket, [{active, once}]),
  Send=fun(N,MP) ->
           gen_tcp:send(Socket,<<N:32/big, (msgpack:pack(MP))/binary>>)
       end,
  Send(0,#{null => "hello","lang" => "wasm","ver" => 2}),
  receive {tcp, Socket, Message1} ->
            io:format("Got msg ~p~n",[Message1])
  after 5000 -> 
          io:format("Timeout1~n",[])
  end,
  test_client_continue(Socket).

test_client_continue(Socket) ->
  Send=fun(N,MP) ->
           gen_tcp:send(Socket,<<N:32/big, (msgpack:pack(MP))/binary>>)
       end,
  inet:setopts(Socket, [{active, once}]),
  receive {tcp, Socket, <<Seq:32/big,Message2/binary>>} ->
            {ok,Msg}=msgpack:unpack(Message2),
            io:format("Got ~b msg ~p~n",[Seq,Msg]),
            Send(Seq bor 1,#{null => "exec","state" => <<" ">>,"txs" => []}),
            test_client_continue(Socket)
  after 5000 -> 
          io:format("Timeout2~n",[]),
          gen_tcp:close(Socket)
  end.

