-module(tpnode_cert).

-behaviour(gen_server).
-define(SERVER, ?MODULE).
% TODO: change this interval to 3 hours

-define(EXPIRE_CHECK_INTERVAL, 10). % expire check interval in seconds

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

-export([check_cert_expire/1]).


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
  application:ensure_all_started(letsencrypt),
  {ok,
    Args#{
      cert_req_active => false,
      expiretimer => erlang:send_after(rand:uniform(15) * 1000, self(), check_cert_expire)
    }
  }.

handle_call(state, _From, State) ->
  {reply, State, State};

handle_call(_Request, _From, State) ->
  lager:notice("Unknown call ~p", [_Request]),
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  lager:notice("Unknown cast ~p", [_Msg]),
  {noreply, State}.

handle_info(ssl_on, State) ->
  lager:info("spawning ssl api listeners"),
  spawn_ssl(),
  {noreply, State};

handle_info(ssl_off, State) ->
  lager:info("shuting down ssl api"),
  shutdown_ssl(),
  {noreply, State};

handle_info(ssl_restart, State) ->
  lager:info("restarting ssl api"),
  shutdown_ssl(),
  spawn_ssl(),
  {noreply, State};


handle_info(certreq, #{cert_req_active := false} = State) ->
  NewSate =
    case check_or_request() of
      certreq ->
        certreq;
      _ ->
        false
    end,
  {noreply, State#{
    cert_req_active => NewSate
  }};

% certificate request is in the process, skip this certreq
handle_info(certreq, #{cert_req_active := CurrentCertReq} = State) ->
  lager:debug("skiping certreq because of current cert_req state: ~p", [CurrentCertReq]),
  {noreply, State};

handle_info(certreq_done, State) ->
  lager:debug("enable certificate requests"),
  self() ! ssl_restart,
  {noreply, State#{
    cert_req_active => false
  }};


handle_info(check_cert_expire, #{expiretimer := Timer, cert_req_active := false} = State) ->
  catch erlang:cancel_timer(Timer),
  NewReqState =
    case check_cert_expire() of
      ok ->
        false;
      certreq ->
        lager:notice("request new certificate"),
        self() ! certreq,
        certreq
    end,
  {noreply, State#{
    cert_req_active => NewReqState,
    expiretimer => erlang:send_after(?EXPIRE_CHECK_INTERVAL * 1000, self(), check_cert_expire)
  }};

% certificate request is in the process, just renew timer
handle_info(check_cert_expire, #{expiretimer := Timer} = State) ->
  catch erlang:cancel_timer(Timer),
  lager:debug("cert expire timer tick"),
  {noreply, State#{
    expiretimer => erlang:send_after(?EXPIRE_CHECK_INTERVAL * 1000, self(), check_cert_expire)
  }};



handle_info(_Info, State) ->
  lager:notice("Unhandled info ~p", [_Info]),
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

get_cert_file(Hostname) ->
  utils:make_list(
      get_cert_path() ++
      "/" ++
      utils:make_list(Hostname) ++
      ".crt"
  ).

get_cert_key_file(Hostname) ->
  utils:make_list(
      get_cert_path() ++
      "/" ++
      utils:make_list(Hostname) ++
      ".key"
  ).

%% -------------------------------------------------------------------------------------

get_hostname() ->
  application:get_env(tpnode, hostname, unknown).
  

%% -------------------------------------------------------------------------------------

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

check_cert_expire() ->
  Hostname = get_hostname(),
  case Hostname of
    unknown ->
      ok;
    _ ->
      case check_cert_expire(get_cert_file(Hostname)) of
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
    lager:debug("node cert expire date: ~p", [Expire]),
    Now = os:system_time(second),
    ExpireTimestamp = parse_cert_date(Expire),
    Diff = ExpireTimestamp - Now - 30 * 24 * 60 * 60, % 30 days before real expiration date
    case Diff of
      Diff1 when Diff1 < 1 ->
        lager:error("Certificate is close to it's expiration date: ~p ~p", [Expire, Diff]),
        expired;
      _ ->
        lager:debug("Certificate expire date '~p' is OK", [Expire]),
        ok
    end
  catch
    {not_found, Reason} ->
      lager:error("can't read certificate: ~p ~p", [CertFile, Reason]),
      not_found;
    Ee:Ec ->
      lager:error(
        "can't check certificate expire date: ~p ~p ~p",
        [Ee, Ec, erlang:get_stacktrace()]
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
  Hostname = get_hostname(),
  case Hostname of
    unknown ->
      ok;
    _ ->
      check_or_request(utils:make_list(Hostname))
  end.

check_or_request(Hostname) ->
  KeyExists = filelib:is_regular(get_cert_key_file(Hostname)),
  CertFile = get_cert_file(Hostname),
  CertExists = filelib:is_regular(CertFile),
  Action = case KeyExists andalso CertExists of
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
      do_cert_request(Hostname);
    _ ->
      pass
  end,
  Action.

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
  self() ! certreq_done,
  ok.

%% -------------------------------------------------------------------------------------

do_cert_request(Hostname) ->
  lager:debug("request letsencrypt cert for host ~p", [Hostname]),
  CertPath = get_cert_path(),
  filelib:ensure_dir(CertPath ++ "/"),
  % TODO: remove staging flag here
  letsencrypt:start([{mode, standalone}, staging, {cert_path, CertPath}, {port, 80}]),
%%  letsencrypt:start([{mode,standalone}, {cert_path, CertPath}, {port, 80}]),
  letsencrypt:make_cert(utils:make_binary(Hostname), #{callback => fun on_complete/1}).

%% -------------------------------------------------------------------------------------

spawn_ssl() ->
  Hostname = get_hostname(),
  Pids = case Hostname of
    unknown ->
      [];
    _ ->
      Specs =
        tpnode_http:childspec_ssl(get_cert_file(Hostname), get_cert_key_file(Hostname)),
      [supervisor:start_child(tpnode_sup, Spec) || Spec <- Specs]
  end,
  lager:debug("ssl spawn result: ~p", [Pids]),
  ListenerFilter =
    fun({ok, Pid}, Acc) ->
      Acc ++ [Pid];
      (_, Acc) ->
        Acc
    end,
  lists:foldl(ListenerFilter, [], Pids).


shutdown_ssl() ->
  Names = tpnode_http:child_names_ssl(),
  Killer =
    fun(Name) ->
      supervisor:terminate_child(tpnode_sup, {ranch_listener_sup, Name}),
      supervisor:delete_child(tpnode_sup, {ranch_listener_sup, Name})
    end,
  lists:foreach(Killer, Names),
  ok.
  
