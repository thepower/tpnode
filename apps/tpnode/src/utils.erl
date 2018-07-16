-module(utils).

-export([make_binary/1, make_list/1]).


%% -------------------------------------------------------------------------------------

make_binary(Arg) when is_binary(Arg) ->
  Arg;

make_binary(Arg) when is_list(Arg) ->
  list_to_binary(Arg);

make_binary(_Arg) ->
  throw(badarg).


%% -------------------------------------------------------------------------------------

make_list(Arg) when is_list(Arg) ->
  Arg;

make_list(Arg) when is_binary(Arg) ->
  binary_to_list(Arg);

make_list(_Arg) ->
  throw(badarg).


