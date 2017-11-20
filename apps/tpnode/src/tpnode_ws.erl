-module(tpnode_ws).
-behaviour(cowboy_http_handler).
-behaviour(cowboy_websocket_handler).
-export([init/3, handle/2, terminate/3]).
-export([
         websocket_init/3, websocket_handle/3,
         websocket_info/3, websocket_terminate/3
        ]).

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

handle(Req, State) ->
    lager:debug("Request not expected: ~p", [Req]),
    {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
    {ok, Req2, State}.

websocket_init(_TransportName, Req, _Opts) ->
    lager:debug("init websocket"),
    {ok, Req, 100}.

websocket_handle({text, _Msg}, Req, 0) ->
    {reply, {text, 
             jsx:encode(#{
               error=><<"subs limit reached">>
              })}, Req, 0, hibernate };

websocket_handle({text, Msg}, Req, State) ->
    try
        JS=jsx:decode(Msg,[return_maps]),
        lager:info("WS ~p",[JS]),
        #{<<"sub">>:=SubT}=JS,
        Ret=case SubT of
                <<"block">> ->
                    gen_server:cast(tpnode_ws_dispatcher,{subscribe,block, self()}),
                    [new_block,any];
                <<"addr">> ->
                    #{<<"addr">>:=Address,<<"get">>:=G}=JS,
                    Get=lists:filtermap(
                          fun(<<"tx">>) -> {true,tx};
                             (<<"bal">>) -> {true,bal};
                             (_) -> false
                          end, binary:split(G,<<",">>,[global])),
                    gen_server:cast(tpnode_ws_dispatcher,{subscribe, address, Address, Get, self()}),
                    [address,Address,Get];
                _ ->
                    undefined
            end,
        {reply, {text, 
                 jsx:encode(#{
                   ok=>true,
                   subscribe=>Ret,
                   moresubs=>State-1
                  })}, Req, State-1, hibernate }
    catch _:_ ->
              lager:error("WS error ~p",[Msg]),
              {ok, Req, State, hibernate}
    end;
    %lager:info("Got Data: ~p from ~p", [Msg,State]),
    %{reply, {text, << "responding to ", Msg/binary >>}, Req, State, hibernate };

websocket_handle(_Any, Req, State) ->
    {reply, {text, << "whut?">>}, Req, State, hibernate }.

websocket_info({message, Msg}, Req, State) ->
%    lager:info("websocket message ~p",[Msg]),
    {reply, {text, Msg}, Req, State};

websocket_info({timeout, _Ref, Msg}, Req, State) ->
    {reply, {text, Msg}, Req, State};

websocket_info(_Info, Req, State) ->
    lager:info("websocket info ~p",[_Info]),
    {ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, _State) ->
    ok.

terminate(_Reason, _Req, _State) ->
    ok.

