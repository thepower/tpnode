-module(tpnode_cert).
-include("include/tplog.hrl").

-behaviour(gen_server).
-define(SERVER, ?MODULE).


-define(EXPIRE_CHECK_INTERVAL, 3*60*60). % expire check interval in seconds

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([check_cert_expire/1, is_ssl_started/0]).
-export([get_cert_file/0, get_cert_key_file/0]).


%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, #{}, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
%  application:ensure_all_started(letsencrypt),
  {ok,
    Args#{
      cert_req_active => false,
      expiretimer => erlang:send_after(rand:uniform(15) * 1000, self(), check_cert_expire)
    }
  }.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  ?LOG_NOTICE("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast(certreq_done, State) ->
  ?LOG_DEBUG("enable certificate requests"),
  self() ! ssl_restart,
  {noreply, State#{
    cert_req_active => false
  }};

handle_cast(_Msg, State) ->
  ?LOG_NOTICE("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(ssl_on, State) ->
  ?LOG_INFO("spawning ssl api listeners"),
  spawn_ssl(),
  {noreply, State};

handle_info(ssl_off, State) ->
  ?LOG_INFO("shuting down ssl api"),
  shutdown_ssl(),
  {noreply, State};

handle_info(ssl_restart, State) ->
  ?LOG_INFO("restarting ssl api"),
  shutdown_ssl(),
  spawn_ssl(),
  {noreply, State};


handle_info(certreq, #{cert_req_active := false} = State) ->
  NewSate =
    case check_or_request() of
      Ref when is_reference(Ref) ->
        Ref;
      _ ->
        false
    end,
  {noreply, State#{
    cert_req_active => NewSate
  }};

% certificate request is in the process, skip this certreq
handle_info(certreq, #{cert_req_active := CurrentCertReq} = State) ->
  ?LOG_DEBUG("skiping certreq because of current cert_req state: ~p", [CurrentCertReq]),
  {noreply, State};


handle_info(check_cert_expire, #{expiretimer := Timer, cert_req_active := false} = State) ->
  catch erlang:cancel_timer(Timer),
  case check_cert_expire() of
    ok ->
      case is_ssl_configured() of
        true ->
          ensure_ssl_started(),
          pass;
        _ ->
          pass
      end;
    certreq ->
      ?LOG_NOTICE("going to request a new certificate"),
      self() ! certreq,
      certreq
  end,
  {noreply, State#{
    expiretimer => erlang:send_after(?EXPIRE_CHECK_INTERVAL * 1000, self(), check_cert_expire)
  }};

% certificate request is in progress, just renew timer
handle_info(check_cert_expire, #{expiretimer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
  ?LOG_DEBUG("cert expire timer tick (certificate request is in progress)"),
  {noreply, State#{
    expiretimer => erlang:send_after(?EXPIRE_CHECK_INTERVAL * 1000, self(), check_cert_expire)
  }};


handle_info({'DOWN', Ref, process, _Pid, normal}, #{cert_req_active := Ref} = State) ->
  ?LOG_DEBUG("cert request process ~p finished successfuly", [_Pid]),
  {noreply, State#{
    cert_req_active => false
  }};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #{cert_req_active := Ref} = State) ->
  ?LOG_DEBUG("cert request process ~p finished with reason: ~p", [_Pid, Reason]),
  {noreply, State#{
    cert_req_active => false
  }};


handle_info(_Info, State) when is_tuple(_Info)->
  ?LOG_NOTICE("Unhandled info tuple [~b]: ~p", [size(_Info), _Info]),
  {noreply, State};

handle_info(_Info, State) ->
  ?LOG_NOTICE("Unhandled info ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% -------------------------------------------------------------------------------------
get_cert_file() ->
  get_cert_file(get_hostname()).

get_cert_key_file() ->
  get_cert_key_file(get_hostname()).

get_cert_file(Hostname) ->
  utils:make_list(
    utils:dbpath(cert) ++
    "/" ++
    utils:make_list(Hostname) ++
    ".crt"
   ).

get_cert_key_file(Hostname) ->
  utils:make_list(
    utils:dbpath(cert) ++
    "/" ++
    utils:make_list(Hostname) ++
    ".key"
   ).

%% -------------------------------------------------------------------------------------

get_hostname() ->
  application:get_env(tpnode, hostname, unknown).


get_port() ->
  tpnode_http:get_ssl_port(unknown).


is_ssl_configured() ->
  Hostname = get_hostname(),
  Port = get_port(),
  if
    Port =:= unknown ->
      false;
    Hostname =:= unknown ->
      false;
    true ->
      true
  end.


%% -------------------------------------------------------------------------------------

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

check_cert_expire() ->
  case is_ssl_configured() of
    false ->
      ok;
    _ ->
      case check_cert_expire(get_cert_file(get_hostname())) of
        expired ->
          certreq;
        not_found ->
          certreq;
        _ ->
          ok
      end
  end.


check_cert_expire(CertFile) ->
  try
    PEM =
      case file:read_file(CertFile) of
        {ok, Data} ->
          Data;
        {error, Descr} ->
          throw({not_found, Descr})
      end,
    [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(PEM),
    OTPCert = public_key:pkix_decode_cert(Der, otp),
    {'Validity', _, Expire} = OTPCert#'OTPCertificate'.tbsCertificate#'OTPTBSCertificate'.validity,
    ?LOG_DEBUG("node cert expire date: ~p", [Expire]),
    Now = os:system_time(second),
    ExpireTimestamp = parse_cert_date(Expire),
    Diff = ExpireTimestamp - Now - 30 * 24 * 60 * 60, % 30 days before real expiration date
    case Diff of
      Diff1 when Diff1 < 1 ->
        ?LOG_ERROR("Certificate is close to it's expiration date: ~p ~p", [Expire, Diff]),
        expired;
      _ ->
        ?LOG_DEBUG("Certificate expire date '~p' is OK", [Expire]),
        ok
    end
  catch
    {not_found, Reason} ->
      ?LOG_ERROR("can't read certificate: ~p ~p", [CertFile, Reason]),
      not_found;
    Ee:Ec:S ->
      %S=erlang:get_stacktrace(),
      ?LOG_ERROR(
        "can't check certificate expire date: ~p ~p ~p",
        [Ee, Ec, S]
      ),
      error
  end.

parse_cert_date({utcTime, Date}) when is_list(Date) ->
  <<
    Year:2/binary,
    Month:2/binary,
    Day:2/binary,
    Hours:2/binary,
    Minutes:2/binary,
    Seconds:2/binary,
    "Z"/utf8
  >> = list_to_binary(Date),
  ParsedDate = {
    {binary_to_integer(Year) + 2000, binary_to_integer(Month), binary_to_integer(Day)},
    {binary_to_integer(Hours), binary_to_integer(Minutes), binary_to_integer(Seconds)}},
  (calendar:datetime_to_gregorian_seconds(ParsedDate) - 62167219200).


%% -------------------------------------------------------------------------------------

check_or_request() ->
  case is_ssl_configured() of
    false ->
      pass;
    _ ->
      check_or_request(utils:make_list(get_hostname()))
  end.

check_or_request(Hostname) ->
  Configured = is_ssl_configured(),
  KeyExists = filelib:is_regular(get_cert_key_file(Hostname)),
  CertFile = get_cert_file(Hostname),
  CertExists = filelib:is_regular(CertFile),
  ?LOG_INFO("Certfile ~s ~s",[CertFile,if CertExists ->
                                             "found";
                                           true ->
                                             "not found"
                                        end]),
  Action = case Configured andalso KeyExists andalso CertExists of
    true ->
      % key and cert already exists for this hostname, check if it expired
      case check_cert_expire(CertFile) of
        expired ->
          certreq;
        not_found ->
          certreq;
        _ ->
          pass
      end;
    _ ->
      certreq
  end,
  case Action of
    certreq ->
      %do_cert_request(Hostname);
      timer:sleep(10000),
      error;
    _ ->
      pass
  end.

%% -------------------------------------------------------------------------------------

%get_letsencrypt_startspec(CertPath) ->
%  GetStaging = fun() ->
%    case application:get_env(tpnode, staging, unknown) of
%      true ->
%        [staging];
%      _ ->
%        []
%    end
%  end,
%  GetMode = fun() ->
%    case application:get_env(tpnode, webroot, unknown) of
%      unknown ->
%        [{mode, standalone}, {port, 80}]; % standalone mode
%      Path ->
%        [{mode,webroot},{webroot_path, utils:make_list(Path)}] % webroot mode
%    end
%  end,
%  GetMode() ++ GetStaging() ++ [{cert_path, utils:make_list(CertPath)}].
%
%
%%% -------------------------------------------------------------------------------------
%
%letsencrypt_runner(CertPath, Hostname) ->
%  letsencrypt:start(get_letsencrypt_startspec(CertPath)),
%  try
%    case letsencrypt:make_cert(utils:make_binary(Hostname), #{async => false}) of
%      {error, Data} ->
%        ?LOG_ERROR("letsencrypt error: ~p", [Data]);
%      {State, Data} ->
%        ?LOG_ERROR("letsencrypt certificate issued: ~p (~p)", [State, Data]);
%      Error ->
%        ?LOG_ERROR("letsencrypt generic error: ~p", [Error])
%    end
%  catch
%    exit:{{{badmatch,{error,eacces}}, _ }, _} ->
%      ?LOG_ERROR(
%        "Got eacces error. Do you have permition to run the http server on port 80 " ++
%        "or webroot access for letsencrypt hostname verification?");
%    
%    Ee:Ec ->
%      ?LOG_ERROR(
%        "letsencrypt runtime error: ~p ~p ~p",
%        [Ee, Ec, erlang:get_stacktrace()]
%      )
%  end,
%  letsencrypt:stop(),
%  gen_server:cast(?MODULE, certreq_done),
%  ok.
%  
%
%%% -------------------------------------------------------------------------------------
%
%do_cert_request(Hostname) ->
%  ?LOG_DEBUG("request letsencrypt cert for host ~p", [Hostname]),
%  CertPath = get_cert_path(),
%  filelib:ensure_dir(CertPath ++ "/"),
%  RunnerFun =
%    fun() ->
%      process_flag(trap_exit, true),
%      letsencrypt_runner(CertPath, Hostname)
%    end,
%    
%  Pid = erlang:spawn(RunnerFun),
%  erlang:monitor(process, Pid).

%% -------------------------------------------------------------------------------------

% a check is all ssl listeners were started or not
-spec is_ssl_started() -> true|false|unknown.

is_ssl_started() ->
  
  Children = supervisor:which_children(tpnode_sup),
  Names = tpnode_http:child_names_ssl(),
  Checker =
    fun(Name, State) when State =:= unknown orelse State =:= true ->
      case lists:keyfind({ranch_listener_sup, Name}, 1, Children) of
        false -> false;
        _ -> true
      end;
      (_, _) ->
        false
    end,
  lists:foldl(Checker, unknown, Names).

%% -------------------------------------------------------------------------------------

% ensure all ssl listeners are active. we don't validate certificate here
ensure_ssl_started() ->
  case is_ssl_started() of
    false ->
      self() ! ssl_on;
    _ ->
      pass
  end.


%% -------------------------------------------------------------------------------------

spawn_ssl() ->
  Hostname = get_hostname(),
  Pids = case is_ssl_configured() of
    false ->
      ?LOG_DEBUG("ssl api unconfigured"),
      [];
    _ ->
      ?LOG_INFO("enable ssl api"),
      Specs =
        tpnode_http:childspec_ssl(get_cert_file(Hostname), get_cert_key_file(Hostname)),
      [supervisor:start_child(tpnode_sup, Spec) || Spec <- Specs]
  end,
  ?LOG_DEBUG("ssl spawn result: ~p", [Pids]),
  ListenerFilter =
    fun({ok, Pid}, Acc) ->
      Acc ++ [Pid];
      (_, Acc) ->
        Acc
    end,
  lists:foldl(ListenerFilter, [], Pids).


shutdown_ssl() ->
  ?LOG_INFO("disable ssl api"),
  Names = tpnode_http:child_names_ssl(),
  Killer =
    fun(Name) ->
      supervisor:terminate_child(tpnode_sup, {ranch_listener_sup, Name}),
      supervisor:delete_child(tpnode_sup, {ranch_listener_sup, Name})
    end,
  lists:foreach(Killer, Names),
  ok.
  
