-module(tpnode_http).
-export([childspec/0,
         childspec_ssl/0,
         childspec_ssl/2,
         child_names_ssl/0,
         get_ssl_port/0,
         get_ssl_port/1]).


get_http_conn_type() ->
  HTTPDispatch = cowboy_router:compile(
    [
      {'_', [
        {"/api/ws", tpnode_ws, []},
        {"/api/[...]", apixiom, {tpnode_httpapi, #{}}},
        {"/", cowboy_static, {priv_file, tpnode, "index.html"}},
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
  

childspec_ssl() ->
  CertFile=tpnode_cert:get_cert_file(),
  KeyFile=tpnode_cert:get_cert_key_file(),
  childspec_ssl(CertFile, KeyFile).

childspec_ssl(CertFile, KeyFile) ->
  Port = get_ssl_port(false),

  case ensure_cert(CertFile, KeyFile) of
    true when is_integer(Port) ->
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
      ];
    _ ->
      []
  end.


child_names_ssl() ->
  [https, https6].

ensure_cert(CertFile, KeyFile) ->
  Hostname=application:get_env(tpnode, hostname, false),
  if Hostname==false ->
       false;
     true ->
       case file:read_file(KeyFile) of
         {ok, _} ->
           ok;
         _ ->
           filelib:ensure_dir(KeyFile),
           gen_priv(KeyFile)
       end,
       CertExists=case file:read_file(CertFile) of
                    {ok, _} -> true;
                    _ -> false
                  end,
       if(not CertExists) ->
           selfsigned(CertFile, KeyFile, Hostname),
           case file:read_file(CertFile) of
             {ok, _} -> true;
             _ -> false
           end;
         (CertExists) ->
           true
       end
  end.

gen_priv(KeyFile) ->
  OpenSSL=os:find_executable("openssl"),
  H=erlang:open_port(
    {spawn_executable, OpenSSL},
    [{args, [
             "genrsa", "2048"
            ]},
     eof,
     binary
    ]),
  Bin=cert_loop(H),
  file:write_file(KeyFile, Bin).

cert_loop(Handle) ->
  receive
    {Handle, {data, Msg}} ->
      <<Msg/binary,(cert_loop(Handle))/binary>>;
    {Handle, eof} ->
      <<>>
  after 10000 ->
          throw("Cant get certificate from openssl")
  end.

selfsigned(CertFile, KeyFile, Subject) ->
  OpenSSL=os:find_executable("openssl"),
  erlang:open_port(
    {spawn_executable, OpenSSL},
    [{args, [
             "req", "-new", "-x509",
             "-key", KeyFile,
             "-days", "3650",
             "-nodes", "-subj", "/CN="++Subject,
             "-out", CertFile
            ]},
     eof,
     binary,
     stderr_to_stdout
    ]).


