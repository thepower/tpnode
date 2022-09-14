-module(tpnode_tpic_handler).
-include("include/tplog.hrl").
%-behaviour(tpic_handler).
-export([handle_tpic/5, handle_response/5]).

handle_tpic(From, _, <<"tping">>, Payload, _State) ->
  ?LOG_DEBUG("tping"),
  Rnd=rand:uniform(300),
  timer:sleep(Rnd),
  ?LOG_INFO("TPIC tping ~p", [_State]),
  tpic2:cast(From, <<"delay ", (integer_to_binary(Rnd))/binary,
                     " pong ", Payload/binary, " from ",
                     (atom_to_binary(node(), utf8))/binary>>,[async]),
  ok;

handle_tpic(From, _, <<"ping">>, Payload, _State) ->
  R=tpic2:cast(From, <<"pong ", Payload/binary, " from ",
                       (atom_to_binary(node(), utf8))/binary>>, [async]),
  ?LOG_INFO("got ping from ~p payload ~p, res ~p",[From, Payload, R]),
  ok;

% beacon announce
handle_tpic(From, <<"mkblock">>, <<"beacon">>, Beacon, _State) ->
  ?LOG_DEBUG("Beacon ~p", [Beacon]),
  gen_server:cast(topology, {got_beacon, From, Beacon}),
  ok;

% relayed beacon announce
handle_tpic(From, <<"mkblock">>, <<"beacon2">>, Beacon, _State) ->
  ?LOG_DEBUG("Beacon2 ~p", [Beacon]),
  gen_server:cast(topology, {got_beacon2, From, Beacon}),
  ok;

handle_tpic({Pub,_,_}=From, <<"txpool">>, <<>>, Payload, _State) ->
  ?LOG_DEBUG("txbatch: form ~p payload ~p", [ From, Payload ]),
  gen_server:cast(txstorage, {tpic, Pub, From, Payload}),
  ok;

handle_tpic({Pub,_,_}=From, <<"mkblock">>, <<>>, Payload, _State) ->
  ?LOG_DEBUG("mkblock from ~p payload ~p",[From,Payload]),
  gen_server:cast(mkblock, {tpic, Pub, Payload}),
  ok;

handle_tpic(_From, 0, <<"discovery">>, Payload, _State) ->
  ?LOG_DEBUG("Service discovery from ~p payload ~p", [_From,Payload]),
  gen_server:cast(discovery, {got_announce, Payload}),
  ok;

handle_tpic(_From, 0, Hdr, Payload, _State) ->
  ?LOG_INFO("Service from ~p hdr ~p payload ~p", [_From, Hdr, Payload]),
  ok;

handle_tpic(From, _To, <<"kickme">>, Payload, State) ->
  ?LOG_INFO("TPIC kick HANDLER from ~p ~p ~p", [From, _To, Payload, State]),
  close;


handle_tpic(From, <<"blockchain">>, <<"ledger">>, Payload, _State) ->
  ?LOG_INFO("==IGNORE MSG== Ledger TPIC From ~p p ~p", [From, Payload]),
  %ledger:tpic(From, Payload),
  ok;

handle_tpic({NodeKey,_,_}=From, <<"blockchain">>, <<"chainkeeper">>, Payload, _State) ->
  NodeName = chainsettings:is_our_node(NodeKey),
  ?LOG_DEBUG("Got chainkeeper beacon From ~p p ~p", [From, Payload]),
  gen_server:cast(chainkeeper, {tpic, NodeName, From, Payload}),
  ok;

handle_tpic(From, <<"blockchain">>, <<>>, Payload, _State) ->
  ?LOG_DEBUG("Generic TPIC to ~p from ~p payload ~p", [blockchain,From,Payload]),
  gen_server:cast(blockchain_reader, {tpic, From, Payload}),
  ok;

handle_tpic({Pub,_,_}=From, <<"mkblock">>, <<>>, Payload, _State) ->
  ?LOG_DEBUG("Generic TPIC to ~p from ~p payload ~p", [mkblock,From,Payload]),
  gen_server:cast(mkblock, {tpic, Pub, Payload}),
  ok;

handle_tpic(From, <<"blockvote">>, <<>>, Payload, _State) ->
  ?LOG_DEBUG("Generic TPIC to ~p from ~p payload ~p", [blockvote,From,Payload]),
  gen_server:cast(blockvote, {tpic, From, Payload}),
  ok;

handle_tpic(From, To, Header, Payload, _State) ->
  ?LOG_INFO("unknown TPIC ~p from ~p ~p ~p", [To, From, Header, Payload]),
  ok.

handle_response(From, To, _Header, Payload, State) ->
  ?LOG_DEBUG("TPIC resp HANDLER from ~p to ~p: ~p ~p ~p", [From, To, _Header, Payload, State]),
  gen_server:cast(To, {tpic, From, Payload}),
  ok.

