-module(teaclient).

-export([start/1, main/1]).

main([]) ->
    getopt:usage(option_spec_list(), escript:script_name());
main(Args) ->
  logger:remove_handler(default),
  OptSpecList = option_spec_list(),
  case getopt:parse(OptSpecList, Args) of
    {ok, {Options, []}} ->
      case proplists:get_value(token,Options) of
        undefined ->
          getopt:usage(OptSpecList, "teaclient");
        _ ->
          application:ensure_all_started(teaclient),
          case lists:member(v,Options) of
            true ->
              Config=#{
                       config => #{ type=>standard_error },
                       level => info,
                       filters => [{nosasl, {fun logger_filters:progress/2, stop}}]
                      },
              logger:add_handler(default, logger_std_h, Config);
            false ->
              ok
          end,

          PArgs=lists:foldl(
                  fun({nodename,NN}, Acc) ->
                      Acc#{nodename=>list_to_binary(NN)};
                     ({token,NN}, Acc) ->
                      Acc#{token=>list_to_binary(NN)};
                     ({K,V},Acc) ->
                      Acc#{K=>V};
                     (K,Acc) ->
                      Acc#{K=>true}
                  end, #{}, Options),
          teaclient_worker:run(PArgs)
      end;
    {ok, {Options, NonOptArgs}} ->
      io:format("error: Unexpected arguments~n Options:~n  ~p~n~nNon-option arguments:~n  ~p~n", [Options, NonOptArgs]);
    {error, {Reason, Data}} ->
      io:format("Error: ~s ~p~n~n", [Reason, Data]),
      getopt:usage(OptSpecList, "teaclient")
  end.

option_spec_list() ->
  [
   %% {Name,     ShortOpt,  LongOpt,       ArgSpec,               HelpMsg}
   {host,        $h,        "host",        {string, "tea.thepower.io"}, "Seremony server"},
   {port,        $p,        "port",        {integer, 443},              "Ceremony server's TLS port"},
   {nodename,    $n,        "nodename",    string,                      "node name (max 10 symbols)"},
   {v,           $v,        undefined,     undefined, "log errors"},
   {ncp,         undefined, "npc",     undefined, "Do not check ports"},
   {legacy,      $l,        "legacy",      undefined,                   "Use legacy secp256k1 keys \n"
    "(default - ed25519)"},
   {token,       undefined, undefined,     string,                      "ceremony token"}
  ].
%main([CeremonyID,NodeName]) when is_list(CeremonyID),
%                                  is_list(NodeName) ->
%  start([list_to_binary(CeremonyID),list_to_binary(NodeName)]).

start([CeremonyID,NodeName]) when is_atom(CeremonyID),
                                  is_atom(NodeName) ->
  start([atom_to_binary(CeremonyID,utf8),atom_to_binary(NodeName,utf8)]);

start([CeremonyID,NodeName]) when is_binary(CeremonyID),
                                  is_binary(NodeName) ->
  application:ensure_all_started(teaclient),
  teaclient_worker:run(CeremonyID,NodeName).
