% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain).

%% API
-export([pack/2, unpack/2, pack_chid/1, childspec/0]).


% -----------

pack(Term, 0) ->
    term_to_binary(Term);

pack(Atom, 2) when is_atom(Atom) ->
  pack(#{null=>atom_to_binary(Atom,utf8)},2);

pack({node_id, MyNodeId, Channels}, 2) ->
  pack(#{null=><<"node_id">>,
    <<"node_id">>=>MyNodeId,
    <<"channels">>=>Channels},2);

pack({subscribe, Channel}, 2) ->
  pack(#{null=><<"subscribe">>,
    <<"channel">>=>Channel},2);

pack({xdiscovery, Announce}, 2) ->
  pack(#{null=><<"xdiscovery">>, <<"bin">>=>Announce},2);

pack(Term, 2) when is_tuple(Term) ->
  pack(tuple_to_list(Term),2);

pack(Term, 2) ->
    msgpack:pack(Term).

% -----------

unpack(Bin,0) when is_binary(Bin) ->
  binary_to_term(Bin, [safe]);

unpack(Bin,2) when is_binary(Bin) ->
  {ok,Res}=msgpack:unpack(Bin),
  if is_list(Res) ->
       list_to_tuple(Res);
     true ->
       Res
  end;

unpack(Invalid, _) ->
    lager:info("xchain got invalid data for unpack ~p", [Invalid]),
    {}.

% -----------

pack_chid(I) when is_integer(I) ->
    <<"ch:", (integer_to_binary(I))/binary>>.

% -----------

childspec() ->
    HTTPDispatch = cowboy_router:compile(
        [
            {'_', [
                {"/xchain/ws", xchain_server, []},
                {"/", xchain_server, []}, %deprecated
                {"/xchain/api/[...]", apixiom, {xchain_api, #{}}}
            ]}
        ]),
    CrossChainOpts = application:get_env(tpnode, crosschain, #{}),
    CrossChainPort = maps:get(port, CrossChainOpts, 43311),


    HTTPOpts=[{connection_type, supervisor}, {port, CrossChainPort}],
    HTTPConnType=#{connection_type => supervisor,
        env => #{dispatch => HTTPDispatch}},
    [
        ranch:child_spec(crosschain_api,
            ranch_tcp,
            HTTPOpts,
            cowboy_clear,
            HTTPConnType),

        ranch:child_spec(crosschain_api6,
            ranch_tcp,
            [inet6, {ipv6_v6only, true}|HTTPOpts],
            cowboy_clear,
            HTTPConnType)
    ].

