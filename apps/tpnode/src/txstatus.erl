-module(txstatus).
-include("include/tplog.hrl").
-behaviour(gen_server).
-compile({no_auto_import,[get/1]}).
-define(SERVER, ?MODULE).
-define(CLEANUP, 30000). %ms
-define(TIMEOUT, 600). %sec

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,get/1,get_json/1,jsonfy/1]).

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
  R=gen_server:call(?MODULE, {get, TxID}),
  if R==undefined ->
      case gen_server:call(blockchain_reader,{txid, TxID, true}) of
        not_found -> undefined;
        #{block := BlkHash,
          hash := _TxHash,
          hei := BlkHei,
          index := TxIndex,
          tx := _,
          receipt := [_,_,_,Succ,Ret|_]
         } ->
           {true,#{block => BlkHash,
                   blockn => BlkHei,
                   index => TxIndex,
                   txhash => _TxHash,
                   retval => Ret,
                   success => Succ
                  }};
        #{block := BlkHash,
          hash := _TxHash,
          hei := BlkHei,
          index := TxIndex,
          tx := _
         } ->
           {true,#{block => BlkHash,
                   blockn => BlkHei,
                   index => TxIndex,
                   txhash => _TxHash,
                   %retval => <<>>,
                   success => 1
                  }}
      end;
    true -> 
       R
  end.


get_json(TxID) ->
  R=get(TxID),
  if R==undefined ->
       null;
     true ->
       jsonfy(R)
  end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  {ok, #{
    q=>hashqueue:new(),
    timer=>erlang:send_after(?CLEANUP, self(), timer)
  }}.

handle_call({get, TxID}, _From, #{q:=Q}=State) ->
  R=hashqueue:get(TxID, Q),
  {reply, R, State};

handle_call(_Request, _From, State) ->
    {reply, unknown_call, State}.

handle_cast({done, Result, Txs}, #{q:=Q} = State) when is_list(Txs) ->
  %{done,false,[{<<"1524179A464B33A2-3NBx74EdmT2PyYexBSrg7xcht998-03A2">>,{contract_error, [error,{badmatch,#{<<"fee">> => 30000000,<<"feecur">> => <<"FTT">>,<<"message">> => <<"To AA100000001677722185 with love">>}}]}}]}
  %{done,true,[<<"AA1000000016777220390000000000000009xQzCH+qGbhzKlrFxoZOLWN5DhVE=">>]}
  stout:log(txstatus_done, [{result, Result}, {ids, Txs}]),
  Timeout = erlang:system_time(seconds) + ?TIMEOUT,
  Q1 = lists:foldl(
    fun
      ({TxID, Res}, QAcc) ->
        %tinymq:push(TxID,{Result,Res}),
        hashqueue:add(TxID, Timeout, {Result, Res}, QAcc);
      (TxID, QAcc) ->
        %tinymq:push(TxID,{Result,
        %    if Result ->
        %      ok;
        %      true -> error
        %    end
        %  }),
        hashqueue:add(
          TxID,
          Timeout,
          {Result,
            if Result ->
              ok;
              true -> error
            end
          },
          QAcc)
    end, Q, Txs),

  {noreply,
    State#{q=>Q1}
  };


handle_cast(_Msg, State) ->
  ?LOG_NOTICE("Unhandler cast ~p",[_Msg]),
  {noreply, State}.

handle_info(timer, #{timer:=Tmr} = State) ->
  catch erlang:cancel_timer(Tmr),
  handle_info(
    {cleanup,
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

%% ------------------------------------------------------------------

jsonfy({IsOK, ExtData}) ->
  maps:fold(
    fun
      (txhash, Blk, A) ->
        maps:put(txhash,hex:encodex(Blk),A);
      (block, Blk, A) ->
        maps:put(block,hex:encodex(Blk),A);
      (blockn, Blk, A) ->
        maps:put(blockn,Blk,A);
      (success, Blk, A) ->
        maps:put(success,Blk,A);
      (K,_V,A) ->
        A
    end,
    jsonfy1({IsOK, maps:without([block,blockn],ExtData)}),
    ExtData).


%jsonfy({IsOK, #{block:=Blk,blockn:=N}=ExtData}) ->
%  R=jsonfy1({IsOK, maps:without([block,blockn],ExtData)}),
%  R#{ block=>hex:encodex(Blk), blockn=>N };
%jsonfy({IsOK, #{block:=Blk}=ExtData}) ->
%  R=jsonfy1({IsOK, maps:without([block],ExtData)}),
%  R#{ block=>hex:encodex(Blk) };
%
%jsonfy({IsOK, ExtData}) ->
%  jsonfy1({IsOK, ExtData}).

%% ------------------------------------------------------------------

jsonfy1({false,{error,{contract_error,[Ec,Ee]}}}) ->
  #{ error=>true,
     res=><<"smartcontract">>,
     type=>Ec,
     reason=>iolist_to_binary(io_lib:format("~p",[Ee]))};

jsonfy1({true,#{address:=Addr}}) ->
  #{ok=>true,
    res=>nex:encode(Addr),
    address=>naddress:encode(Addr)
   };

jsonfy1({true,#{retval:=RV}}) when is_integer(RV)->
  #{ok=>true,
    res=>ok,
    retval=>RV
   };

jsonfy1({true,#{retval:=RV}}) when is_binary(RV)->
  #{ok=>true,
    res=>ok,
    retval=>hex:encodex(RV)
   };

jsonfy1({true,#{revert:=RV}}) when is_binary(RV)->
  #{ok=>true,
    res=><<"revert">>,
    revert=>utils:textize_binary(RV)
   };

jsonfy1({true,Status}) when is_map(Status)->
  case maps:size(Status) of 
    0 ->
      #{ok=>true,
        res=>ok
       };
    _ ->
      #{ok=>true,
        s=>maps:size(Status),
        res=>format_res(Status)
       }
  end;

jsonfy1({true,Status}) ->
  #{ok=>true,
    res=>format_res(Status)
   };

jsonfy1({false,Status}) ->
  #{error=>true,
    res=>format_res(Status)
   }.


%% ------------------------------------------------------------------

format_res(Atom) when is_atom(Atom) -> Atom;

format_res(#{<<"reason">> := R}) when is_atom(R); is_binary(R) ->
  R;

format_res(Any) ->
  iolist_to_binary(io_lib:format("~p",[Any])).

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


%% ------------------------------------------------------------------
%% ------------------------------------------------------------------

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
        ?assertMatch({true,ok}, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch({true,ok}, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch({false,"err1"}, gen_server:call(Pid,{get, <<"1334">>})),
        ?assertMatch({false,"err2"}, gen_server:call(Pid,{get, <<"1335">>})),
        ?assertMatch({false,error}, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch({false,error}, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    Pid ! {cleanup, erlang:system_time(seconds)+?TIMEOUT-1},
    S2=[
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch({false,error}, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch({false,error}, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    Pid ! {cleanup, erlang:system_time(seconds)+?TIMEOUT+1},
    S3=[
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1234">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1235">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1236">>})),
        ?assertMatch(undefined, gen_server:call(Pid,{get, <<"1237">>}))
       ],
    gen_server:stop(Pid, normal, 3000),
    S1++S2++S3.
-endif.

