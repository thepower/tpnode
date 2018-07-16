-module(tpnode_certreq).

-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    application:ensure_all_started(letsencrypt),
    {ok, Args}.

handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p",[_Request]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:notice("Unknown cast ~p",[_Msg]),
    {noreply, State}.

handle_info(certreq, State) ->
  check_or_request(),
  {noreply, State};

handle_info(_Info, State) ->
    lager:notice("Unknown info  ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% -------------------------------------------------------------------------------------
get_cert_path() ->
%%  "/tmp/4/cert".
 "db/" ++ atom_to_list(erlang:node()) ++ "/cert".

%% -------------------------------------------------------------------------------------

check_or_request() ->
  Hostname = application:get_env(tpnode, hostname, unknown),
  case Hostname of
    unknown ->
      ok;
    _ ->
      check_or_request(utils:make_list(Hostname))
  end.

check_or_request(Hostname) when is_list(Hostname)->
  CertPath = get_cert_path(),
  KeyExists = filelib:is_regular(CertPath ++ Hostname ++ ".key"),
  CertExists = filelib:is_regular(CertPath ++ Hostname ++ ".crt"),
  case KeyExists andalso CertExists of
    true ->
      % key and cert already exists for this hostname
      % TODO check if cert expired
      ok;
    _ ->
      do_cert_request(Hostname)
  end.

%% -------------------------------------------------------------------------------------

on_complete({State, Data}) ->
  case State of
    error ->
      lager:error("letsencrypt error: ~p", [Data]);
    _ ->
      lager:error("letsencrypt certificate issued: ~p (~p)", [State, Data]),
      lager:debug("letsencrypt certificate issued: ~p (~p)", [State, Data])
  end,
  letsencrypt:stop(),
  ok.

%% -------------------------------------------------------------------------------------

do_cert_request(Hostname) ->
  lager:debug("request letsencrypt cert for host ~p", [Hostname]),
  CertPath = get_cert_path(),
  filelib:ensure_dir(CertPath ++ "/"),
  letsencrypt:start([{mode,standalone}, staging, {cert_path, CertPath}, {port, 80}]),
%%  letsencrypt:start([{mode,standalone}, {cert_path, CertPath}, {port, 80}]),
  letsencrypt:make_cert(utils:make_binary(Hostname), #{callback => fun on_complete/1}).
