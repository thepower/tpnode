-module(contract_nft).
-behaviour(smartcontract).

-export([deploy/6, handle_tx/4, getters/0, get/3, info/0]).

info() ->
  {<<"nft">>, <<"non-fungible tokens">>}.

deploy(_Address, _Ledger, Code, _State, _GasLimit, _GetFun) ->
  #{owner:=Owner,
    token:=TokenName}=erlang:binary_to_term(Code, [safe]),
  {ok, term_to_binary(#{
         owner=>Owner,
         issued=>0,
         bals=>#{},
         token=>TokenName
        })}.

handle_tx(#{from:=From, to:=MyAddr, extradata:=JSON}=_Tx, #{state:=MyState}=_Ledger, _GasLimit, _GetFun) ->
  State=erlang:binary_to_term(MyState, [safe]),
  #{<<"nft_to">>:=ToH,<<"nft_val">>:=Val}=jsx:decode(JSON, [return_maps]),
  To=naddress:decode(ToH),
  lager:info("From ~p ~p",[From,MyAddr]),
  lager:info("JSON ~p",[[To,Val]]),
  lager:info("State ~p",[State]),
  {ok, unchanged, 0}.

getters() ->
  [{<<"issued">>,[]},
   {<<"bal">>,[{<<"Address"/utf8>>,addr}]}
  ].

get(<<"issued">>,[],#{state:=MyState}) ->
  #{issued:=I}=erlang:binary_to_term(MyState, [safe]),
  I;

get(_,_,_Ledger) ->
  throw("unknown method").


