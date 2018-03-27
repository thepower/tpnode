% -*- mode: erlang -*-
% vi: set ft=erlang :
-module(discovery).

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-define(DEFAULT_SCOPE, [tpic, xchain, api]).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-export([my_address_v4/0,my_address_v6/0]).

-export([test/0, test1/0, test2/0, test3/0, test4/0]).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    Name = maps:get(name, Options, discovery),
    lager:notice("start_link for ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).

my_address_v6() ->
    {ok,IL}=inet:getifaddrs(),
    lists:foldl(
      fun({_NetIf,Flags},Acc0) ->
              lists:foldl(
                fun({addr,{0,_,_,_,_,_,_,_}},Acc1) ->
                        Acc1;
                   ({addr,{16#fe80,_,_,_,_,_,_,_}},Acc1) ->
                        Acc1;
                   ({addr,{_,_,_,_,_,_,_,_}=A},Acc1) ->
                        [inet:ntoa(A)|Acc1];
                   (_,Acc1) -> Acc1
                end, Acc0, Flags)
      end, [], IL).

my_address_v4() ->
    {ok,IL}=inet:getifaddrs(),
    lists:foldl(
      fun({_NetIf,Flags},Acc0) ->
              lists:foldl(
                fun({addr,{127,_,_,_}},Acc1) ->
                        Acc1;
                   ({addr,{_,_,_,_}=A},Acc1) ->
                        [inet:ntoa(A)|Acc1];
                   (_,Acc1) -> Acc1
                end, Acc0, Flags)
      end, [], IL).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    lager:notice("start discovery"),
    CheckExpireInterval = maps:get(check_expire_interval, Args, 60), % in seconds
    Settings = read_config(),
    AnnounceServicesInterval = maps:get(announce_interval, Settings, 60), % in seconds
    LocalServices =
        #{
            names => #{},
            pids => #{}
        },
    PermanentServices = maps:get(services, Args, []),

    {ok, #{
        settings => Settings,
        local_services => init_local_serivces(PermanentServices, LocalServices),
        remote_services => #{},
        check_expire_interval => CheckExpireInterval,
        announce_interval => AnnounceServicesInterval,
        cleantimer => erlang:send_after(CheckExpireInterval * 1000, self(), cleanup),
        announcetimer => erlang:send_after(10 * 1000, self(), make_announce)
    }}.


handle_call(state, _From, State) ->
    lager:notice("state request", []),
    {reply, State, State};

handle_call({get_config, Key}, _From, State) ->
    {reply, get_config(Key, undefined, State), State};

handle_call({get_config, Key, Default}, _From, State) ->
    {reply, get_config(Key, Default, State), State};

handle_call({set_config, Key, Value}, _From, State) ->
    {reply, ok, set_config(Key, Value, State)};

handle_call({register, ServiceName, Pid}, _From, #{local_services:=Dict} = State) ->
    lager:debug("Register local service ~p with pid ~p", [ServiceName, Pid]),
    {reply, ok, State#{
        local_services => register_service(ServiceName, Pid, Dict, #{})
    }};

handle_call({register, ServiceName, Pid, Options}, _From, #{local_services:=Dict} = State) ->
    lager:debug("Register local service ~p with pid ~p", [ServiceName, Pid]),
    {reply, ok, State#{
        local_services => register_service(ServiceName, Pid, Dict, Options)
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

handle_call({lookup, Pred}, _From, State) when is_function(Pred) ->
    {reply, query(Pred, State), State};

handle_call({lookup, Name}, _From, State) ->
    {reply, query(Name, State), State};

handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p", [_Request]),
    {reply, ok, State}.


handle_cast(make_announce, #{local_services:=Dict} = State) ->
    lager:debug("Make local services announce (cast)"),
    make_announce(Dict, State),
    {noreply, State};


handle_cast({got_announce, AnnounceBin}, #{remote_services:=Dict} = State) ->
%%    lager:debug("Got service announce ~p", [AnnounceBin]),
    try
        Announce =
            case unpack(AnnounceBin) of
                error -> throw(error);
                {ok, Unpacked} -> Unpacked
            end,

        lager:debug("Announce details: ~p", [Announce]),

        case validate_announce(Announce, State) of
            error -> throw(error);
            _ -> ok
        end,

        case is_local_service(Announce) of
            true ->
                lager:debug("skip copy of local service: ~p", [Announce]),
                throw(error);
            _ -> ok
        end,

        {noreply, State#{
            remote_services => process_announce(Announce, Dict, AnnounceBin)
        }}

    catch
        throw:error ->
            {noreply, State}
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

handle_info(make_announce, #{announcetimer:=Timer} = State) ->
    catch erlang:cancel_timer(Timer),
    #{
        local_services:=Dict,
        announce_interval:=AnnounceInterval} = State,

    lager:debug("Make local services announce (timer)"),
    make_announce(Dict, State),

    {noreply, State#{
        announcetimer => erlang:send_after(AnnounceInterval * 1000, self(), make_announce)
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


init_local_serivces(PermanentServices, Dict) ->
    Registrator =
        fun F(ServiceName, CurrentDict) when is_binary(ServiceName) ->
            Name = <<ServiceName/binary, "peer">>,
            register_service(Name, nopid, CurrentDict, #{});
            F(ServiceName, CurrentDict) when is_list(ServiceName) ->
                F(list_to_binary(ServiceName), CurrentDict);
            F(ServiceName, CurrentDict) when is_atom(ServiceName) ->
                F(atom_to_binary(ServiceName, utf8), CurrentDict);
            F(_InvalidServiceName, CurrentDict) ->
                lager:info("invalid permanent service name: ~p", [_InvalidServiceName]),
                CurrentDict
        end,
    lists:foldl(Registrator, Dict, PermanentServices).

read_config() ->
    application:get_env(tpnode, discovery, #{}).

get_config(Key, Default, State) ->
    #{settings:=Config} = State,
    maps:get(Key, Config, Default).

set_config(Key, Value, State) ->
    #{settings:=Config} = State,
    State#{
        settings => maps:put(Key, Value, Config)
    }.

get_unixtime() ->
    {Mega, Sec, _Micro} = os:timestamp(),
    (Mega * 1000000 + Sec).



announce_one_service(Name, Address, ValidUntil, Scopes) ->
    try
        TranslatedAddress = translate_address(Address),
        lager:debug(
            "make announce for service ~p, address: ~p, scopes: ~p",
            [Name, TranslatedAddress, Scopes]
        ),
        Announce = #{
            name => Name,
            address => TranslatedAddress,
            valid_until => ValidUntil,
            nodeid => nodekey:node_id(),
            scopes => Scopes
        },
        AnnounceBin = pack(Announce),
        send_service_announce(AnnounceBin)
    catch
        Err:Reason ->
            lager:error(
                "Announce with name ~p and address ~p and scopes ~p hasn't made because ~p ~p",
                [Name, Address, Scopes, Err, Reason]
            )
    end.


%%is_address_advertisable(Address, #{options:=Options} = _ServiceOptions) ->
%%    is_address_advertisable(Address, {options, Options});
%%
%%is_address_advertisable(Address, {options, #{filter:=Filter} = _Options}) ->
%%    is_address_advertisable(Address, {filter, Filter});
%%
%%% filter services by protocol
%%is_address_advertisable(#{proto:=Proto} = _Address, {filter, #{proto:=FilterProto}=_Filter})
%%    when Proto == FilterProto ->
%%    true;
%%
%%is_address_advertisable(_Address, _ServiceOptions) ->
%%    false.
%%


%%find_local_service(
%%  #{address:=AnnIp, port:=AnnPort} = _Announce,
%%  [ #{address:=LocalIp, port:=LocalPort} = _Address | Rest ]
%%) when AnnIp =:= LocalIp andalso AnnPort =:= LocalPort ->
%%    true;
%%
%%find_local_service( _Announce, [] )->
%%    false;
%%
%%find_local_service(Announce, [ _Address | Rest ]) ->
%%    find_local_service(Announce, Rest).
%%
%%
%%is_local_service(Announce, State) ->
%%    LocalServices = get_config(addresses, [], State),
%%    TranslatedLocalServices = lists:map(
%%        fun(Address) -> translate_address(Address) end,
%%        LocalServices
%%    ),
%%    find_local_service(Announce, TranslatedLocalServices).


is_local_service(#{<<"nodeid">>:=RemoteNodeId} = _Announce) ->
    MyNodeId = nodekey:node_id(),
    MyNodeId =:= RemoteNodeId;

is_local_service(_Announce) ->
    false.




% return true if Scope is exists for ServiceName in AllScopesCfg configuration,
% we use scopes [tpic, xchain, api] by default if configuration for ServiceName isn't exists in config.
in_scope(ServiceName, ScopeToCheck, AllScopesCfg) ->
    AllowedScopes = get_scopes(ServiceName, AllScopesCfg),
    lists:member(ScopeToCheck, AllowedScopes).

get_scopes(ServiceName, AllScopesCfg) ->
    maps:get(ServiceName, AllScopesCfg, ?DEFAULT_SCOPE).

is_right_proto(ServiceName, Proto) when is_binary(Proto) ->
    (<<Proto/binary, "peer">> =:= ServiceName);

is_right_proto(ServiceName, Proto) when is_atom(Proto) ->
    is_right_proto(ServiceName, atom_to_binary(Proto, utf8));

is_right_proto(ServiceName, Proto) when is_list(Proto) ->
    is_right_proto(ServiceName, list_to_binary(Proto));

is_right_proto(_ServiceName, Proto) ->
    lager:info("invalid protocol: ~p", Proto),
    false.


% make announce of our local services with tpic scope
make_announce(#{names:=Names} = _Dict, State) ->
    lager:debug("Announcing our local services"),
    ValidUntil = get_unixtime() + get_config(our_ttl, 120, State),
    Addresses = get_config(addresses, [], State),
    AllScopesCfg = get_config(scope, #{}, State),

    Announcer = fun(Name, _ServiceSettings, Counter) ->
        Counter + lists:foldl(
            % #{address => local4, port => 53221, proto => tpic}
            fun(#{proto := Proto} = Address, AddrCounter) ->
                Scopes = get_scopes(Proto, AllScopesCfg),
                IsAdvertisable = in_scope(Proto, tpic, AllScopesCfg),
                IsRightProto = is_right_proto(Name, Proto),
                lager:debug("ann dbg ~p ~p ~p ~p", [Name, IsAdvertisable, IsRightProto, Address]),

                if
                    IsRightProto == true andalso IsAdvertisable == true ->
                        announce_one_service(Name, Address, ValidUntil, Scopes),
                        AddrCounter + 1;
                    true ->
                        lager:debug("skip announce for address ~p ~p", [Name, Address]),
                        AddrCounter
                end;
                ( Address, AddrCounter ) ->
                    lager:debug("skip announce for invalid address ~p ~p", [Name, Address]),
                    AddrCounter
            end,
            0,
            Addresses)
        end,
    ServicesCount = maps:fold(Announcer, 0, Names),
    lager:debug("Announced ~p of our services", [ServicesCount]),
    ok.

find_service(Pid, #{pids:=PidDict}) when is_pid(Pid) ->
    lager:debug("find service by pid ~p", [Pid]),
    maps:find(Pid, PidDict);

find_service(Name, #{names:=NamesDict}) when is_binary(Name) ->
    lager:debug("find service by name ~p", [Name]),
    maps:find(Name, NamesDict).


register_service(Name, Pid, #{names:=NameDict, pids:=PidDict} = _Dict, Options) ->
    Record0 = #{
        pid => Pid,
        monitor => nopid,
        updated => get_unixtime(),
        options => Options
    },

    Record =
        case Pid of
            nopid ->
                Record0;
            _ ->
                Record0#{
                    monitor => monitor(process, Pid)
                }
        end,

    NewNames = maps:put(Name, Record, NameDict),

    NewPidDict =
        case Pid of
            nopid ->
                PidDict;
            _ ->
                maps:put(Pid, Name, PidDict)
        end,

    #{
        names => NewNames,
        pids => NewPidDict
    }.



% delete local service from local dict
delete_service(nopid, Dict) ->
    Dict;

delete_service(Name, #{pids:=PidsDict, names:=NamesDict} = Dict) when is_binary(Name) ->
    case find_service(Name, Dict) of
        {ok, #{pid := nopid}} ->
            Dict#{
                names => maps:without([Name], NamesDict)
            };
        {ok, #{pid := Pid, monitor := Ref}} ->
            demonitor(Ref),
            Dict#{
                pids => maps:without([Pid], PidsDict),
                names => maps:without([Name], NamesDict)
            };
        Invalid ->
            lager:debug("try to delete service with unexisting name ~p, result ~p", [Name, Invalid]),
            Dict
    end;

delete_service(nopid, Dict) ->
    Dict;

delete_service(Pid, Dict) when is_pid(Pid) ->
    case find_service(Pid, Dict) of
        {ok, Name} ->
            delete_service(Name, Dict);
        error ->
            lager:debug("try to delete service with unexisting pid ~p", [Pid]),
            Dict
    end;

delete_service(InvalidName, Dict) ->
    lager:debug("try to delete service with invalid name ~p", [InvalidName]),
    Dict.



% translate IP address aliases to local IPv4 or IPv6 address
translate_address(#{address:=IP}=Address0) when is_map(Address0) ->
    case IP of
        local4 ->
            maps:put(address, hd(discovery:my_address_v4()), Address0);
        local6 ->
            maps:put(address, hd(discovery:my_address_v6()), Address0);
        _ ->
            Address0
    end.


% check if local service is exists
query_local(Name, #{names:=Names}=_Dict, State) ->
    case maps:is_key(Name, Names) of
        false -> [];
        true ->
            LocalAddresses = get_config(addresses, [], State),
            RightAddresses = lists:filter(
                fun(#{proto:=Proto}) ->
                    is_right_proto(Name, Proto);
                    (_InvalidAddress) ->
                        lager:info("invalid address: ~p", [_InvalidAddress]),
                        false
                end,
                LocalAddresses
            ),
            lists:map(
                fun(Address) -> translate_address(Address) end,
                RightAddresses
            )
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

query(Pred, _State) when is_function(Pred) ->
    lager:error("Not inmplemented"),
    error;


% find service by name
query(Name, State) ->
    #{local_services := LocalDict, remote_services := RemoteDict} = State,
    Local = query_local(Name, LocalDict, State),
    Remote = query_remote(Name, RemoteDict),
%%    lager:debug("query ~p local: ~p", [Name, Local]),
%%    lager:debug("query ~p remote: ~p", [Name, Remote]),
    lists:merge(Local, Remote).


address2key(#{address:=Ip, port:=Port, proto:=Proto}) ->
    {Ip, Port, Proto};

address2key(Invalid) ->
    lager:info("invalid address: ~p", [Invalid]),
    throw(invalid_address).


% foreign service announce validation
validate_announce(
          #{
              name := _Name,
              address := _Address,
              valid_until := ValidUntil,
              nodeid := _NodeId,
              scopes := _Scopes
          } = Announce,
          State) ->
    try
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
    ok;

validate_announce(Announce, _State) ->
    lager:debug("invalid announce ~p", [Announce]),
    error.


% parse foreign service announce and add it to services database
process_announce(#{name := Name, address := Address} = Announce, Dict, AnnounceBin) ->
    try
        Key = address2key(Address),
        Nodes = maps:get(Name, Dict, #{}),
        PrevAnnounce = maps:get(Key, Nodes, #{valid_until => 0}),
        relay_announce(PrevAnnounce, Announce, AnnounceBin),
        UpdatedNodes = maps:put(Key, Announce, Nodes),
        maps:put(Name, UpdatedNodes, Dict)
    catch
        Err:Reason ->
            lager:error("skip announce ~p because error: ~p ~p", [Announce, Err, Reason]),
            Dict
    end;

process_announce(Announce, Dict, _AnnounceBin) ->
    lager:error("invalid announce: ~p", [Announce]),
    Dict.


% relay announce to connected nodes
relay_announce(
        #{valid_until:=ValidUntilPrev} = _PrevAnnounce,
        #{valid_until:=ValidUntilNew, nodeid:=NodeId} = NewAnnounce,
        AnnounceBin)
    when is_binary(AnnounceBin)
    andalso size(AnnounceBin) > 0 ->

    MyNodeId = nodekey:node_id(),
    if
        NodeId =:= MyNodeId ->
            lager:debug("skip relaying of self announce: ~p", [NewAnnounce]),
            norelay;
        ValidUntilPrev /= ValidUntilNew ->
            lager:debug("relay announce ~p", [NewAnnounce]),
            send_service_announce(AnnounceBin);
        ValidUntilPrev =:= ValidUntilNew ->
%%            lager:debug("skip relaying of announce (equal validuntil): ~p", [NewAnnounce]),
            norelay;
        true ->
            lager:debug("skip relaying of announce: new ~p, prev ~p", [NewAnnounce, _PrevAnnounce]),
            norelay
    end;

relay_announce(_PrevAnnounce, NewAnnounce, _AnnounceBin) ->
    lager:debug("skip relaying of invalid announce ~p", [NewAnnounce]),
    norelay.


send_service_announce(AnnounceBin) ->
%%    lager:debug("send tpic announce ~p", [AnnounceBin]),
    tpic:cast(tpic, service, {<<"discovery">>, AnnounceBin}).

add_sign_to_bin(Sign, Data) ->
    <<254, (size(Sign)):8/integer, Sign/binary, Data/binary>>.

split_bin_to_sign_and_data(<<254, SignLen:8/integer, Rest/binary>>) ->
    <<Sign:SignLen/binary, Data/binary>>=Rest,
    {Sign, Data};

split_bin_to_sign_and_data(Bin) ->
    lager:info("invalid sign format: ~p", [Bin]),
    {<<>>, <<>>}.


pack(Message) ->
    PrivKey=nodekey:get_priv(),
    Packed = msgpack:pack(Message),
    Hash = crypto:hash(sha256, Packed),
    Sign = bsig:signhash(
        Hash,
        [{timestamp,os:system_time(millisecond)}],
        PrivKey
    ),
    add_sign_to_bin(Sign, Packed).



unpack(<<254, _Rest/binary>> = Packed) ->
    try
        {Sign, Bin} = split_bin_to_sign_and_data(Packed),
        Hash = crypto:hash(sha256, Bin),
        case bsig:checksig(Hash, [Sign]) of
            { [ #{ signature:= _FirstSign } | _] , _InvalidSings} ->
                lager:notice("Check signature here");
            _X ->
                lager:debug("checksig result ~p", [_X]),
                throw(invalid_signature)
        end,
        Atoms = [address, name, valid_until, port, proto, tpic, nodeid, scopes, xchain, api],
        case msgpack:unpack(Bin, [{known_atoms, Atoms}]) of
            {ok, Message} ->
                {ok, Message};
            _ -> throw(msgpack)
        end
    catch throw:Reason ->
        lager:info("can't unpack announce with reason ~p ~p", [Reason, Packed]),
        error
    end;

unpack(Packed) ->
    lager:info("Invalid packed data ~p", [Packed]),
    error.

% --------------------------------------------------------

filter_expired(Dict, CurrentTime) ->
    NodesMapper =
        fun(_Name, Nodes) ->
            ExpireFilter =
                fun(_AddrKey, #{valid_until:=RecordValidUntil}) ->
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
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => 10
    },
%%  gen_server:cast(discovery, {got_announce, Announce}),
    D1 = process_announce(Announce, #{}, <<>>),
    D2 = process_announce(Announce#{name => <<"looking_glass2">>}, D1, <<>>),
    D3 = process_announce(Announce#{
        name => <<"looking_glass2">>,
        address => #{address => <<"127.0.0.2">>, port => 1234, proto => tpic}
    }, D2, <<>>),
    D4 = process_announce(Announce#{name => <<"looking_glass2">>, valid_until => 20}, D3, <<>>),
    query_remote(<<"looking_glass2">>, D4).

test2() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => get_unixtime() + 100500
    },
    gen_server:cast(discovery, {got_announce, Announce}),
    gen_server:call(discovery, {state}).

test3() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => get_unixtime() + 2
    },
    gen_server:cast(discovery, {got_announce, Announce}),
    erlang:send(discovery, cleanup),
    gen_server:call(discovery, {state}).

test4() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        valid_until => get_unixtime() + 100
    },
    Packed = pack(Announce),
    io:fwrite("packed: ~n~p~n", [ Packed ]),
    {ok, Message} = unpack(Packed),
    io:fwrite("message: ~n~p~n", [ Message ]).
