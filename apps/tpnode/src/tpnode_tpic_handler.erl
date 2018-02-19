-module(tpnode_tpic_handler).
-behaviour(tpic_handler).
-export([init/1,handle_tpic/5,routing/1,handle_response/5]).

init(_S) ->
    {ok, #{}}.

routing(_State) ->
    #{ <<"timesync">>=>synchronizer,
       <<"mkblock">>=>mkblock,
       <<"blockvote">>=>blockvote,
       <<"blockchain">>=>blockchain
     }.

handle_tpic(From, _, <<"tping">>, Payload, _State) ->
    Rnd=rand:uniform(300),
    timer:sleep(Rnd),
    tpic:cast(tpic, From, <<"delay ",(integer_to_binary(Rnd))/binary,
                            " pong ",Payload/binary," from ",
                            (atom_to_binary(node(),utf8))/binary>>),
    ok;

handle_tpic(_From, service, <<"discovery">>, Payload, _State) ->
    lager:info("Service discovery ~p",[Payload]),
    gen_server:cast(discovery, {got_announce, Payload}),
    ok;

handle_tpic(_From, service, Hdr, Payload, _State) ->
    lager:info("Service ~p:~p",[Hdr,Payload]),
    ok;

handle_tpic(From, _To, <<"kickme">>, Payload, State) ->
    lager:info("TPIC kick HANDLER from ~p ~p ~p",[From,Payload,State]),
    close;

handle_tpic(From, blockchain, <<"ping">>, Payload, _State) ->
    tpic:cast(tpic, From, <<"pong ",Payload/binary," from ",
                            (atom_to_binary(node(),utf8))/binary>>),
    ok;

handle_tpic(From, blockchain, <<"ledger">>, Payload, _State) ->
    lager:info("Ledger TPIC From ~p p ~p",[From,Payload]),
    ledger:tpic(From, Payload),
    ok;

handle_tpic(From, To, <<>>, Payload, _State) when To==synchronizer orelse
                                                  To==blockvote orelse
                                                  To==mkblock orelse
                                                  To==blockchain ->
    gen_server:cast(To,{tpic,From,Payload}),
    ok;

handle_tpic(From, To, Header, Payload, _State) ->
    lager:info("unknown TPIC ~p from ~p ~p ~p",[To, From,Header,Payload]),
    ok.

handle_response(From, To, _Header, Payload, State) ->
    lager:debug("TPIC resp HANDLER from ~p to ~p: ~p ~p ~p",[From,To,_Header,Payload,State]),
    gen_server:cast(To,{tpic,From,Payload}),
    ok.

