-module(tpnode_ws).
-export([init/2]).
-export([
         websocket_init/1, websocket_handle/2,
         websocket_info/2
        ]).

init(Req, Opts) ->
    {cowboy_websocket, Req, Opts, #{
                              idle_timeout => 600000
                             }}.

websocket_init(_State) ->
    lager:debug("init websocket"),
    {ok, 100}.

websocket_handle({text, _Msg}, 0) ->
    {reply, {text,
             jsx:encode(#{
               error=><<"subs limit reached">>
              })}, 0};

websocket_handle({text, <<"ping">>}, State) ->
    {ok, State};

websocket_handle({text, Msg}, State) ->
    try
        JS=jsx:decode(Msg, [return_maps]),
        lager:info("WS ~p", [JS]),
        #{<<"sub">>:=SubT}=JS,
        Ret=case SubT of
                <<"block">> ->
                    gen_server:cast(tpnode_ws_dispatcher, {subscribe, block, self()}),
                    [new_block, any];
                <<"tx">> ->
                    gen_server:cast(tpnode_ws_dispatcher, {subscribe, tx, self()}),
                    [tx, any];
                <<"addr">> ->
                    #{<<"addr">>:=Address, <<"get">>:=G}=JS,
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
              lager:error("WS error ~p", [Msg]),
              {ok, State}
    end;

websocket_handle(_Any, State) ->
    {reply, {text, << "whut?">>}, State}.

websocket_info({message, Msg}, State) ->
%    lager:info("websocket message ~p", [Msg]),
    {reply, {text, Msg}, State};

websocket_info({timeout, _Ref, Msg}, State) ->
    {reply, {text, Msg}, State};

websocket_info(_Info, State) ->
    lager:info("websocket info ~p", [_Info]),
    {ok, State}.


