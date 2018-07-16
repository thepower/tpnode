-module(tpnode_http).
-export([childspec/0, childspec_ssl/2]).


get_http_conn_type() ->
  HTTPDispatch = cowboy_router:compile(
    [
      {'_', [
        {"/api/ws", tpnode_ws, []},
        {"/api/[...]", apixiom, {tpnode_httpapi, #{}}},
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
  #{
    connection_type => supervisor,
    env => #{
      dispatch => HTTPDispatch
    }
  }.


get_http_opts(Port) ->
  [
    {connection_type, supervisor},
    {port, Port}
  ].


childspec() ->
  Port = application:get_env(tpnode, rpcport, 43280),
  HTTPOpts = get_http_opts(Port),
  HTTPConnType = get_http_conn_type(),
  [
    ranch:child_spec(
      http,
      ranch_tcp,
      HTTPOpts,
      cowboy_clear,
      HTTPConnType
    ),
    ranch:child_spec(
      http6,
      ranch_tcp,
      [inet6, {ipv6_v6only, true} | HTTPOpts],
      cowboy_clear,
      HTTPConnType
    )
  ].


childspec_ssl(CertFile, KeyFile) ->
  Port = application:get_env(tpnode, rpcsport, 43380),
  SslOpts = [
    {certfile, utils:make_list(CertFile)},
    {keyfile, utils:make_list(KeyFile)}],
  HTTPOpts = [ get_http_opts(Port) | SslOpts ],
  HTTPConnType = get_http_conn_type(),
  [
    ranch:child_spec(
      https,
      ranch_tcp,
      HTTPOpts,
      cowboy_clear,
      HTTPConnType
    ),
    ranch:child_spec(
      https6,
      ranch_tcp,
      [inet6, {ipv6_v6only, true} | HTTPOpts],
      cowboy_clear,
      HTTPConnType
    )
  ].
