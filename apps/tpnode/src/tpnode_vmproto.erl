%%%-------------------------------------------------------------------
%% @doc tpnode_vmproto
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_vmproto).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-08-15").

-behaviour(ranch_protocol).

-export([start_link/4, init/4, child_spec/1, loop/1]).
-export([test_client/0, testtx/0]).

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
  loop(#{socket=>Socket, transport=>Transport}).

loop(#{socket:=Socket, transport:=Transport}=State) ->
  receive
    {tcp, Socket, <<Seq:32/big,Data/binary>>} ->
      {ok,Payload}=msgpack:unpack(Data),
      handle(Seq, Payload, State),
      inet:setopts(Socket, [{active, once}]),
      ?MODULE:loop(State);
    {tcp_closed, Socket} ->
      lager:info("Client gone"),
      Transport:close(Socket);
    Any ->
      lager:info("unknown message ~p",[Any]),
      ?MODULE:loop(State)
  end.

handle(Seq, #{null:="hello"}=Request, State) ->
  lager:info("Got seq ~b hello ~p",[Seq, Request]),
  send(Seq bor 1, Request, State),

  send(2, #{null=>"exec",
            "gas" => 11111,
            "ledger" => <<130,164,99,111,100,101,196,0,
                          165,115,116,97,116,101,196,69,
                          129,196,32,88,88, 88,88,88,
                          88,88,88,88,88,88,88,88,
                          88,88,88,88,88,88,88,88,
                          88,88,88,88,88,88,88,88,
                          88,88,88,196,32,89,89,89,
                          89,89,89,89,89,89,89,89,
                          89,89,89,89,89,89,89,89,
                          89,89,89,89,89,89,89,89,
                          89,89,89,89,89>>,
            "tx" => testtx()
           }, State);

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



handle(Seq, Request, _State) ->
  lager:info("Got seq ~b payload ~p",[Seq, Request]).

send(Seq, Payload, #{socket:=Socket, transport:=Transport}=_State) when is_map(Payload) ->
  lager:info("Sending seq ~b ~p",[Seq, Payload]),
  Data=msgpack:pack(Payload),
  %lager:info("sending ~s",[base64:encode(Data)]),
  Transport:send(Socket, <<Seq:32/big,Data/binary>>).

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

testtx() ->
  tx:pack(#{body =>
            base64:decode(<<"iKFrEqFmxAiAACAAAgAAA6FwkpMAo1hYWAqTAaNGRUUUonRvxAiAACAAAgAABaFzBaF0zwAAAWRBcFcXoWOSpGluaXSRzb6voWWBpGNvZGXFAukAYXNtAQAAAAEWBWABfwBgAn9/AGAAAX9gAX4BfmAAAAJMBANlbnYMX2ZpbGxfc3RydWN0AAADZW52Cl9wcmludF9zdHIAAANlbnYMc3RvcmFnZV9yZWFkAAEDZW52DXN0b3JhZ2Vfd3JpdGUAAQMHBgECAwMEAAQEAXAAAAUDAQABBykFBm1lbW9yeQIABG5hbWUABQRpbml0AAYDZ2V0AAgIZ2V0X2RhdGEACQkBAAqiAwajAQEEf0EAQQAoAgRBIGsiBTYCBCAFQRhqIgJC2rTp0qXLlq3aADcDACAFQRBqIgNC2rTp0qXLlq3aADcDACAFQQhqIgRC2rTp0qXLlq3aADcDACAFQtq06dKly5at2gA3AwAgASAFEAIgAEEYaiACKQMANwAAIABBEGogAykDADcAACAAQQhqIAQpAwA3AAAgACAFKQMANwAAQQAgBUEgajYCBAsEAEEQCzYBAX9BAEEAKAIEQSBrIgE2AgRBIBABQTBB0AAQAyABQTAQBCAAEAchAEEAIAFBIGo2AgQgAAsLACAAQoCAtPUNhAskAQF/QQBBACgCBEEgayIANgIEIABB8AAQBEEAIABBIGo2AgQLjQEBBH9BAEEAKAIEQSBrIgQ2AgQgBEEYaiIBQQApA6gBNwMAIARBEGoiAkEAKQOgATcDACAEQQhqIgNBACkDmAE3AwAgBEEAKQOQATcDACAEEAAgAEEYaiABKQMANwAAIABBEGogAikDADcAACAAQQhqIAMpAwA3AAAgACAEKQMANwAAQQAgBEEgajYCBAsLkQEFAEEQCwl0ZXN0IG5hbWUAQSALDFRFU1QgU1RSSU5HAABBMAsgQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEAQdAACyBCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQgBBkAELIEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8A">>),
            sig => [],
            ver => 2}).

