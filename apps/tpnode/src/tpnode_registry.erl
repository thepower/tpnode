-module(tpnode_registry).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, prepare/1, lookup/1, port/3]).

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

lookup(Address) ->
    gen_server:call(?MODULE, {lookup, Address}).

prepare(Addresses) ->
    gen_server:cast(?MODULE, {prepare, Addresses}).

port(Address, Chain, Pubkey) ->
    gen_server:call(?MODULE, {port, Address, Chain, Pubkey}).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    {ok, Pid} = cowdb:open("addr.db"),
    cowdb:put(Pid, {extra, last_run}, os:system_time(seconds)),
    {ok, #{
       args => Args,
       db => Pid
      }
    }.

handle_call({port, Address, Chain, Pubkey}, _From, #{db:=DB}=State) ->
    Res=cowdb:put(DB, Address,
                  #{ c=>Chain,
                     p=>Pubkey
                   }
                 ),
    {reply, Res, State};

handle_call({lookup, Address}, _From, #{db:=DB}=State) ->
    Res=cowdb:get(DB, Address),
    {reply, Res, State};

handle_call(_Request, _From, State) ->
    lager:info("Bad call ~p", [_Request]),
    {reply, bad_request, State}.

handle_cast({prepare, Addresses}, #{db:=DB}=State) when is_list(Addresses) ->
    Res=cowdb:mget(DB, Addresses),
    lager:info("Prepare ~p", [Res]),
    {noreply, State};

handle_cast(_Msg, State) ->
    lager:info("Bad cast ~p", [_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    lager:info("Bad info  ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

