-module(txstatus).
-behaviour(gen_server).
-define(SERVER, ?MODULE).
-define(CLEANUP, 30000).

-ifndef(TEST).
-define(TEST, 1).
-endif.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,get/1,get_json/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

get(TxID) ->
  gen_server:call(?MODULE, {get, TxID}).

get_json(TxID) ->
  R=gen_server:call(?MODULE, {get, TxID}),
  if R==undefined ->
       null;
     true ->
       jsonfy(R)
  end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok, #{ q=>hashqueue:new(),
          timer=>erlang:send_after(?CLEANUP, self(), timer)
        }
  }.

handle_call({get, TxID}, _From, #{q:=Q}=State) ->
  R=hashqueue:get(TxID, Q),
  {reply, R, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_call, State}.

handle_cast({done, Result, Txs}, #{q:=Q}=State) when is_list(Txs)->
  %{done,false,[{<<"1524179A464B33A2-3NBx74EdmT2PyYexBSrg7xcht998-03A2">>,{contract_error, [error,{badmatch,#{<<"fee">> => 30000000,<<"feecur">> => <<"FTT">>,<<"message">> => <<"To AA100000001677722185 with love">>}}]}}]}
  %{done,true,[<<"AA1000000016777220390000000000000009xQzCH+qGbhzKlrFxoZOLWN5DhVE=">>]}
  Timeout=erlang:system_time(seconds)+3600,
  Q1=lists:foldl(
       fun({TxID,Res},QAcc) ->
           hashqueue:add(TxID, Timeout, {Result, Res}, QAcc);
          (TxID,QAcc) ->
           hashqueue:add(TxID, Timeout, 
                         {Result, 
                         if Result -> 
                              ok;
                            true -> error 
                         end}, QAcc)
       end, Q, Txs),
  {noreply, 
   State#{q=>Q1}
  };


handle_cast(_Msg, State) ->
  lager:notice("Unhandler cast ~p",[_Msg]),
  {noreply, State}.

handle_info(timer, #{timer:=Tmr}=State) ->
  catch erlang:cancel_timer(Tmr),
  handle_info({cleanup, 
               erlang:system_time(seconds)}, 
              State#{
                timer=>erlang:send_after(?CLEANUP, self(), timer)
               });

handle_info({cleanup, Time}, #{q:=Queue}=State) ->
  Q1=cleanup(Queue,Time),
  {noreply, State#{q=>Q1}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

jsonfy({false,{error,{contract_error,[Ec,Ee]}}}) ->
  #{ error=><<"smartcontract">>,
     type=>Ec,
     res=>iolist_to_binary(io_lib:format("~p",[Ee]))};

jsonfy({true,#{address:=Addr}}) ->
  #{ok=>true,
    res=>naddress:encode(Addr)
   };

jsonfy({true,Status}) ->
  #{ok=>true,
    res=> iolist_to_binary(io_lib:format("~p",[Status]))
   };

jsonfy({false,Status}) ->
  #{error=>true,
    res=>iolist_to_binary(io_lib:format("~p",[Status]))
   }.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

cleanup(Queue, Now) ->
  case hashqueue:head(Queue) of
    empty ->
      Queue;
    I when is_integer(I) andalso I>=Now ->
      Queue;
    I when is_integer(I) ->
      case hashqueue:pop(Queue) of
        {Queue1, empty} ->
          Queue1;
        {Queue1, _} ->
          cleanup(Queue1, Now)
      end
  end.



-ifdef(TEST).
txstatus_test() ->
    {ok, Pid}=?MODULE:start_link(txstatus_test),
    gen_server:cast(Pid,{done, true, [<<"1234">>,<<"1235">>]}),
    gen_server:cast(Pid,{done, false, [{<<"1334">>,"err1"},
                                       {<<"1335">>,"err2"}
                                      ]}),
    timer:sleep(2000),
    gen_server:cast(Pid,{done, false, [<<"1236">>,<<"1237">>]}),
    S1=[
        ?assertMatch(ok, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch(ok, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch("err1", gen_server:call(Pid,{get, <<"1334">>})),
        ?assertMatch("err2", gen_server:call(Pid,{get, <<"1335">>})),
        ?assertMatch(error, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch(error, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    Pid ! {cleanup, erlang:system_time(seconds)+119},
    S2=[
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch(error, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch(error, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    Pid ! {cleanup, erlang:system_time(seconds)+150},
    S3=[
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    gen_server:stop(Pid, normal, 3000),
    S1++S2++S3.
-endif.

