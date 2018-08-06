% -*- mode: erlang -*-
% vi: set ft=erlang :
-module(discovery).

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-define(DEFAULT_SCOPE, [tpic, xchain, api]).
-define(DEFAULT_SCOPE_CONFIG, #{
    tpic => [tpic],
    api => [tpic, xchain, api],
    apis => [tpic, xchain, api]
}).

-define(KNOWN_ATOMS,
  [address, name, valid_until, port, proto, tpic, nodeid, scopes,
    xchain, api, apis, chain, created, ttl, hostname]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1, lookup/2, lookup/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-export([my_address_v4/0, my_address_v6/0]).


% ------ for tests ---
-export([pack/1, unpack/1]).
-export([test/0, test1/0, test2/0, test3/0, test4/0]).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    Name = maps:get(name, Options, discovery),
    lager:notice("start_link for ~p", [Name]),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).

my_address_v6() ->
  {ok, IL} = inet:getifaddrs(),
  lists:foldl(
    fun({_NetIf, Flags}, Acc0) ->
      lists:foldl(
        fun
          ({addr, {0, _, _, _, _, _, _, _}}, Acc1) ->
            Acc1;
          ({addr, {16#fe80, _, _, _, _, _, _, _}}, Acc1) ->
            Acc1;
          ({addr, {_, _, _, _, _, _, _, _} = A}, Acc1) ->
            [inet:ntoa(A) | Acc1];
          (_, Acc1) -> Acc1
        end, Acc0, Flags)
    end, [], IL).

my_address_v4() ->
  {ok, IL} = inet:getifaddrs(),
  lists:foldl(
    fun({_NetIf, Flags}, Acc0) ->
      lists:foldl(
        fun({addr, {127, _, _, _}}, Acc1) ->
          Acc1;
          ({addr, {_, _, _, _} = A}, Acc1) ->
            [inet:ntoa(A) | Acc1];
          (_, Acc1) -> Acc1
        end, Acc0, Flags)
    end, [], IL).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    lager:notice("start discovery"),
    CheckExpireInterval = maps:get(check_expire_interval, Args, 10), % in seconds
    Hostname = application:get_env(tpnode, hostname, unknown),
    Settings0 = maps:put(hostname, Hostname, read_config()), % copy hostname from global tpnode config into our local configs inside state
    Settings = maps:put(macro_dict, build_macro_dict(), Settings0),
    AnnounceServicesInterval = maps:get(announce_interval, Settings, 120), % in seconds
    LocalServices =
        #{
            names => #{},
            pids => #{}
        },
    MandatoryServices = maps:get(services, Args, []),

    {ok, #{
        settings => Settings,
        local_services => init_local_serivces(MandatoryServices, LocalServices),
        remote_services => #{},
        check_expire_interval => CheckExpireInterval,
        announce_interval => AnnounceServicesInterval,
        cleantimer => erlang:send_after(CheckExpireInterval * 1000, self(), cleanup),
        announcetimer => erlang:send_after(rand:uniform(15) * 1000, self(), make_announce)
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

handle_call(get_local_addresses, _From, State) ->
  {reply, get_local_addresses(State), State};


%% register Pid as new local service with name ServiceName
handle_call({register, ServiceName, Pid}, _From, #{local_services:=Dict} = State) ->
    {reply, ok, State#{
        local_services => register_service(ServiceName, Pid, Dict)
    }};

handle_call({register, ServiceName, Pid, Options}, _From, #{local_services:=Dict} = State) ->
    {reply, ok, State#{
        local_services => register_service(ServiceName, Pid, Dict, Options)
    }};

%% remove registration for all local services with pid Pid
handle_call({unregister, Pid}, _From, #{local_services:=LocalDict} = State) when is_pid(Pid) ->
    lager:debug("Unregister local service with pid ~p", [Pid]),
    {reply, ok, State#{
        local_services => delete_service(Pid, LocalDict)
    }};

%% remove registration for local serivce with name Name
handle_call({unregister, Name}, _From, #{local_services:=Dict} = State) when is_binary(Name) ->
    lager:debug("Unregister local service with name ~p", [Name]),
    {reply, ok, State#{
        local_services => delete_service(Name, Dict)
    }};

%% get pid for local service with name Name
handle_call({get_pid, Name}, _From, #{local_services:=Dict} = State) when is_binary(Name) ->
    lager:debug("Get pid for local service with name ~p", [Name]),
    Reply = case find_service(Name, Dict) of
                {ok, #{pid:=Pid}} -> {ok, Pid, Name};
                error -> {error, not_found, Name}
            end,
    {reply, Reply, State};

handle_call({lookup, Pred}, _From, State) when is_function(Pred) ->
    {reply, query(Pred, State), State};

%% get list of ip and port for service with name Name (local and remote)
handle_call({lookup, Name}, _From, State) ->
    {reply, query(Name, State), State};

handle_call({lookup, Name, Chain}, _From, State) ->
    {reply, query(Name, Chain, State), State};


handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p", [_Request]),
    {reply, ok, State}.


handle_cast(make_announce, #{local_services:=Dict} = State) ->
    lager:debug("Make local services announce (cast)"),
    make_announce(Dict, State),
    {noreply, State};


handle_cast({got_announce, AnnounceBin}, State) ->
    lager:debug("Got service announce ~p", [AnnounceBin]),
    try
        MaxTtl = get_config(intrachain_ttl, 300, State),

        {noreply, State#{
            remote_services => parse_and_process_announce(MaxTtl, AnnounceBin, State)
        }}
    catch
        skip ->
            {noreply, State};
        Err:Reason ->
            lager:info("can't process announce ~p ~p", [Err, Reason]),
            {noreply, State}
    end;

handle_cast({got_xchain_announce, AnnounceBin}, State) ->
%%    lager:debug("Got service announce ~p", [AnnounceBin]),
    try
        MaxTtl = get_config(xchain_ttl, 1800, State),

        {noreply, State#{
            remote_services => parse_and_process_announce(MaxTtl, AnnounceBin, State)
        }}
    catch
        skip ->
            {noreply, State};
        Err:Reason ->
            lager:info("can't process announce ~p ~p", [Err, Reason]),
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
        remote_services => filter_expired(RemoteDict, os:system_time(seconds))
    }};

handle_info(make_announce, #{announcetimer:=Timer} = State) ->
    catch erlang:cancel_timer(Timer),
    #{
        local_services:=Dict,
        announce_interval:=AnnounceInterval} = State,

    OurChain = blockchain:chain(),
    if
        OurChain =:= 0 ->
            lager:debug("Skip local services announce because of our chain is 0");
        true ->
            lager:debug("Make local services announce (timer)"),
            make_announce(Dict, State)
    end,

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
        fun (ServiceName0, CurrentDict)->
            ServiceName = convert_to_binary(ServiceName0),
            Name = <<ServiceName/binary, "peer">>,
            register_service(Name, nopid, CurrentDict, #{})
        end,
    lists:foldl(Registrator, Dict, PermanentServices).

% --------------------------------------------------------
read_config() ->
    application:get_env(tpnode, discovery, #{}).

% --------------------------------------------------------

get_config(Key, Default, State) ->
    #{settings:=Config} = State,
    maps:get(Key, Config, Default).

% --------------------------------------------------------
set_config(Key, Value, State) ->
    #{settings:=Config} = State,
    State#{
        settings => maps:put(Key, Value, Config)
    }.

% --------------------------------------------------------
get_local_addresses(State) ->
  Addresses = get_config(addresses, [], State),
  Hostname = application:get_env(tpnode, hostname, unknown),
  MacroDict = get_config(macro_dict, #{}, State),
  Translator =
    fun
      (Address, Translated) ->
        try
          TranslatedAddress =
            add_hostname(substitute_macro(Address, MacroDict), Hostname),
          [TranslatedAddress | Translated]
        catch
          pass ->
            lager:debug("skip address (pass): ~p", [Address]),
            Translated
        end
    end,
  lists:foldl(Translator, [], Addresses).

  



% --------------------------------------------------------
announce_one_service(Name, TranslatedAddress, Ttl, Scopes) ->
    try
%%        TranslatedAddress = add_hostname(translate_address(Address), Hostname),
        
        lager:debug(
            "make announce for service ~p, address: ~p, scopes: ~p",
            [Name, TranslatedAddress, Scopes]
        ),

        Announce = #{
            name => Name,
            address => TranslatedAddress,
%%            valid_until => ValidUntil,
            created => os:system_time(seconds),
            ttl => Ttl,
            nodeid => nodekey:node_id(),
            scopes => Scopes,
            chain => blockchain:chain()
        },
        AnnounceBin = pack(Announce),
        send_service_announce(local, AnnounceBin)
    catch
        Err:Reason ->
            lager:error(
                "Announce with name ~p and address ~p and scopes ~p hasn't made because ~p ~p",
                [Name, TranslatedAddress, Scopes, Err, Reason]
            )
    end.

% ------------------------------------------------------------
-spec is_local_service(Announce :: #{ 'nodeid' := _, _ := _ }) -> boolean().

is_local_service(#{nodeid:=RemoteNodeId} = _Announce) ->
    MyNodeId = nodekey:node_id(),
    MyNodeId =:= RemoteNodeId;

is_local_service(#{<<"nodeid">>:=RemoteNodeId} = Announce) ->
    is_local_service(Announce#{nodeid => RemoteNodeId});

is_local_service(_Announce) ->
    false.

% ------------------------------------------------------------

% return true if Scope is exists for ServiceName in AllScopesCfg configuration,
% we use scopes [tpic, xchain, api] by default if configuration for ServiceName isn't exists in config.
in_scope(ServiceName, ScopeToCheck, AllScopesCfg) ->
    AllowedScopes = get_scopes(ServiceName, AllScopesCfg),
    lists:member(ScopeToCheck, AllowedScopes).

% --------------------------------------------------------

get_scopes(ServiceName, AllScopesCfg) ->
    maps:get(ServiceName, AllScopesCfg, ?DEFAULT_SCOPE).


get_default_addresses() ->
    TpicConfig = application:get_env(tpnode, tpic, #{}),
    TpicPort = maps:get(port, TpicConfig, unknown),
    if
        TpicPort =:= unknown ->
            lager:info("Default tpic config isn't found");
        true ->
            [
                #{address => local4, port => TpicPort, proto => tpic},
                #{address => local6, port => TpicPort, proto => tpic}
            ]
    end.

% --------------------------------------------------------

is_right_proto(ServiceName, Proto)  ->
    (<<(utils:make_binary(Proto))/binary, "peer">> =:= ServiceName).

% --------------------------------------------------------

get_local_names(Names) ->
  case tpnode_cert:is_ssl_started() of
    true ->
      maps:keys(Names) ++ [<<"apispeer">>];
    _ ->
      maps:keys(Names)
  end.

% --------------------------------------------------------

% make announce of our local services with tpic scope
make_announce(#{names:=Names} = _Dict, State) ->
  lager:debug("Announcing our local services"),
  Ttl = max(get_config(intrachain_ttl, 300, State), 30),
  Hostname = application:get_env(tpnode, hostname, unknown),
%%    ValidUntil = os:system_time(seconds) + get_config(intrachain_ttl, 120, State),
  Addresses = get_config(addresses, get_default_addresses(), State),
  AllScopesCfg = get_config(scope, ?DEFAULT_SCOPE_CONFIG, State),
  MacroDict = get_config(macro_dict, #{}, State),
  
  LocalNames = get_local_names(Names),
  
  Announcer = fun(Name, Counter) ->
    Counter + lists:foldl(
      % #{address => local4, port => 53221, proto => tpic}
      fun(#{proto := Proto} = Address, AddrCounter) ->
        Scopes = get_scopes(Proto, AllScopesCfg),
        IsAdvertisable = in_scope(Proto, tpic, AllScopesCfg),
        IsRightProto = is_right_proto(Name, Proto),
%%        lager:debug("ann dbg ~p ~p ~p ~p", [Name, IsAdvertisable, IsRightProto, Address]),
        
        if
          IsRightProto == true andalso IsAdvertisable == true ->
            try
              TranslatedAddress =
                add_hostname(substitute_macro(Address, MacroDict), Hostname),
              announce_one_service(Name, TranslatedAddress, Ttl, Scopes),
              AddrCounter + 1
            catch
              pass ->
                lager:debug("skip address (can't substitute macro?): ~p", [Address]),
                AddrCounter
            end;
          
          true ->
%%            lager:debug("skip announce for address ~p ~p", [Name, Address]),
            AddrCounter
        end;
        (Address, AddrCounter) ->
          lager:debug("skip announce for invalid address ~p ~p", [Name, Address]),
          AddrCounter
      end,
      0,
      Addresses)
              end,
  ServicesCount = lists:foldl(Announcer, 0, LocalNames),
  lager:debug("Announced ~p of our services", [ServicesCount]),
  ok.

% --------------------------------------------------------
-spec find_service(pid() | binary(), #{'names'=>map(), 'pids'=>map()}) ->
    'error' | {ok, _}.

%%find_service(Pid, #{pids:=PidsDict}) when is_pid(Pid) ->
%%    lager:debug("find service by pid ~p", [Pid]),
%%    maps:find(Pid, PidsDict);

find_service(Name, #{names:=NamesDict}) when is_binary(Name) ->
    lager:debug("find service by name ~p", [Name]),
    maps:find(Name, NamesDict).

% --------------------------------------------------------

register_service(Name, Pid, Dict) ->
    register_service(Name, Pid, Dict, #{}).

register_service(Name0, Pid, #{names:=NameDict, pids:=PidDict} = _Dict, Options) ->
    Name = convert_to_binary(Name0),
    lager:debug("Register local service ~p with pid ~p", [Name, Pid]),

    Record0 = #{
        pid => Pid,
        monitor => nopid,
        updated => os:system_time(seconds),
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


% --------------------------------------------------------


% delete local service from local dict
delete_service(nopid, Dict) ->
    Dict;

delete_service(Pid, #{pids:=PidsDict, names:=NamesDict} = Dict) when is_pid(Pid) ->
%%    lager:debug("deleting service by pid ~p", [Pid]),
    NewNames = maps:filter(
        fun(_Name, #{pid := Pid1}=Record) when Pid==Pid1 ->
%%            lager:debug("found service ~p with pid ~p", [_Name, Pid]),
            case maps:get(monitor, Record, not_found) of
                not_found ->
%%                    lager:debug("no monitor ref for pid ~p", [Pid]),
                    skip;
                MonitorRef ->
                    lager:debug("demonitor for pid ~p (service ~p)", [Pid, _Name]),
                    demonitor(MonitorRef)
            end,
            false;
        (_Name, _Record) ->
            true
        end,
        NamesDict),
    NewPids = maps:remove(Pid, PidsDict),
    Dict#{
        pids => NewPids,
        names => NewNames
    };


%%    case find_service(Pid, Dict) of
%%        {ok, Name} ->
%%            lager:debug("we found name ~p for pid ~p", [Name, Pid]),
%%            delete_service(Name, Dict);
%%        error ->
%%            lager:debug("try to delete service with unexisting pid ~p", [Pid]),
%%            Dict
%%    end;

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

delete_service(InvalidName, Dict) ->
    lager:debug("try to delete service with invalid name ~p", [InvalidName]),
    Dict.

% --------------------------------------------------------

%%% translate IP address aliases to local IPv4 or IPv6 address
%%translate_address(#{address:=IP} = Address) when is_map(Address) ->
%%  case IP of
%%    local4 ->
%%      maps:put(address, hd(discovery:my_address_v4()), Address);
%%    local6 ->
%%      maps:put(address, hd(discovery:my_address_v6()), Address);
%%    _ ->
%%      Address
%%  end.

% --------------------------------------------------------

substitute_macro(Address, Dict) when is_map(Address), is_map(Dict) ->
  Address1 = utils:apply_macro(Address, Dict), % apply mandatory macros
  IsSslRan = tpnode_cert:is_ssl_started(),
  Worker =
    fun
      (_K, rpcsport) ->
        case IsSslRan of
          true ->
            tpnode_http:get_ssl_port();
          _ ->
            throw(pass)  % we can't resolve this macro because ssl is down
        end;

      (address, local6) ->
        case my_address_v6() of
          [] ->
            lager:error("can't find ipv6 address for local6 macro"),
            throw(pass); % skip this address announce because host don't support ipv6
          IPv6Addresses ->
            hd(IPv6Addresses)
        end;
        
      (proto, apis) when IsSslRan =/= true ->
        lager:error("skip apis proto because ssl is down right now"),
        throw(pass);  % we can't announce this proto because ssl is down
      
      (_K, V) ->
        V
    end,
  maps:map(Worker, Address1).

% --------------------------------------------------------
build_macro_dict() ->
  DictKeys = [local4, rpcport, tpicport],  % mandatory macro names
  Worker =
    fun
      (local4, Dict) ->
        maps:put(local4, hd(my_address_v4()), Dict);
%%      (local6, Dict) ->
%%        maps:put(local6, hd(my_address_v6()), Dict);
      (rpcport, Dict) ->
        Port = application:get_env(tpnode, rpcport, 43280),
        maps:put(rpcport, Port, Dict);
      (tpicport, Dict) ->
        TpicConfig = application:get_env(tpnode, tpic, #{}),
        TpicPort =
          case maps:get(port, TpicConfig, unknown) of
            unknown ->
              lager:error("Undefined tpic port. Can't read tpic configuration"),
              throw(unknown_tpic);
            ValidPort ->
              ValidPort
          end,
        maps:put(tpicport, TpicPort, Dict)
    end,
  lists:foldl(Worker, #{}, DictKeys).


% --------------------------------------------------------

add_hostname(Address, Hostname) ->
  case Hostname of
    unknown ->
      Address;
    _ ->
      maps:put(hostname, Hostname, Address)
  end.
  

% --------------------------------------------------------

lookup(Name) ->
    lookup(Name, blockchain:chain()).


lookup(Name, Chain) ->
    Discovery = whereis(discovery),
    try
        gen_server:call(Discovery, {lookup, Name, Chain})
    catch
        exit:{timeout, Details} = Reason ->
            StackTrace = erlang:process_info(Discovery, current_stacktrace),
            ProcInfo = erlang:process_info(Discovery),
            QLen = proplists:get_value(message_queue_len, ProcInfo),
            lager:error("got lookup timeout: ~p", [Details]),
            lager:error("message_queue_len: ~p", [QLen]),
            lager:error("process info: ~p", [ProcInfo]),
            lager:error("stack trace: ~p", [StackTrace]),
            erlang:raise(exit, Reason, erlang:get_stacktrace())
    end.

% --------------------------------------------------------




% check if local service is exists
query_local(Name, #{names:=Names} = _Dict, State) ->
  Hostname = get_config(hostname, unknown, State),
  MacroDict = get_config(macro_dict, #{}, State),
  NodeId = nodekey:node_id(),
  TranslateAddress =
    fun(Address) when is_map(Address) ->
      Translated =
        add_hostname(substitute_macro(Address, MacroDict), Hostname),
      maps:put(nodeid, NodeId, Translated)
    end,
  LocalNames = get_local_names(Names),
  case lists:member(Name, LocalNames) of
    false -> [];
    true ->
      LocalAddresses = get_config(addresses, [], State),
      Worker =
        fun
          (#{proto:=Proto} = Addr, Result) when is_map(Addr) ->
            try
              case is_right_proto(Name, Proto) of
                true ->
                  Result ++ [TranslateAddress(Addr)];
                _ ->
                  Result
              end
            catch
              pass ->
                lager:debug("skip address ~p", [Addr])
            end;
          
          (_Invalid, Result) ->
            lager:error("Invalid address: ~p", [_Invalid]),
            Result
        end,
      lists:foldl(Worker, [], LocalAddresses)
  end.

% --------------------------------------------------------

% find addresses of remote service
query_remote(Name, Dict) ->
    query_remote(Name, Dict, blockchain:chain()).


query_remote(Name0, Dict, Chain) when is_integer(Chain)->
    Name = add_chain_to_name(Name0, Chain),
    Nodes = maps:get(Name, Dict, #{}),
    Announces = maps:values(Nodes),
    lists:map(
        fun(#{address:=Address, nodeid:=NodeId})
                when is_map(Address) andalso is_binary(NodeId) ->
                    maps:put(nodeid, NodeId, Address);
            (#{address:=Address}) ->
                Address
        end, Announces
    );

query_remote(Name, _Dict, Chain) ->
    lager:info("unmached clouse ~p ~p", [Name, Chain]),
    [].

% --------------------------------------------------------

query(Name0, Chain, State) ->
    Name = convert_to_binary(Name0),
    LocalChain = blockchain:chain(),
    #{local_services := LocalDict, remote_services := RemoteDict} = State,
    Local = case Chain of
        LocalChain ->
            query_local(Name, LocalDict, State);
        _ ->
            []
    end,
    Remote = query_remote(Name, RemoteDict, Chain),
%%    lager:debug("query ~p local: ~p", [Name, Local]),
%%    lager:debug("query ~p remote: ~p", [Name, Remote]),
    lists:merge(Local, Remote).


% --------------------------------------------------------

query(Pred, _State) when is_function(Pred) ->
    lager:error("Not inmplemented"),
    not_implemented;

% find service by name
query(Name, State) ->
    query(Name, blockchain:chain(), State).

% --------------------------------------------------------

address2key(#{address:=Ip, port:=Port, proto:=Proto})
  when is_integer(Port) andalso is_atom(Proto) ->
    {Ip, Port, Proto};

address2key(#{hostname:=Host, port:=Port, proto:=Proto})
  when is_integer(Port) andalso is_atom(Proto) ->
    {Host, Port, Proto};

address2key(Invalid) ->
    lager:info("invalid address: ~p", [Invalid]),
    throw("can't parse address").



% --------------------------------------------------------

% foreign service announce validation
validate_announce(
          #{
              name := _Name,
              address := _Address,
              nodeid := _NodeId,
              scopes := _Scopes,
              created := Created,
              ttl := Ttl
          } = _Announce,
          State) ->
    MaxTtl = max(get_config(xchain_ttl, 1800, State), 30),
    TtlToCheck = min(Ttl, MaxTtl),
    Now = os:system_time(seconds),
    MaxExpireTime = Now + TtlToCheck,
    ValidUntil = Created + TtlToCheck,
    if
        ValidUntil > MaxExpireTime ->
            throw("too big ttl");
        ValidUntil < Now ->
            lager:debug(
                "got expired announce. now: ~p, valid until: ~p, ttl: ~p, announce: ~p",
                [ Now, ValidUntil, TtlToCheck, _Announce ]
            ),
            throw("announce expired");
        true ->
            ok
    end;

validate_announce(Announce, _State) ->
    lager:debug("invalid announce ~p", [Announce]),
    throw("can't validate announce").


% --------------------------------------------------------

add_chain_to_name(Name, Chain) when is_integer(Chain) andalso is_binary(Name) ->
    <<Name/binary, ":", (integer_to_binary(Chain))/binary>>;

add_chain_to_name(Name, Chain) ->
    lager:info("Can't add chain to announce name: ~p ~p", [Name, Chain]),
    throw("Can't add chain to announce name").


% --------------------------------------------------------

parse_and_process_announce(MaxTtl, AnnounceBin, #{remote_services:=Dict} = State) ->
    {ok, Announce} = unpack(AnnounceBin),
    lager:debug("Announce details: ~p", [Announce]),
    validate_announce(Announce, State),
    case is_local_service(Announce) of
        true ->
            lager:debug("skip copy of local service: ~p", [Announce]),
            throw(skip);
        _ -> ok
    end,

    XChainThrottle = get_config(xchain_throttle, 600, State),
    Settings = {Dict, MaxTtl, XChainThrottle, AnnounceBin},
    process_announce(Announce, Settings).

% --------------------------------------------------------


% parse foreign service announce and add it to services database
process_announce(
  #{name := Name0, address := Address, chain := Chain} = Announce0, Settings) ->
    {Dict, MaxTtl, XChainThrottle, AnnounceBin} = Settings,
    try
        Key = address2key(Address),
        Name = add_chain_to_name(Name0, Chain),
        Nodes = maps:get(Name, Dict, #{}),
        Announce = add_valid_until(Announce0, MaxTtl),
        PrevAnnounce = maps:get(Key, Nodes, #{created => 0, ttl=> 0, sent_xchain => 0}),
        SentXchain = relay_announce(PrevAnnounce, Announce, AnnounceBin, XChainThrottle),
        Announce1 = Announce#{sent_xchain => SentXchain},
        UpdatedNodes = maps:put(Key, Announce1, Nodes),
        maps:put(Name, UpdatedNodes, Dict)
    catch
        Err:Reason ->
            lager:error("skip announce because of error: ~p ~p ~p", [Err, Reason, Announce0]),
            Dict
    end;

process_announce(Announce, Settings) ->
    {Dict, _MaxTtl, _XChainThrottle, _AnnounceBin} = Settings,
    lager:error("invalid announce: ~p", [Announce]),
    Dict.

% --------------------------------------------------------


add_valid_until(#{valid_until:=_ValidUntil}=Announce, _MaxTtl) ->
    Announce;

add_valid_until(#{created:=Created, ttl:=Ttl}=Announce, MaxTtl)
    when is_integer(Created) andalso is_integer(Ttl) ->
    NewTtl = max(Ttl, MaxTtl),
    ValidUntil = Created + NewTtl,
    Announce#{valid_until => ValidUntil};

add_valid_until(Announce, _MaxTtl) ->
    Announce#{valid_until => 0}.


% --------------------------------------------------------

% relay announce to active xchain connections
relay_announce(
        #{created:=CreatedPrev, sent_xchain:=SentXChainPrev} = PrevAnnounce,
        #{created:=CreatedNew, nodeid:=NodeId} = NewAnnounce,
        AnnounceBin,
        XChainThrottle
    )
    when is_binary(AnnounceBin)
    andalso size(AnnounceBin) > 0 ->

    MyNodeId = nodekey:node_id(),
    if
        NodeId =:= MyNodeId ->
            lager:debug("skip relaying of self announce: ~p", [NewAnnounce]),
            SentXChainPrev;
        CreatedPrev < CreatedNew ->
            lager:debug(
              "relay new announce. old: ~p, new: ~p, new announce body: ~p",
              [CreatedPrev, CreatedNew, NewAnnounce]
            ),
            send_service_announce(NewAnnounce, AnnounceBin),
            xchain_relay_announce(SentXChainPrev, XChainThrottle, NewAnnounce, AnnounceBin);
        CreatedPrev =:= CreatedNew ->
%%            lager:debug("skip relaying of announce (equal created): ~p", [NewAnnounce]),
            SentXChainPrev;
        true ->
            lager:debug("skip relaying of announce: new ~p, prev ~p", [NewAnnounce, PrevAnnounce]),
            SentXChainPrev
    end;

relay_announce(_PrevAnnounce, NewAnnounce, _AnnounceBin, _XChainThrottle) ->
    lager:debug("skip relaying of invalid announce ~p", [NewAnnounce]),
    0.

% --------------------------------------------------------
-spec xchain_relay_announce(
  SentXchain :: non_neg_integer(),
  Throttle :: non_neg_integer(),
  Announce :: #{'chain' => non_neg_integer()} | map(),
  AnnounceBin :: binary()) -> non_neg_integer().


xchain_relay_announce(SentXchain, Throttle, #{chain:=Chain}=Announce, AnnounceBin) ->
    Now = os:system_time(seconds),
    MyChain = blockchain:chain(),
    if
        % relay our chain announces which isn't throttled
        MyChain =:= Chain andalso SentXchain + Throttle < Now ->
            gen_server:cast(xchain_client, {discovery, Announce, AnnounceBin}),
            Now;
        true ->
            lager:debug("skipping xchain relay"),
            SentXchain
    end;

xchain_relay_announce(SentXchain, _Throttle, Announce, _AnnounceBin) ->
    lager:error("invalid announce can't be xchain relayed: ~p", [Announce]),
    SentXchain.


% --------------------------------------------------------
send_service_announce(local, AnnounceBin) ->
%%    lager:debug("send tpic announce ~p", [AnnounceBin]),
    tpic:cast(tpic, service, {<<"discovery">>, AnnounceBin});

send_service_announce(Announce, AnnounceBin) ->
%%    lager:debug("send tpic announce ~p", [AnnounceBin]),
    gen_server:cast(xchain_client, {discovery, Announce, AnnounceBin}),
    tpic:cast(tpic, service, {<<"discovery">>, AnnounceBin}).


% --------------------------------------------------------

add_sign_to_bin(Sign, Data) ->
    <<254, (size(Sign)):8/integer, Sign/binary, Data/binary>>.


% --------------------------------------------------------

split_bin_to_sign_and_data(<<254, SignLen:8/integer, Rest/binary>>) ->
    <<Sign:SignLen/binary, Data/binary>>=Rest,
    {Sign, Data};

split_bin_to_sign_and_data(Bin) ->
    lager:info("invalid sign format: ~p", [Bin]),
    {<<>>, <<>>}.

% --------------------------------------------------------

pack(Message) ->
    PrivKey = nodekey:get_priv(),
    Packed = msgpack:pack(Message),
    Hash = crypto:hash(sha256, Packed),
    Sign = bsig:signhash(
        Hash,
        [
            {timestamp, os:system_time(millisecond)}
        ],
        PrivKey
    ),
    add_sign_to_bin(Sign, Packed).

% --------------------------------------------------------


unpack(<<254, _Rest/binary>> = Packed) ->
    {Sign, Bin} = split_bin_to_sign_and_data(Packed),
    Hash = crypto:hash(sha256, Bin),
    case bsig:checksig(Hash, [Sign]) of
        { [ #{ signature:= _FirstSign } | _] , _InvalidSings} ->
            lager:notice("Check signature here");
        _X ->
            lager:debug("checksig result ~p", [_X]),
            throw("invalid signature")
    end,
    case msgpack:unpack(Bin, [{known_atoms, ?KNOWN_ATOMS}]) of
        {ok, Message} ->
            {ok, Message};
        _ -> throw("msgpack unpack error")
    end;

unpack(Packed) ->
    lager:info("Invalid packed data ~p", [Packed]),
    throw("invalid packed data").

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


% --------------------------------------------------------

convert_to_binary(Data) when is_binary(Data) ->
    Data;

convert_to_binary(Data) when is_list(Data) ->
    list_to_binary(Data);

convert_to_binary(Data) when is_atom(Data) ->
    atom_to_binary(Data, utf8);

convert_to_binary(Data) when is_integer(Data) ->
    integer_to_binary(Data, 10).



% --------------------------------------------------------

-ifdef(TEST).
convert_to_binary_test() ->
    ?assertEqual(<<"wazzzup">>, convert_to_binary(<<"wazzzup">>)),
    ?assertEqual(<<"wazzzup">>, convert_to_binary(wazzzup)),
    ?assertEqual(<<"wazzzup">>, convert_to_binary("wazzzup")),
    ?assertEqual(<<"42">>, convert_to_binary(42)).


pack_unpack_test() ->
    Original = <<"Answer to the Ultimate Question of Life, the Universe, and Everything">>,
    meck:new(nodekey),
    meck:expect(nodekey, get_priv, fun() -> hex:parse("1E919CD3897241D78B420255F66426CC9A31163653AD7685DBBF0C34FFFFFFFF") end),
    Packed = pack(Original),
    Unpacked = unpack(Packed),
    meck:unload(nodekey),
    ?assertEqual({ok, Original}, Unpacked).
-endif.


% --------------------------------------------------------

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
        created => os:system_time(seconds)
    },
%%  gen_server:cast(discovery, {got_announce, Announce}),
    MaxTtl = 120,
    XChainThrottle = 600,
    D1 = process_announce(Announce, {#{}, MaxTtl, XChainThrottle, <<>>}),
    D2 = process_announce(Announce#{name => <<"looking_glass2">>}, {D1, MaxTtl, XChainThrottle, <<>>}),
    D3 = process_announce(Announce#{
        name => <<"looking_glass2">>,
        address => #{address => <<"127.0.0.2">>, port => 1234, proto => tpic}
    }, {D2, MaxTtl, XChainThrottle, <<>>}),
    D4 = process_announce(Announce#{name => <<"looking_glass2">>, valid_until => 20}, {D3, MaxTtl, XChainThrottle, <<>>}),
    query_remote(<<"looking_glass2">>, D4).

test2() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        created => os:system_time(seconds),
        ttl => 100500

    },
    gen_server:cast(discovery, {got_announce, Announce}),
    gen_server:call(discovery, {state}).

test3() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        created => os:system_time(seconds),
        ttl => 2
    },
    gen_server:cast(discovery, {got_announce, Announce}),
    erlang:send(discovery, cleanup),
    gen_server:call(discovery, {state}).

test4() ->
    Announce = #{
        name => <<"looking_glass">>,
        address => #{address => <<"127.0.0.1">>, port => 1234, proto => tpic},
        created => os:system_time(seconds),
        ttl => 100
    },
    Packed = pack(Announce),
    io:fwrite("packed: ~n~p~n", [ Packed ]),
    {ok, Message} = unpack(Packed),
    io:fwrite("message: ~n~p~n", [ Message ]).
