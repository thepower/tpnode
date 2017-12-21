-module(tpic).
-author("cleverfox <devel@viruzzz.org>").

-export([cast/3]).
-export([call/3,call/4]).

cast(TPIC, Service, Message) when is_binary(Service) ->
    gen_server:cast(TPIC, {broadcast, self(), Service, Message});

cast(TPIC, Conn, Message) when is_tuple(Conn) ->
    gen_server:cast(TPIC, {unicast, self(), Conn, Message}).

call(TPIC, Conn, Request) -> 
    call(TPIC, Conn, Request, 2000).

call(TPIC, Service, Request, Timeout) when is_binary(Service) -> 
    R=gen_server:call(TPIC,{broadcast, self(), Service, Request}),
    T2=erlang:system_time(millisecond)+Timeout,
    wait_response(T2,R,[]);

call(TPIC, Conn, Request, Timeout) when is_tuple(Conn) -> 
    R=gen_server:call(TPIC,{unicast, self(), Conn, Request}),
    T2=erlang:system_time(millisecond)+Timeout,
    wait_response(T2,R,[]).

wait_response(_Until,[],Acc) ->
    Acc;

wait_response(Until,[R1|RR],Acc) ->
    lager:debug("Waiting for reply"),
    T1=Until-erlang:system_time(millisecond),
    T=if(T1>0) -> T1;
        true -> 0
      end,
    receive 
        {'$gen_cast',{tpic,R1,A}} ->
            {ok,Response}=msgpack:unpack(A),
            lager:debug("Got reply from ~p ~p",[R1,Response]),
            wait_response(Until,RR,[{R1,Response}|Acc])
    after T ->
              wait_response(Until,RR,Acc)
    end.


