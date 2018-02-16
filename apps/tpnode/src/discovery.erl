% -*- mode: erlang -*-
% vi: set ft=erlang :
-module(discovery).

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

-export([test/0, test1/0, test2/0, test3/0]).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    #{name := Name} = Options,
    lager:notice("start ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    lager:debug("start discovery"),
    #{pid:=ParentPid} = Args,
    CheckExpireInterval = maps:get(check_expire_interval, Args, 60), % in seconds
    {ok, #{
        pid => ParentPid,
        settings => read_config(),
        local_services => #{
            names => #{},
            pids => #{}
        },
        remote_services => #{},
        check_expire_interval => CheckExpireInterval,
        cleantimer => erlang:send_after(CheckExpireInterval * 1000, self(), cleanup)
    }}.


handle_call({state}, _From, State) ->
    lager:notice("state request", []),
    {reply, State, State};

%%% TODO: продублировать с cast'ом
%%handle_call({register, Service, Description}, _From, State) ->
%%    #{dict:=Dict} = State,
%%    {reply, ok, State#{
%%        dict=>add(Service, Description, _From, Dict)
%%    }};

handle_call({config, Key}, _From, State) ->
    {reply, ok, get_config(Key, undefined, State), State};

handle_call({register, ServiceName, Pid}, _From, #{local_services:=Dict} = State) ->
    lager:debug("Register local service ~p with pid ~p", [ServiceName, Pid]),
    {reply, ok, State#{
        local_services => register_service(ServiceName, Pid, Dict)
    }};

handle_call({unregister, Pid}, _From, #{local_services:=Dict} = State) when is_pid(Pid) ->
    lager:debug("Unregister local service with pid ~p", [Pid]),
    {reply, ok, State#{
        local_services => delete_service(Pid, Dict)
    }};

handle_call({unregister, Name}, _From, #{local_services:=Dict} = State) when is_binary(Name) ->
    lager:debug("Unregister local service with name ~p", [Name]),
    {reply, ok, State#{
        local_services => delete_service(Name, Dict)
    }};

handle_call({get_pid, Name}, _From, #{local_services:=Dict} = State) when is_binary(Name) ->
    lager:debug("Get pid for local service with name ~p", [Name]),
    Reply = case find_service(Name, Dict) of
                {ok, #{pid:=Pid}} -> {ok, Pid, Name};
                error -> {error, not_found, Name}
            end,
    {reply, Reply, State};


% todo: написать с предикатом
% handle_call({lookup, Pred}, _From, State) when is_fun(Pred) ->
%     #{dict:=Dict} = State,
%     {reply, query(Query, Dict), State};

handle_call({lookup, Name}, _From, State) ->
    {reply, query(Name, State), State};

handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p", [_Request]),
    {reply, ok, State}.


handle_cast({make_announce}, #{local_services:=Dict} = State) ->
    lager:debug("Make local services announce"),
    make_announce(Dict, State),
    {noreply, State};

handle_cast({got_announce, Announce}, #{remote_services:=Dict} = State) ->
    lager:debug("Got service announce ~p", [Announce]),
    case validate_announce(Announce, State) of
        error ->
            {noreply, State};
        ok ->
            {noreply, State#{
                remote_services => process_announce(Announce, Dict)
            }}
    end;

handle_cast(_Msg, State) ->
    lager:notice("Unknown cast ~p", [_Msg]),
    {noreply, State}.


handle_info({'DOWN', _Ref, process, Pid, _Reason}, #{local_services:=Dict} = State) ->
    {noreply, State#{
        local_services => delete_service(Pid, Dict)
    }};


handle_info(cleanup, #{cleantimer:=CT} = State) ->
    catch erlang:cancel_timer(CT),
    #{
        remote_services:=RemoteDict,
        check_expire_interval:=CheckExpireInterval} = State,
    {noreply, State#{
        cleantimer => erlang:send_after(CheckExpireInterval * 1000, self(), cleanup),
        remote_services => filter_expired(RemoteDict, get_unixtime())
    }};

handle_info(_Info, State) ->
    lager:notice("Unknown info  ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

read_config() ->
    application:get_env(discovery, discovery, #{}).

get_config(Key, Default, State) ->
    #{settings:=Config} = State,
    maps:get(Key, Config, Default).


get_unixtime() ->
    {Mega, Sec, _Micro} = os:timestamp(),
    (Mega * 1000000 + Sec).


% make announce of our local services via tpic
make_announce(_Dict, _State) ->
    lager:debug("Announcing our local services"),
    ok.

find_service(Pid, #{pids:=PidDict}) when is_pid(Pid) ->
    lager:debug("find service by pid ~p", [Pid]),
    maps:find(Pid, PidDict);

find_service(Name, #{names:=NamesDict}) when is_binary(Name) ->
    lager:debug("find service by name ~p", [Name]),
    maps:find(Name, NamesDict).

register_service(Name, Pid, #{names:=NameDict, pids:=PidDict} = _Dict) ->
    Record = #{
        pid => Pid,
        monitor => monitor(process, Pid),
        updated => get_unixtime()
    },
    #{
        names=>maps:put(Name, Record, NameDict),
        pids=>maps:put(Pid, Name, PidDict)
    }.


delete_service(Name, #{pids:=PidsDict, names:=NamesDict} = Dict) when is_binary(Name) ->
    case find_service(Name, Dict) of
        {ok, #{pid := Pid, monitor := Ref}} ->
            demonitor(Ref),
            Dict#{
                pids => maps:without([Pid], PidsDict),
                names => maps:without([Name], NamesDict)
            };
        error ->
            lager:debug("try to delete service with unexisting name ~p", [Name]),
            Dict
    end;

delete_service(Pid, Dict) when is_pid(Pid) ->
    case find_service(Pid, Dict) of
        {ok, Name} ->
            delete_service(Name, Dict);
        error ->
            lager:debug("try to delete service with unexisting pid ~p", [Pid]),
            Dict
    end.


% check if local service is exists
query_local(Name, Dict, State) ->
    case maps:is_key(Name, Dict) of
        false -> [];
        true -> get_config(addresses, [], State)
    end.

% find addresses of remote service
query_remote(Name, Dict) ->
    Nodes = maps:get(Name, Dict, #{}),
    Announces = maps:values(Nodes),
    lists:map(
        fun(#{address:=Address}) ->
            Address
        end, Announces
    ).


% find service by name
query(Name, State) ->
    #{local_services := LocalDict, remote_services := RemoteDict} = State,
    Local = query_local(Name, LocalDict, State),
    Remote = query_remote(Name, RemoteDict),
    lists:merge(Local, Remote).


address2key(#{ip:=Ip, port:=Port, proto:=Proto}) ->
    {Ip, Port, Proto}.


% foreign service announce validation
validate_announce(Announce, State) ->
    try
        #{valid_until:=ValidUntil} = Announce,
        MaxExpireTime = get_unixtime() + get_config(max_allowed_ttl, 1800, State),
        case ValidUntil =< MaxExpireTime of
            true -> ok;
            false -> throw(expire_too_big)
        end,
        case ValidUntil < get_unixtime() of
            true -> throw(expired);
            false -> ok
        end
    catch
        throw:_ ->
            lager:debug("invalid announce ~p", [Announce]),
            error
    end,
    ok.

% parse foreign service announce and add it to services database
process_announce(Announce, Dict) ->
    #{name := Name, address := Address} = Announce,
    Key = address2key(Address),
    Nodes = maps:get(Name, Dict, #{}),
    UpdatedNodes = maps:put(Key, Announce, Nodes),
    maps:put(Name, UpdatedNodes, Dict).


% make announce of our local services
%%make_announce() ->


% --------------------------------------------------------

filter_expired(Dict, CurrentTime) ->
    NodesMapper =
        fun(_Name, Nodes) ->
            ExpireFilter =
                fun(_AddrKey, Announce) ->
                    #{valid_until:=RecordValidUntil} = Announce,
                    (RecordValidUntil > CurrentTime)
                end,
            maps:filter(ExpireFilter, Nodes)
        end,
    maps:map(NodesMapper, Dict).


%% -----------------



test() ->
    gen_server:call(discovery, {register, <<"test_service">>, self()}),
    gen_server:call(discovery, {register, <<"test_service2">>, self()}),
%%  io:fwrite("state ~p", [ gen_server:call(discovery, {state}) ]),
    {ok, Pid, Name} = gen_server:call(discovery, {get_pid, <<"test_service">>}),
    io:fwrite("pid for ~p is ~p ~n", [Name, Pid]),
    [] = gen_server:call(discovery, {lookup, <<"nonexist">>}),
    Lookup = gen_server:call(discovery, {lookup, <<"test_service">>}),
    io:fwrite("lookup ~p~n", [Lookup]),
    gen_server:call(discovery, {unregister, <<"test_service">>}),
    {error, not_found, _} = gen_server:call(discovery, {get_pid, <<"test_service">>}),
    gen_server:call(discovery, {unregister, <<"test_service">>}),
    gen_server:call(discovery, {unregister, self()}),
    ok.



test1() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{ip => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => 10
    },
%%  gen_server:cast(discovery, {got_announce, Announce}),
    D1 = process_announce(Announce, #{}),
    D2 = process_announce(Announce#{name => <<"looking_glass2">>}, D1),
    D3 = process_announce(Announce#{
        name => <<"looking_glass2">>,
        address => #{ip => <<"127.0.0.2">>, port => 1234, proto => tpic}
    }, D2),
    D4 = process_announce(Announce#{name => <<"looking_glass2">>, valid_until => 20}, D3),
    query_remote(<<"looking_glass2">>, D4).

test2() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{ip => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => get_unixtime() + 100500
    },
    gen_server:cast(discovery, {got_announce, Announce}),
    gen_server:call(discovery, {state}).

test3() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{ip => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => get_unixtime() + 2
    },
    gen_server:cast(discovery, {got_announce, Announce}),
    erlang:send(discovery, cleanup),
    gen_server:call(discovery, {state}).

