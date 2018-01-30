-module(ledger).
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
         put/1,check/1,get/1,dump/0,restore/2,tpic/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Params) ->
    gen_server:start_link({local, 
                           proplists:get_value(name,Params,?SERVER)}, 
                          ?MODULE, Params, []).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

put(KVS) when is_list(KVS) ->
    gen_server:call(?SERVER, {put, KVS}).

check(KVS) when is_list(KVS) ->
    gen_server:call(?SERVER, {check, KVS}).

get(KS) when is_list(KS) ->
    gen_server:call(?SERVER, {get, KS}).

dump() ->
    msgpack:pack(
      #{ <<"type">> => <<"ledgerdumpv1">>,
         <<"dump">> =>
         lists:map(
           fun({Account, Bal}) ->
                   [Account, bal:pack(Bal)]
           end,
           gen_server:call(?SERVER, dump, 60000))
       }
     ).

restore(Bin,ExpectHash) -> 
    {ok, #{ <<"type">> := <<"ledgerdumpv1">>,
            <<"dump">> := Payload}} = msgpack:unpack(Bin),
    ToRestore=lists:map(
      fun([Account, BBal]) ->
              {Account, bal:unpack(BBal)}
      end, Payload),
    gen_server:call(?SERVER, {try_restore, ToRestore, ExpectHash}, 60000).

tpic(From, Payload) when is_binary(Payload) ->
    lager:info("Untpic ~p",[Payload]),
    case msgpack:unpack(Payload) of
        {ok, Obj} when is_map(Obj) ->
            tpic(From, Obj);
        Any ->
            tpic:cast(tpic, From, <<"error">>),
            lager:info("Bad TPIC received:: ~p",[Any]),
            error
    end;

tpic(From, _Payload) ->
    tpic:cast(tpic, From, <<"pong !!!">>).


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

handle_call(snaptest, _From, #{db:=DB}=State) ->
    {ok,DBS}=cowdb:get_snapshot(DB, 1),
    lager:info("Info ~p",[cowdb:database_info(DB)]),
    lager:info("Info ~p",[cowdb:database_info(DBS)]),
    timer:sleep(1000),
    cowdb:compact(DB),
    timer:sleep(1000),
    lager:info("Info ~p",[cowdb:database_info(DB)]),
    lager:info("Info ~p",[cowdb:database_info(DBS)]),
    Show=fun(DBh) ->
                 FR=cowdb:fold(DBh,
                               fun(KV, Acc) ->
                                       lager:info("K ~p",[KV]),
                                       {ok, Acc}
                               end,
                               0
                              ),
                 lager:info("FR ~p",[FR])
         end,
    Show(DB),

    Show(DBS),
    {reply, ok, State};

handle_call(compact, _From, #{db:=DB}=State) ->
    {reply, cowdb:compact(DB), State};

handle_call(info, _From, #{db:=DB}=State) ->
    {reply, cowdb:database_info(DB), State};

handle_call(dump, _From, #{db:=DB}=State) -> 
    {ok,GB}=cowdb:fold(DB, 
                       fun(KV, Acc) -> 
                               {ok,
                                [KV|Acc]
                               }
                       end, 
                       []
                      ),
    {reply, GB, State};


handle_call('_flush', _From, State) ->
    drop_db(State),
    NewDB=open_db(State),
    {reply, flushed, State#{
                       db=>NewDB,
                       mt=>load(NewDB)
                      }};

handle_call({try_restore, Dump, ExpectHash}, _From, State) ->
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
    lager:info("KVS0 ~p",[KVS0]),
    lager:info("KVS1 ~p",[KVS]),

    MT1=gb_merkle_trees:balance(
          lists:foldl(fun applykv/2, MT, KVS)
         ),
    Res={ok, gb_merkle_trees:root_hash(MT1)},
    {reply, Res,
     case Action of
         check -> State;
         put when KVS=/=[] -> 
             TR=cowdb:transact(DB,
                            lists:map(
                              fun({K,V}) ->
                                      {add, K,V}
                              end, KVS)
                           ),
             lager:info("Trans ~p",[TR]),
             State#{mt=>MT1};
         _ -> State
     end};

handle_call({get, KS}, _From, #{db:=DB}=State) ->
    R=lists:foldl(
        fun(not_found,Acc) -> Acc;
           ({ok,{K,V}}, Acc) ->
                maps:put(K,V,Acc)
        end, #{}, cowdb:mget(DB, KS)),
    {reply, R, State};

handle_call(_Request, _From, State) ->
    lager:info("Bad call ~p",[_Request]),
    {reply, bad_request, State}.

handle_cast({prepare, Addresses}, #{db:=DB}=State) when is_list(Addresses) ->
    Res=cowdb:mget(DB,Addresses),
    lager:info("Prepare ~p",[Res]),
    {noreply, State};

handle_cast(drop_terminate, State) ->
    drop_db(State),
    lager:info("Terminate me"),
    {stop, normal, State};

handle_cast(_Msg, State) ->
    lager:info("Bad cast ~p",[_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    lager:info("Bad info  ~p",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

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
    {ok,GB}=cowdb:fold(DB, 
               fun(KV, Acc) -> 
                       {ok, applykv(KV,Acc)} 
               end, 
               gb_merkle_trees:from_list([{<<>>,<<>>}])
              ),
    gb_merkle_trees:balance(GB).

apply_patch(_Address,Patch, #{db:=test}=State) ->
    NewVal=Patch,
    {NewVal,State};

apply_patch(Address,Patch, #{db:=DB}=State) ->
    NewVal=case cowdb:get(DB, Address) of
               not_found ->
                   Patch;
               {ok, {Address,Element}} ->
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

drop_db(#{db:=DB,args:=Args}) ->
    cowdb:close(DB),
    Filename=proplists:get_value(filename,
                                 Args,
                                 ("ledger_"++atom_to_list(node())++".db")
                                ),
    file:delete(Filename).

open_db(#{args:=Args}) ->
    Filename=proplists:get_value(filename,
                                 Args,
                                 ("ledger_"++atom_to_list(node())++".db")
                                ),
    {ok, Pid} = cowdb:open(Filename),
    Pid.



-ifdef(TEST).
ledger_test() ->
    Name=test_ledger,
    {ok,Pid}=ledger:start_link(
               [{filename, "test.db"},
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
    gen_server:call(Pid, snaptest),
    gen_server:cast(Pid, drop_terminate),
    {R1,R2,R3}.

-endif.

