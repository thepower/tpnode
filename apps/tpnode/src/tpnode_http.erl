-module(tpnode_http).
-export([childspec/0]).

childspec() ->
    HTTPDispatch = cowboy_router:compile(
                     [
                      {'_', [
                             {"/api/ws", tpnode_ws, []},
                             {"/api/[...]", apixiom, {tpnode_httpapi,#{}}},
                             {"/[...]", cowboy_static, 
                              {dir, "public", 
                               [
                                {mimetypes, cow_mimetypes, all},
                                {dir_handler, directory_handler}
                               ]
                              }
                             }
                            ]}
                     ]),
    HTTPOpts=[{connection_type,supervisor},
              {port,
               application:get_env(tpnode,rpcport,43280)
              }],
    HTTPConnType=#{connection_type => supervisor,
                   env => #{dispatch => HTTPDispatch}},
    HTTPAcceptors=10,
    ranch:child_spec(http,
                     HTTPAcceptors,
                     ranch_tcp, 
                     HTTPOpts,
                     cowboy_clear,
                     HTTPConnType).



