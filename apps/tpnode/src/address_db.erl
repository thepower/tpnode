-module(address_db).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-ifndef(TEST).
-define(TEST,1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
         start_link/1,
         lookup/1,
         put/1,check/1,get/1,tpic/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Params) ->
    gen_server:start_link({local,
                           proplists:get_value(name,Params,?SERVER)},
                          ?MODULE, Params, []).

lookup(Address) ->
    case naddress:check(Address) of
        {true, #{address:=_,
                 block:=Block,
                 group:=_,
                 type:=public
                }} -> 
            {ok, Block};
        _ ->
            error
    end.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

put(KVS) when is_list(KVS) ->
    gen_server:call(?SERVER, {put, KVS}).

check(KVS) when is_list(KVS) ->
    gen_server:call(?SERVER, {check, KVS}).

get(KS) when is_list(KS) ->
    gen_server:call(?SERVER, {get, KS}).

tpic(From, Payload) when is_binary(Payload) ->
    case msgpack:unpack(Payload) of
        {ok, Obj} when is_map(Obj) ->
            tpic(From, Obj);
        Any ->
            tpic:cast(tpic, From, <<"error">>),
            lager:info("Bad TPIC received:: ~p",[Any]),
            error
    end;

tpic(From, _Payload) ->
    tpic:cast(tpic, From, <<"pong ADB">>).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    case lists:member(test,Args) of
        true ->
            {ok, #{
               args => Args,
               mt => gb_merkle_trees:balance(
                       gb_merkle_trees:from_list([{<<>>,<<>>}])
                      ),
               db => test
              }
            };
        false ->
            Pid = open_db(#{args => Args}),
            {ok, #{
               args => Args,
               mt => load(Pid),
               db => Pid
              }
            }
    end.

handle_call(dump, _From, #{db:=DB}=State) ->
    GB=rocksdb:fold(DB,
                       fun({K,V}, Acc) ->
                                [{K,binary_to_term(V)}|Acc]
                       end,
                       [],
                       []
                      ),
    {reply, GB, State};

handle_call(snapshot, _From, #{db:=DB}=State) ->
    {ok,Snap}=rocksdb:snapshot(DB),
    {reply, {DB, Snap}, State};

handle_call('_flush', _From, State) ->
    drop_db(State),
    NewDB=open_db(State),
    {reply, flushed, State#{
                       db=>NewDB,
                       mt=>load(NewDB)
                      }};

handle_call({try_restore, Dump, ExpectHash}, _From, State) ->
    throw('fixme'),
    lager:info("Restore ~p",[Dump]),
    MT1=gb_merkle_trees:balance(
          lists:foldl(fun applykv/2,
                      gb_merkle_trees:from_list([{<<>>,<<>>}]),
                      Dump)
         ),
    RH=gb_merkle_trees:root_hash(MT1),
    case ExpectHash=/=RH of
        true ->
            {reply, {error, hash_mismatch, RH}, State};
        false ->
            drop_db(State),
            NewDB=open_db(State),
            cowdb:transact(NewDB,
                           lists:map(
                             fun({K,V}) ->
                                     {add, K,V}
                             end, Dump)
                          ),
            {reply, ok, State#{
                            db=>NewDB,
                            mt=>MT1}
            }
    end;


handle_call({Action, KVS0}, _From, #{db:=DB, mt:=MT}=State) when
      Action==put orelse Action==check ->
    {KVS,_S1}=lists:foldl(
          fun({Addr,Patch},{AccKV,AccS}) ->
                  {NP,Acc1}=apply_patch(Addr,Patch,AccS),
                  {[{Addr,NP}|AccKV], Acc1}
          end, {[], State}, KVS0),
    %lager:info("KVS0 ~p",[KVS0]),
    %lager:info("KVS1 ~p",[KVS]),

    MT1=gb_merkle_trees:balance(
          lists:foldl(fun applykv/2, MT, KVS)
         ),
    Res={ok, gb_merkle_trees:root_hash(MT1)},
    {reply, Res,
     case Action of
         check -> State;
         put when KVS=/=[] ->
             {ok, Batch} = rocksdb:batch(),
             TR=lists:foldl(
                  fun({K,V},Total) ->
                          ok=rocksdb:batch_put(Batch, K, term_to_binary(V)),
                          Total+1
                  end,
                  0, KVS),
             ?assertEqual(TR, rocksdb:batch_count(Batch)),
             lager:debug("Ledger apply trans ~p",[TR]),
             ok = rocksdb:write_batch(DB, Batch, []),
             ok = rocksdb:close_batch(Batch),
             State#{mt=>MT1};
         _ -> State
     end};

handle_call({get, KS}, _From, #{db:=DB}=State) ->
    R=lists:foldl(
        fun(Key, Acc) ->
                case rocksdb:get(DB, Key, []) of
                    {ok, Value} ->
                        maps:put(Key,erlang:binary_to_term(Value),Acc);
                    not_found ->
                        Acc;
                    Error ->
                        lager:error("Can't fetch ~p: ~p",[Key,Error]),
                        Acc
                end
        end, #{}, KS),
    {reply, R, State};

handle_call(_Request, _From, State) ->
    lager:info("Bad call ~p",[_Request]),
    {reply, bad_request, State}.

handle_cast({prepare, Addresses}, #{db:=_DB}=State) when is_list(Addresses) ->
    %Res=cowdb:mget(DB,Addresses),
    %lager:info("Prepare ~p",[Res]),
    {noreply, State};

handle_cast(drop_terminate, State) ->
    drop_db(State),
    lager:info("Terminate me"),
    {stop, normal, State};

handle_cast(terminate, State) ->
    close_db(State),
    lager:error("Terminate me"),
    {stop, normal, State};

handle_cast(_Msg, State) ->
    lager:info("Bad cast ~p",[_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    lager:info("Bad info  ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

format_status(_Opt, [_PDict,State]) -> 
    State#{
      db=>dbhandler
     }.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

applykv({K0,V},Acc) ->
    K=if is_binary(K0) -> K0;
         is_integer(K0) -> binary:encode_unsigned(K0)
      end,
    gb_merkle_trees:enter(K,crypto:hash(sha256,bal:pack(V)),Acc).

load(DB) ->
    GB=rocksdb:fold(DB,
               fun({K,V}, Acc) ->
                       applykv({K,binary_to_term(V)},Acc)
               end,
               gb_merkle_trees:from_list([{<<>>,<<>>}]),
               []
              ),
    gb_merkle_trees:balance(GB).

apply_patch(_Address,Patch, #{db:=test}=State) ->
    NewVal=Patch,
    {NewVal,State};

apply_patch(Address,Patch, #{db:=DB}=State) ->
    NewVal=case rocksdb:get(DB, Address, []) of
               not_found ->
                   Patch;
               {ok, Wallet} ->
                   Element=erlang:binary_to_term(Wallet),
                   P1=maps:merge(
                        Element,
                        maps:with([seq,t],Patch)
                       ),
                   Bals=maps:merge(
                          maps:get(amount, Element,#{}),
                          maps:get(amount, Patch,#{})
                         ),
                   P1#{amount=>Bals}
           end,
    {NewVal,State}.

close_db(#{args:=Args}) ->
    DBPath=proplists:get_value(filename,
                               Args,
                               ("db/ledger_"++atom_to_list(node()))
                              ),
    ok=gen_server:call(rdb_dispatcher, {close, DBPath}).

drop_db(#{args:=Args}) ->
    DBPath=proplists:get_value(filename,
                               Args,
                               ("db/ledger_"++atom_to_list(node()))
                              ),
    ok=gen_server:call(rdb_dispatcher, {close, DBPath}),
    {ok,Files}=file:list_dir_all(DBPath),
    lists:foreach(
      fun(Filename) ->
              file:delete(DBPath++"/"++Filename)
      end, Files),
    file:del_dir(DBPath).

open_db(#{args:=Args}) ->
    filelib:ensure_dir("db/"),
    DBPath=proplists:get_value(filename,
                                 Args,
                                 ("db/ledger_"++atom_to_list(node()))
                                ),
    {ok, Pid} = gen_server:call(rdb_dispatcher,
                                {open, DBPath, [{create_if_missing, true}]}),
    Pid.


-ifdef(TEST).
ledger_test() ->
    NeedStop=case whereis(rdb_dispatcher) of
                 P when is_pid(P) -> false;
                 undefined -> 
                     {ok,P}=rdb_dispatcher:start_link(),
                     P
             end,
    Name=test_ledger,
    {ok,Pid}=ledger:start_link(
               [{filename, "db/ledger_test"},
                {name, Name}
               ]
              ),
    gen_server:call(Pid, '_flush'),
    {ok,R1}=gen_server:call(Pid, {check, []}),
    gen_server:call(Pid,
                    {put, [
                           {<<"abc">>,#{amount=> #{<<"xxx">> => 123}}},
                           {<<"bcd">>,#{amount=> #{<<"yyy">> => 321}}}
                          ]}),
    {ok,R2}=gen_server:call(Pid, {check, []}),
    gen_server:call(Pid,
                    {put, [
                           {<<"abc">>,#{amount=> #{<<"xxx">> => 234}}},
                           {<<"def">>,#{amount=> #{<<"yyy">> => 210}}}
                          ]}),
    {ok,R3}=gen_server:call(Pid, {check, []}),
    Expect=#{<<"def">>=>#{amount=> #{<<"yyy">> => 210}}},
    Expect=gen_server:call(Pid, {get, [<<"def">>]}),
    %gen_server:cast(Pid, terminate),
    gen_server:cast(Pid, drop_terminate),
    if NeedStop==false -> ok;
       true ->
           gen_server:stop(NeedStop, normal, 3000)
    end,
    {R1,R2,R3}.

-endif.

