-module(proxy_connect).
-export([proxy_connect/3]).

proxy_connect(P, ToHostStr, ToPort) ->
  Bin = << 5, 1, 0 >>,
  gen_tcp:send(P, Bin),
  case gen_tcp:recv(P,2,5000) of
    {ok, <<5, 255>>} ->
      logger:notice("Proxy rejected auth"),
      {error, auth_reject};
    {ok, <<5, 0>>} ->
      ToHost=list_to_binary(ToHostStr),
      logger:info("Connect to ~s:~p via proxy",[ToHost, ToPort]),
      Bin1= <<5, 1, 0, 3, (size(ToHost)):8/integer, ToHost/binary, ToPort:16/big>>,
      gen_tcp:send(P, Bin1),
      case gen_tcp:recv(P,5,5000) of
        {ok, <<5, 0, _:8/integer, 1, _IP1>>} ->
          case gen_tcp:recv(P,5,5000) of
            {ok, <<_IP2, _IP3, _IP4, _Port:16/big>>} ->
              ok;
            Other ->
              logger:info("other error ~p",[Other]),
              {error, connect_sync}
          end;
        {ok, <<5, 0, _:8/integer, 4, _IP1>>} ->
          case gen_tcp:recv(P,17,5000) of
            {ok, <<_IP2, _IP3, _IP4, _Port:16/big>>} ->
              ok;
            Other ->
              logger:info("other error ~p",[Other]),
              {error, connect_sync}
          end;
        {ok, <<5, 0, _:8/integer, 3, ALen:8/integer>>} ->
          case gen_tcp:recv(P,ALen+2,5000) of
            {ok, <<_Addr:ALen/binary, _Port:16/big>>} ->
              ok;
            Other ->
              logger:info("other error ~p",[Other]),
              {error, connect_sync}
          end;
        {ok, <<5, ErrT, _:3/binary>>} ->
              {error, ErrT}
      end
  end.
