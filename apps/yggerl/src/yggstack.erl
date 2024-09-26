-module(yggstack).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Config], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Config]) ->
    logger:set_process_metadata(#{domain=>[yggstack]}),
    Executable=case ygg:executable() of
                 false -> throw(no_yggstack_found);
                 L -> L
               end,
    io:format("Config ~p~n",[Config]),
    ok=file:write_file("_tmp_cfg",ygg:config_file(Config)),
    H=erlang:open_port(
        {spawn_executable, Executable},
        [{args, ["-useconffile", "_tmp_cfg" ]},
         %eof,
         binary,
         stderr_to_stdout
        ]),
    erlang:link(H),
    timer:sleep(200),
    %ok=file:delete("_tmp_cfg"),
    {ok, #{handler=>H}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    logger:info("BV Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
  io:format("Got info ~p~n",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    logger:info("Terminate blockvote ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


