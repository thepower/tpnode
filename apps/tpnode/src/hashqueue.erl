-module(hashqueue).
-export([new/0,
         add/4,
         remove/2,
         pop/1,
         head/1,
         test/0
        ]).

new() ->
    {
     queue:new(),
     #{}
    }.

add(Key,Timestamp,Value,{Q,H}) ->
    {
     queue:in({Key,Timestamp},Q),
     maps:put(Key,Value,H)
    }.

remove(Key,{Q,H}) ->
    {Q,
     maps:remove(Key,H)
    }.

head({Q,_H}) ->
    case queue:is_empty(Q) of
        true ->
            empty;
        false ->
            {_,T}=queue:head(Q),
            T
    end.

pop({Q,H}) ->
    case queue:out(Q) of
        {empty, Q2} ->
            {{Q2, #{}},empty};
        {{value,{K,_}},Q1} ->
            case maps:is_key(K,H) of 
                true ->
                    {{Q1,maps:remove(K,H)},{K,maps:get(K,H)}};
                false ->
                    pop({Q1,H})
            end
    end.

test() ->
    QH0=new(),
    io:format("~p~n",[head(QH0)]),
    QH1=add(key1,10,val1,QH0),
    QH2=add(key2,10,val2,QH1),
    QH3=add(key3,10,val3,QH2),
    QH4=add(key4,13,val4,QH3),
    QH5=add(key5,13,val5,QH4),
    io:format("~p~n",[head(QH1)]),
    io:format("~p~n",[head(QH5)]),
    io:format("~p~n",[QH5]),
    {QH6,{key1,val1}=R1}=pop(QH5),
    {QH7,{key2,val2}=R2}=pop(QH6),
    io:format("~p ~p~n",[R1, head(QH6)]),
    io:format("~p ~p~n",[R2, head(QH7)]),
    QH8=remove(key3,QH7),
    QH9=remove(key4,QH8),
    {QH10,{key5,val5}=R3}=pop(QH9),
    io:format("~p ~p~n",[R3, head(QH10)]),
    io:format("~p~n",[QH9]),
    {_,empty}=pop(QH10),
    ok.

    
