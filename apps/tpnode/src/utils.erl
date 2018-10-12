-module(utils).

-export([alloc_tcp_port/0,make_binary/1, make_list/1, apply_macro/2, print_error/4]).

alloc_tcp_port() ->
  {ok,S}=gen_tcp:listen(0,[]),
  {ok,{_,CPort}}=inet:sockname(S),
  gen_tcp:close(S),
  CPort.

%% -------------------------------------------------------------------------------------

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

print_error(Message, Ec, Ee, StackTrace) ->
  lager:error(Message ++ " [~p:~p]", [Ec, Ee]),
  lists:foreach(
    fun(SE) -> lager:error("@ ~p", [SE]) end,
    StackTrace
  ).
