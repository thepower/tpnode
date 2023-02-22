-module(utils).
-include("include/tplog.hrl").

-export([alloc_tcp_port/0,make_binary/1, make_list/1, apply_macro/2,
  print_error/4, log_stacktrace/1, check_tcp_port/1]).

-export([logger/1, logger/2]).

-export([dbpath/1]).
-export([update_cfg/2]).
-export([read_cfg/2,read_cfg/1]).
-export([is_printable/1,textize_binary/1]).

read_cfg(DbName) ->
  read_cfg(DbName,[]).

read_cfg(DbName, Default) ->
  Filename=dbpath(DbName),
  case file:consult(Filename) of
    {ok,[L]} when is_list(L) ->
      L;
    {ok,_} ->
      {error, badfile};
    {error,enoent} ->
      Default;
    {error,Any} ->
      {error, Any}
  end.

update_cfg(DbName,Replacements) ->
  Filename=dbpath(DbName),
  New=case file:consult(Filename) of
        {ok,[L]} when is_list(L) ->
          lists:foldr(
            fun({K,V},Acc) ->
                [{K,V}|proplists:delete(K,Acc)]
            end,
            L,
            Replacements);
        {ok,_} ->
          throw({error, badfile});
        {error,enoent} ->
          Replacements;
        {error,Any} ->
          throw({error, Any})
      end,
  file:write_file(Filename,io_lib:format("~p.~n",[New])).


dbpath(cert) ->
  DBPath=application:get_env(tpnode,dbpath,"db"),
  case application:get_env(tpnode,dbsuffix, undefined) of
    undefined ->
      filename:join([DBPath,erlang:node(),"cert"]);
    Other ->
      filename:join(DBPath,[cert,Other])
  end;

dbpath(mledger) ->
  DBPath=application:get_env(tpnode,dbpath,"db"),
  Suffix=application:get_env(tpnode,dbsuffix,"_" ++ atom_to_list(node()) ++ ".db"),
  filename:join(DBPath,[mledger,Suffix]);

dbpath(DB) ->
  DBPath=application:get_env(tpnode,dbpath,"db"),
  Suffix=application:get_env(tpnode,dbsuffix,"_" ++ atom_to_list(node())),
  filename:join(DBPath,[DB,Suffix]).

alloc_tcp_port() ->
  {ok,S}=gen_tcp:listen(0,[]),
  {ok,{_,CPort}}=inet:sockname(S),
  gen_tcp:close(S),
  CPort.

check_tcp_port(Port) ->
  case gen_tcp:listen(Port,[]) of
    {error, _} -> false;
    {ok,S} ->
      gen_tcp:close(S),
      true
  end.


%% -------------------------------------------------------------------------------------
textize_binary(Bin) ->
  case is_printable(Bin) of
    true ->
      Bin;
    false ->
      list_to_binary(["0x",hex:encode(Bin)])
  end.

is_printable(<<>>) ->
  true;
is_printable(<<B0,Bin/binary>>) when B0>=32 andalso B0<127 ->
  is_printable(Bin);
is_printable(_) ->
  false.

make_binary(Arg) when is_integer(Arg) ->
  integer_to_binary(Arg, 10);

make_binary(Arg) when is_binary(Arg) ->
  Arg;

make_binary(Arg) when is_list(Arg) ->
  list_to_binary(Arg);

make_binary(Arg) when is_atom(Arg) ->
  atom_to_binary(Arg, utf8);

make_binary(_Arg) ->
  throw(badarg).


%% -------------------------------------------------------------------------------------

make_list(Arg) when is_list(Arg) ->
  Arg;

make_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg);

make_list(Arg) when is_atom(Arg) ->
  atom_to_list(Arg);

make_list(_Arg) ->
  throw(badarg).


%% -------------------------------------------------------------------------------------

apply_macro(MapWithMacro, Dict) when is_map(MapWithMacro) andalso is_map(Dict) ->
  Worker =
    fun(DictKey, DictValue, SrcMap) ->
      maps:map(
        fun(_K, V) ->
          case V of
            DictKey -> DictValue;
            _ -> V
          end
        end, SrcMap)
    end,
  maps:fold(Worker, MapWithMacro, Dict).

%% -------------------------------------------------------------------------------------

log_stacktrace(StackTrace) ->
  lists:foreach(
    fun(Where) -> ?LOG_ERROR("@ ~p", [Where]) end,
    StackTrace
  ).

%% -------------------------------------------------------------------------------------

print_error(Message, Ec, Ee, StackTrace) ->
  ?LOG_ERROR(make_list(Message) ++ " [~p:~p]", [Ec, Ee]),
  log_stacktrace(StackTrace).

%% -------------------------------------------------------------------------------------

logger(Format) when is_list(Format) ->
  logger(Format, []).

logger(Format, Args) when is_list(Format), is_list(Args) ->
  StrTime = now_str(),
  io:format(
    StrTime ++ " " ++ Format ++ "~n",
    Args).


% -----------------------------------------------------------------------------
%% pretty print timestamp from logger/src/logger_utils.erl
now_str() ->
  {_, _, Micro} = Now = os:timestamp(),
  {Date, {Hours, Minutes, Seconds}} = calendar:now_to_local_time(Now),
  now_str({Date, {Hours, Minutes, Seconds, Micro div 1000 rem 1000}}).

now_str({{Y, M, D}, {H, Mi, S, Ms}}) ->
  lists:flatten(io_lib:format(
    "~p-~2..0p-~2..0p ~2..0p:~2..0p:~2..0p.~3..0p",
    [Y, M, D, H, Mi, S, Ms]
  )).
