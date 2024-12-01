-module(yggstack_wdt).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(ParentPid, OsPid) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [ParentPid, OsPid], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([EPid,OsPid]) ->
    logger:set_process_metadata(#{domain=>[yggstack]}),
    process_flag(trap_exit, true),
    {ok, #{epid => EPid, ospid => OsPid}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    logger:info("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info({'EXIT',EPid,_}, State=#{epid:=EPid, ospid:=OsPid}) ->
  logger:info("termnate yggstack pid ~w",[OsPid]),
  send_signal(OsPid,15),
  {terminate, normal, State};

handle_info(_Info, State) ->
  logger:info("Got info ~w ~w~n",[_Info, maps:keys(State)]),
  {noreply, State}.

terminate(_Reason, _State) ->
    logger:info("Terminate yggstack ~p", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

send_signal(Pid, Signal) ->
    % Construct the shell command for sending the signal.
    Command = "kill -" ++ integer_to_list(Signal) ++ " " ++ integer_to_list(Pid),
    % Execute the command using os:cmd/1.
    os:cmd(Command).

