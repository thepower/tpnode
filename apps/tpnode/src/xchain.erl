% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(xchain).

%% API
-export([pack/1, unpack/1, pack_chid/1, childspec/0]).


% -----------

pack(Term) ->
    term_to_binary(Term).

% -----------

unpack(Bin) when is_binary(Bin) ->
    binary_to_term(Bin, [safe]);

unpack(Invalid) ->
    lager:info("xchain got invalid data for unpack ~p", [Invalid]),
    {}.

% -----------

pack_chid(I) when is_integer(I) ->
    <<"ch:",(integer_to_binary(I))/binary>>.

% -----------

childspec() ->
    HTTPDispatch = cowboy_router:compile(
        [
            {'_', [
                {"/xchain/ws", xchain_server, []},
                {"/", xchain_server, []},
                {"/xchain/api/[...]", apixiom, {xchain_api,#{}}}
            ]}
        ]),
    CrossChainOpts = application:get_env(tpnode, crosschain, #{}),
    CrossChainPort = maps:get(port, CrossChainOpts, 43311),


    HTTPOpts=[{connection_type,supervisor}, {port, CrossChainPort}],
    HTTPConnType=#{connection_type => supervisor,
        env => #{dispatch => HTTPDispatch}},
    HTTPAcceptors=10,
    [
        ranch:child_spec(crosschain_api,
            HTTPAcceptors,
            ranch_tcp,
            HTTPOpts,
            cowboy_clear,
            HTTPConnType),

        ranch:child_spec(crosschain_api6,
            HTTPAcceptors,
            ranch_tcp,
            [inet6,{ipv6_v6only,true}|HTTPOpts],
            cowboy_clear,
            HTTPConnType)
    ].

