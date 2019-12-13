-module(tpic_handler).

%-callback init(Params :: map()) -> {'ok', State :: term()}.
%-callback routing(State :: term()) -> map().
-callback handle_tpic(
            From :: term(),
            To :: binary() | atom(),
            Header :: binary(),
            Payload :: binary(),
            State :: term()|'close'
           ) -> {'ok', State :: term()}|'ok'|'close'.

-callback handle_response(
            From :: term(),
            To :: pid(),
            Header :: binary(),
            Payload :: binary(),
            State :: term()|'close'
           ) -> {'ok', State :: term()}|'ok'|'close'.
%% Alternatively you may define:
%%
%% -export([behaviour_info/1]).
%% behaviour_info(callbacks) ->
%%     [{init,1},
%%      {handle_req,2},
%%      {terminate,0}].

