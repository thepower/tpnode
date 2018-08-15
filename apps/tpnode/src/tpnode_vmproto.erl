%%%-------------------------------------------------------------------
%% @doc tpnode_vmproto
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_vmproto).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-08-15").

-behaviour(ranch_protocol).

-export([start_link/4, init/4, child_spec/1, loop/3]).
-export([test_client/0]).

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
  Transport:send(Socket, <<"Preved\r\n">>),
%Transport:close(Socket),
  loop(Socket, Transport, #{}).

loop(Socket, Transport, State) ->
  receive
    {tcp, Socket, <<Seq:32/big,Payload/binary>>} ->
      lager:info("Got seq ~b payload ~p",[Seq, Payload]),
      Transport:send(Socket, <<(Seq+1):32/big,"Got ",Payload/binary>>),
      inet:setopts(Socket, [{active, once}]),
      ?MODULE:loop(Socket, Transport, State);
    {tcp_closed, Socket} ->
      Transport:close(Socket);
    Any ->
      lager:info("unknown message ~p",[Any]),
      ?MODULE:loop(Socket, Transport, State)
  end.


test_client() ->
  {ok, Socket} = gen_tcp:connect("127.0.0.1",3333,[{packet,4},binary]),
  inet:setopts(Socket, [{active, once}]),
  receive {tcp, Socket, Message1} ->
            io:format("Got  msg ~p~n",[Message1])
  after 5000 -> 
          io:format("Timeout1~n",[])
  end,
  gen_tcp:send(Socket, <<1234:32/big,"preved">>),
  inet:setopts(Socket, [{active, once}]),
  receive {tcp, Socket, <<Seq:32/big,Message2/binary>>} ->
            io:format("Got ~b msg ~p~n",[Seq,Message2])
  after 5000 -> 
          io:format("Timeout2~n",[])
  end,
  gen_tcp:close(Socket).


