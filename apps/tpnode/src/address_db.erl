-module(address_db).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([lookup/1]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

lookup(Address) ->
    case naddress:check(Address) of
        {true, #{address:=_,
                 block:=Block,
                 group:=_,
                 type:=public
                }} ->
            {ok, Block};
        _ ->
            error
    end.

