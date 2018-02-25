-module(tpnode_xchain).
-export([childspec/0]).

childspec() ->
    HTTPDispatch = cowboy_router:compile(
        [
            {'_', [
                {"/", ws_xchain_handler, []}
            ]}
        ]),
    CrossChainOpts = application:get_env(tpnode, crosschain, #{}),
    CrossChainPort = maps:get(port, CrossChainOpts, 43311),


    HTTPOpts=[{connection_type,supervisor}, {port, CrossChainPort}],
    HTTPConnType=#{connection_type => supervisor,
        env => #{dispatch => HTTPDispatch}},
    HTTPAcceptors=10,
    ranch:child_spec(crosschain_api,
        HTTPAcceptors,
        ranch_tcp,
        HTTPOpts,
        cowboy_clear,
        HTTPConnType).
