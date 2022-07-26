-module(tpnode_http).
-export([childspec/0, childspec_ssl/2, child_names_ssl/0, get_ssl_port/0, get_ssl_port/1]).


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


get_http_opts(Port,SockOpt) ->
  #{
    connection_type => supervisor,
    socket_opts => [{port,Port}|SockOpt]
  }.


childspec() ->
  Port = application:get_env(tpnode, rpcport, 43280),
  HTTPConnType = get_http_conn_type(),
  [
    ranch:child_spec(
      http,
      ranch_tcp,
      get_http_opts(Port,[]),
      cowboy_clear,
      HTTPConnType
    ),
    ranch:child_spec(
      http6,
      ranch_tcp,
      get_http_opts(Port,[inet6, {ipv6_v6only, true}]),
      cowboy_clear,
      HTTPConnType
    )
  ].


get_ssl_port() ->
  get_ssl_port(43380).

get_ssl_port(DefaultPort) ->
  application:get_env(tpnode, rpcsport, DefaultPort).
  

childspec_ssl(CertFile, KeyFile) ->
  Port = get_ssl_port(),

  CaFile = utils:make_list(CertFile)++".ca.crt",
  SslOpts = [
             {certfile, utils:make_list(CertFile)},
             {keyfile, utils:make_list(KeyFile)}] ++
  case file:read_file_info(CaFile) of
    {ok,_} ->
      [{cacertfile, CaFile}];
    _ ->
      []
  end,

  HTTPConnType = get_http_conn_type(),
  [
    ranch:child_spec(
      https,
      ranch_ssl,
      get_http_opts(Port,SslOpts),
      cowboy_clear,
      HTTPConnType
    ),
    ranch:child_spec(
      https6,
      ranch_ssl,
      get_http_opts(Port,[inet6, {ipv6_v6only, true}|SslOpts]),
      cowboy_clear,
      HTTPConnType
    )
  ].


child_names_ssl() ->
  [https, https6].
