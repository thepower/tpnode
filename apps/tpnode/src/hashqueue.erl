-module(hashqueue).
-export([new/0,
         add/4,
         remove/2,
         pop/1,
         get/2,
         head/1
        ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

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

get(Key,{_Q,H}) ->
    maps:get(Key,H,undefined).

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

-ifdef(TEST).
default_test() ->
    QH0=new(),
    QH1=add(key1,10,val1,QH0),
    QH2=add(key2,10,val2,QH1),
    QH3=add(key3,10,val3,QH2),
    QH4=add(key4,13,val4,QH3),
    QH5=add(key5,13,val5,QH4),
    {QH6,R1}=pop(QH5),
    {QH7,R2}=pop(QH6),
    QH8=remove(key3,QH7),
    QH9=remove(key4,QH8),
    {QH10,R3}=pop(QH9),
    [
    ?_assertEqual(empty,head(QH0)),
    ?_assertEqual(10,head(QH1)),
    ?_assertEqual(10,head(QH5)),
    ?_assertEqual({key1,val1},R1),
    ?_assertEqual({key2,val2},R2),
    ?_assertEqual(10,head(QH6)),
    ?_assertEqual(10,head(QH7)),
    ?_assertEqual({key5,val5},R3),
    ?_assertEqual(empty,head(QH10)),
    ?_assertMatch(val4,get(key4,QH5)),
    ?_assertMatch(undefined,get(key4,QH10)),
    ?_assertMatch({_,empty},pop(QH10))
    ].

-endif.
    
