%%%-------------------------------------------------------------------
-include("include/tplog.hrl").
%% @doc tpnode_repl gen_server
%% @end
%%%-------------------------------------------------------------------
-module(tpnode_netmgmt_repl).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2022-11-12").

-behaviour(gen_statem).

%% API
-export([start_link/2]).

%% gen_statem callbacks
-export([
         callback_mode/0,
         init/1,
         format_status/2,
         terminate/3,
         code_change/4
        ]).

-export([
         state_init/3
        ]).
%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Worker,Opts) ->
    gen_statem:start_link({global,{nm,Worker}}, ?MODULE, [Worker, Opts], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
callback_mode() -> state_functions.

init([Worker, Opts]) ->
  self() ! init,
  {ok, state_init, #{worker=>Worker, opts=>Opts, loaders=>[]}}.

format_status(_Opt, [_PDict, State, Data]) ->
    [{data, [{"State", {State, Data}}]}].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name.  If callback_mode is statefunctions, one of these
%% functions is called when gen_statem receives and event from
%% call/2, cast/2, or as a normal process message.
%%
%% @spec state_init(Event, OldState, Data) ->
%%                   {next_state, NextState, NewData} |
%%                   {next_state, NextState, NewData, Actions} |
%%                   {keep_state, NewData} |
%%                   {keep_state, NewData, Actions} |
%%                   keep_state_and_data |
%%                   {keep_state_and_data, Actions} |
%%                   {repeat_state, NewData} |
%%                   {repeat_state, NewData, Actions} |
%%                   repeat_state_and_data |
%%                   {repeat_state_and_data, Actions} |
%%                   stop |
%%                   {stop, Reason} |
%%                   {stop, Reason, NewData} |
%%                   {stop_and_reply, Reason, Replies} |
%%                   {stop_and_reply, Reason, Replies, NewData}
%% @end
%%--------------------------------------------------------------------
state_init({call, Caller}, _Msg, Data) ->
  ?LOG_INFO("Got unhandled call: ~p",[_Msg]),
  {keep_state, Data, [{reply, Caller, unhandled}]};

state_init(cast, {new_block_notify,{Height, Hash, _Parent}, Origin}, #{worker:=Wrk, loaders:=PIDs}=Data) ->
  Ptr=hex:encode(Hash),
  Query= <<"/api/binblock/",Ptr/binary>>,

  ?LOG_INFO("Got new block, should sync ~p: ~p",[Height,blockchain:blkid(Hash)]),
  R=httpget(Origin, Query, PIDs),
  ?LOG_DEBUG("httpget ~p",[R]),
  case R of
    {ok, {200, _Headers, Body}, PidList1} ->
      Block=block:unpack(Body),
      gen_server:call(Wrk, {new_block, Block}),
      {keep_state, Data#{loaders=>PidList1}};
    {error, PidList1} ->
      {keep_state, Data#{loaders=>PidList1}}
  end;

state_init(info, {gun_up,_Pid,_Http}, Data) ->
  {next_state, state_init, Data, []};

state_init(info, {gun_down,Pid,_,closed,_,_}, #{loaders:=PidList}=Data) ->
  case lists:keyfind(Pid,1,PidList) of
    false ->
      keep_state_and_data;
    {Pid, _} = E ->
      {keep_state, Data#{loaders=>PidList -- [E]}}
  end;

state_init(info, {wrk_up,_Pid,_}, _Data) ->
  keep_state_and_data;

state_init(Kind, Msg, _Data) ->
  ?LOG_INFO("Got unhandled ~p: ~p",[Kind,Msg]),
  keep_state_and_data.

terminate(_Reason, _State, _Data) ->
  ok.

code_change(_OldVsn, State, Data, _Extra) ->
  {ok, State, Data}.

%%
%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

do_connect(URL) ->
  #{host:=H,
    port:=P,
    scheme:=Sch} = uri_string:parse(URL),
  Opts=case Sch of
         "http" -> #{};
         "https" -> 
           %CaCerts = certifi:cacerts(),
           CHC=[
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
               ],
           #{ transport=>tls,
              protocols => [http],
              transport_opts => [{verify, verify_peer},
                                 %{cacerts, CaCerts},
                                 {customize_hostname_check, CHC}
                                ]}
       end,
  case gun:open(H,P,Opts) of
    {ok, ConnPid} ->
      case gun:await_up(ConnPid,5000) of
        {ok, _} ->
          {ok, ConnPid};
        Reason ->
          ?LOG_NOTICE("Can't connect to ~s: ~p",[URL,Reason]),
          gun:close(ConnPid),
          {error, Reason}
      end;
    {error, Err} ->
      ?LOG_ERROR("Error connecting to ~s: ~p",[URL,Err]),
      {error, Err}
  end.

ensure_connected(URL, PidList) ->
  case lists:keyfind(URL,2,PidList) of
    false ->
      case do_connect(URL) of
        {ok, Pid} ->
          [{Pid,URL}|PidList];
        {error, _Reason} ->
          PidList
      end;
    {ConnPid,URL} = Elm ->
      case is_process_alive(ConnPid) of
        true ->
          PidList;
        false ->
          case do_connect(URL) of
            {ok, Pid} ->
              [{Pid,URL}|PidList -- [Elm]];
            {error, _Reason} ->
              PidList -- [Elm]
          end
      end
  end.

do_httpget(Pid, URL) ->
  Ref=gun:get(Pid,URL),
  case gun:await(Pid, Ref, 20000) of
    {response, _, HttpCode, Headers} ->
      ?LOG_INFO("Getting ~s code ~p",[URL, HttpCode]),
      {ok, Body} = gun:await_body(Pid, Ref, 20000),
      {HttpCode, Headers, Body};
    {error, timeout} ->
      {error, timeout}
  end.

httpget(Server, Query, PidList) ->
  PidList1=ensure_connected(Server,PidList),
  case lists:keyfind(Server,2,PidList1) of
    false ->
      {error, PidList1};
    {Pid, Server} ->
      case do_httpget(Pid, Query) of
        {_C, _H, _B}=CHB  ->
          {ok, CHB, PidList1};
        {error, Any} ->
          ?LOG_NOTICE("httpget error ~p",[Any]),
          {error, PidList1}
      end
  end.


