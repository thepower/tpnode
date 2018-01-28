-module(tpnode_tpic_handler).
-behaviour(tpic_handler).
-export([init/1,handle_tpic/5,routing/1,handle_response/5]).

init(_S) ->
    {ok, #{}}.

routing(_State) ->
    #{
          <<"timesync">>=>synchronizer,
          <<"mkblock">>=>mkblock,
          <<"blockvote">>=>blockvote,
          <<"blockchain">>=>blockchain
         }.

handle_tpic(From, _To, <<"kickme">>, Payload, State) ->
    lager:info("TPIC kick HANDLER from ~p ~p ~p",[From,Payload,State]),
    close;

handle_tpic(From, To, _Header, Payload, _State) when To==synchronizer orelse
                                                     To==blockvote->
    %lager:debug("Payload to ~p from ~p ~p", [To, Assoc, SID]),
    gen_server:cast(To,{tpic,From,Payload}),
    ok;

handle_tpic(From, To, Header, Payload, State) ->
    lager:info("TPIC ~p HANDLER from ~p ~p ~p ~p",[To, From,Header,Payload,State]),
    ok.

handle_response(From, To, Header, Payload, State) ->
    lager:info("TPIC resp HANDLER from ~p to ~p: ~p ~p ~p",[From,To,Header,Payload,State]),
    ok.
