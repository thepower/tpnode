-module(erun_http).
-export([childspec/0, childspec_ssl/2, child_names_ssl/0, get_ssl_port/0, get_ssl_port/1]).

get_http_conn_type() ->
  HTTPDispatch = cowboy_router:compile(
    [
      {'_', [
        {"/erun/[...]", apixiom, {erun_httpapi, #{}}}
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
  Port = application:get_env(erun, rpcport, 30080),
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


get_ssl_port() ->
  get_ssl_port(43380).

get_ssl_port(DefaultPort) ->
  application:get_env(erun, rpcsport, DefaultPort).
  

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

  HTTPOpts = get_http_opts(Port) ++ SslOpts,
  HTTPConnType = get_http_conn_type(),
  [
    ranch:child_spec(
      https,
      ranch_ssl,
      HTTPOpts,
      cowboy_clear,
      HTTPConnType
    ),
    ranch:child_spec(
      https6,
      ranch_ssl,
      [inet6, {ipv6_v6only, true} | HTTPOpts],
      cowboy_clear,
      HTTPConnType
    )
  ].


child_names_ssl() ->
  [https, https6].
