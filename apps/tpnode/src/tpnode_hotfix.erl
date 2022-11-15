-module(tpnode_hotfix).
-export([install/1, autoload/0, unpack/1, load/1, load1/2, validkey/1]).

-define(STD_KEYS,[
                  "302A300506032B65700321002B3A6C9A401865F65004665336A9CA3E33D029D7AE2B5204EBFBC0A4910CFA1E",
                  "032FB1B9DF699380904A803E579AB7392B7DF26881DA07D1ABC9DB198919B03782"
                 ]).

validkey(PubKey) ->
  ValidKeys=lists:foldl(
              fun(HexKey,A) ->
                  maps:put(tpecdsa:cmp_pubkey(hex:decode(HexKey)),1,A)
              end, #{},
              application:get_env(tpnode, hotfix_keys, ?STD_KEYS)
             ),
  PK=tpecdsa:cmp_pubkey(PubKey),
  maps:is_key(PK,ValidKeys).


versig({true,#{extra := SigXD}}=Any) ->
  case proplists:get_value(pubkey,SigXD) of
    undefined ->
      logger:notice("Versig failed to find pubkey: ~p",[Any]),
      false;
    PubKey ->
      validkey(PubKey)
  end;

versig(Any) ->
  logger:notice("Versig failed: ~p",[Any]),
  false.

autoload() ->
  ok.

install(Fix) ->
  Host=application:get_env(tpnode,hotfix_host,"https://hotfix.thepower.io"),

  case get(Host, "/thepower/hotfix/tpnode/"++Fix) of
    {200, Bin} ->
      {ok, Files, Sig} = unpack(Bin),
      case versig(Sig) of
        true ->
          code:delete(hotfix_compatible),
          code:purge(hotfix_compatible),
          code:delete(hotfix_compatible),
          case proplists:get_value("hotfix_compatible.beam",Files) of
            undefined -> {error, that_is_not_hotfix};
            Beam ->
              load1("hotfix_compatible.beam",Beam),
              {file,_} = code:is_loaded(hotfix_compatible),
              ok = hotfix_compatible:check(Files),
              {ok,load(Files)}
          end;
        false ->
          {error,badsig}
      end;
    {Code,_} ->
      {error,{http,Code}}
  end.


load1(Filename, Bin) ->
  N=filename:basename(Filename),
  case string:split(N,".") of
    [Module,"beam"] ->
      ModName=list_to_atom(Module),
      {Filename,case code:load_binary(ModName,Filename,Bin) of
                  {error, R} ->
                    R;
                  {module, _} ->
                    ok
                end}; 
    _ ->
      false
  end.

load([]) -> [];

load([{"hotfix_compatible.beam",_}|Files]) ->
  load(Files);

load([{Filename,<<"FOR1",_/binary>> = Bin}|Files]) ->
  case load1(Filename,Bin) of
    false ->
      load(Files);
    {_,_} = E ->
      [E|load(Files)]
  end;

load([_|Files]) ->
  load(Files).

split_bin(<<HL:16/big,0,Signatures:(HL-1)/binary,ZIP/binary>>) ->
  {Signatures,ZIP}.

unpack(Bin) ->
  {Sig,Zip}=split_bin(Bin),
  {ok,Files}=zip:extract(Zip,[memory]),
  Hash=crypto:hash(sha256,Zip),
  CheckSig=bsig:checksig1(Hash,Sig),
  {ok, Files, CheckSig}.

get(Node, Path) ->
  application:ensure_all_started(gun),
  {ok, ConnPid} = connect(Node),
  StreamRef = gun:get(ConnPid, Path, []),
  {response, Fin, Code, _Headers} = gun:await(ConnPid, StreamRef),
  case Code of
    200 ->
      Body=case Fin of
             fin -> <<>>;
             nofin ->
               {ok, Body2} = gun:await_body(ConnPid, StreamRef),
               Body2
           end,
      gun:close(ConnPid),
      {Code,Body};
    Code ->
      gun:close(ConnPid),
      logger:error("Can't fetch ~s: code ~w",[Path,Code]),
      {Code,<<>>}
  end.

connect(Node) ->
  {Host, Port, Opts,_} = parse_url(Node),
  {ok, ConnPid} = gun:open(Host,Port,Opts),
  case gun:await_up(ConnPid) of
    {ok, _} ->
      {ok, ConnPid};
    {error,Other} ->
      throw(Other)
  end.

parse_url(Node) when is_binary(Node) ->
  parse_url(binary_to_list(Node));

parse_url(Node) when is_list(Node) ->
  CaCerts = certifi:cacerts(),
  CHC=[
       {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
      ],
  #{scheme:=Sch,
    path:=Path,
    host:=Host}=P = uri_string:parse(Node),
  {Opts,Port}=case Sch of
                "httpsi" ->
                  case get(warned) of
                    undefined ->
                      logger:notice("-=-=-= [ connection is insecure ] =-=-=-~n",[]),
                      put(warned, true);
                    _ ->
                      ok
                  end,
                  {
                   #{ transport=>tls,
                     transport_opts => [
                                        {versions,['tlsv1.2']},
                                        {verify,verify_none}
                                       ]
                   },
                  maps:get(port,P,443)
                 };
                "https" -> {
                  #{ transport=>tls,
                     transport_opts => [{verify, verify_peer},
                                        {customize_hostname_check, CHC},
                                        {depth, 5},
                                        {versions,['tlsv1.2']},
                                        %{versions,['tlsv1.3']},
                                        {cacerts, CaCerts}
                                       ]
                   },
                  maps:get(port,P,443)
                 };
                "http" ->
                  case get(warned) of
                    undefined ->
                      logger:notice("-=-=-= [ connection is not encrypted, so insecure ] =-=-=-~n",[]),
                      put(warned, true);
                    _ ->
                      ok
                  end,
                  {
                   #{ transport=>tcp },
                   maps:get(port,P,80)
                  }
              end,
  {Host,
   Port,
   Opts,
   #{path=>Path}
  }.


