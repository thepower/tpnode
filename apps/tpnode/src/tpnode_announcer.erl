% -*- mode: erlang -*-
% vi: set ft=erlang :

-module(tpnode_announcer).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

-export([test/0, test1/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    PeersCheckTimeout = maps:get(peers_check_timeout, Args, 10),
    register_node(),
    State = #{
        peers_check_timeout => PeersCheckTimeout,
        peers_check_timer => erlang:send_after(PeersCheckTimeout * 1000, self(), renew_peers)
    },
    {ok, State}.

handle_call(get_peers, _From, State) ->
    {reply, get_peers(), State};

handle_call(_Request, _From, State) ->
    lager:notice("Unknown call ~p", [_Request]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:notice("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info(renew_peers, #{peers_check_timer:=PeersCheckTimer} = State) ->
    catch erlang:cancel_timer(PeersCheckTimer),
    #{peers_check_timeout := PeersCheckTimeout} = State,
    renew_peers(),
    {noreply, State#{
        peers_check_timer => erlang:send_after(PeersCheckTimeout * 1000, self(), renew_peers)
    }};

handle_info(_Info, State) ->
    lager:notice("Unknown info ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


parse_address(#{address:=Ip, port:=Port, proto:=Proto} = _Address)
    when is_integer(Port) and is_atom(Proto) ->
    {Ip, Port, Proto};

parse_address(_Address) ->
    lager:error("invalid address: ~p", [_Address]),
    error.


get_peers() ->
    AllRemoteNodes = gen_server:call(discovery, {lookup_remote, <<"tpicpeer">>}),
    AddressParser =
        fun(Address, Accepted) ->
            Parsed = parse_address(Address),
            case Parsed of
                {Ip, Port, tpic} ->
                    [{Ip, Port} | Accepted];
                _ ->
                    Accepted
            end
        end,
    lists:foldl(AddressParser, [], AllRemoteNodes).

renew_peers() ->
    renew_peers(get_peers()).

renew_peers([]) ->
    ok;

renew_peers(Peers) when is_list(Peers) ->
    lager:debug("add peers to tpic ~p", [Peers]),
    tpic2_cmgr:add_peers(Peers).

register_node() ->
    gen_server:call(discovery, {register, <<"tpicpeer">>, self(), #{}}).


%% ---------------

test() ->
    register_node(),
    ok.

test1() ->
    get_peers().
