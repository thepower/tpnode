-module(tpnode_ws_dispatcher).
-include("include/tplog.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

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

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_) ->
  {ok, #{
     blocksub=>[],
     addrsub=>#{},
     pidsub=>#{},
     logssub=>[],
     txsub=>[]
    }
    }.

handle_call(state, _From, State) ->
    {reply, State, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({new_logs, BlkID, Height, Logs}, #{logssub:=Sub}=State) ->
  Now = os:system_time(millisecond),
  MPStat=#{
           null => block_logs,
           hash => BlkID,
           height => Height,
           now => Now,
           logs => Logs
          },
  lists:foreach(
    fun({Pid, _}) ->
        erlang:send(Pid, {message, MPStat})
    end, Sub),
  {noreply, State};

handle_cast({new_block, Block}, #{addrsub:=AS, blocksub:=BS}=State) ->
  Now = os:system_time(millisecond),
  PrettyBlock=try
                tpnode_httpapi:prettify_block(Block)
              catch _:_ ->
                      #{error => true}
              end,
  maps:fold(
    fun(Address, BalSnap, _) ->
        {Tx, Bal}=lists:foldl(
                    fun({Pid, Acts}, {ATx, ABal}) ->
                        {
                         case lists:member(tx, Acts) of
                           true -> [Pid|ATx];
                           false -> ATx
                         end,
                         case lists:member(bal, Acts) of
                           true -> [Pid|ABal];
                           false -> ABal
                         end
                        }
                    end, {[], []}, maps:get(Address, AS, [])),
        if Tx=/=[] ->
             ?LOG_INFO("Notify TX ~p", [Tx]),
             BTxs=lists:filter(
                    fun({_TxID, #{from:=Fa}}) when Fa==Address -> true;
                       ({_TxID, #{to:=Ta}}) when Ta==Address -> true;
                       (_) -> false
                    end,
                    maps:get(txs, PrettyBlock)),
             TxJS=jsx:encode(#{txs=>BTxs,
                               address=>Address}),
             lists:foreach(fun(Pid) ->
                               erlang:send(Pid, {message, TxJS})
                           end, Tx);
           true ->
             ok
        end,

        if Bal=/=[] ->
             ?LOG_INFO("Notify Bal ~p", [Bal]),
             BalJS=jsx:encode(#{balance=>BalSnap,
                                address=>Address}),
             lists:foreach(fun(Pid) ->
                               erlang:send(Pid, {message, BalJS})
                           end, Bal);
           true ->
             ok
        end,
        ok
    end, undefined, maps:get(bals, PrettyBlock, #{})),
  BlockJS=jsx:encode(#{block=>PrettyBlock}),
  BlockStat=jsx:encode(#{blockstat=>#{
                           hash=>maps:get(hash,PrettyBlock,[]),
                           header=>maps:get(header,PrettyBlock,[]),
                           txs_cnt=>length(maps:get(txs,Block,[])),
                           sign_cnt=>length(maps:get(sign,Block,[])),
                           settings_cnt=>length(maps:get(settings,Block,[])),
                           bals_cnt=>maps:size(maps:get(bals,Block,#{})),
                           timestamp => Now
                          }}),
  MPStat=#{
           null => new_block,
           block_meta=>block:pack(
             maps:with([header,hash,sign],Block)
            ),
           hash=>maps:get(hash,Block,[]),
           stat=>#{
                   txs=>length(maps:get(txs,Block,[])),
                   sign=>length(maps:get(sign,Block,[])),
                   settings=>length(maps:get(settings,Block,[])),
                   bals=>maps:size(maps:get(bals,Block,#{}))
                  },
           now => Now
          },
  lists:foreach(
    fun({Pid, _Format, full}) ->
        erlang:send(Pid, {message, BlockJS});
       ({Pid, term, stat}) ->
        erlang:send(Pid, {message, MPStat});
       ({Pid, _Format, stat}) ->
        erlang:send(Pid, {message, BlockStat});
       (Pid) when is_pid(Pid) ->
        erlang:send(Pid, {message, BlockJS})
    end, BS),
  {noreply, State};

handle_cast({done, Result, Txs}, State) ->
  BS=maps:get(txsub, State, []),
  lists:foreach(
    fun({TxID, Reason}) ->
        BlockJS=jsx:encode(#{txid=>TxID,
                             result=>Result,
                             info=>format_reason(Reason)
                            }),
        lists:foreach(fun(Pid) ->
                          erlang:send(Pid, {message, BlockJS})
                      end, BS);
       (TxID) ->
        BlockJS=jsx:encode(#{txid=>TxID,
                             result=>Result
                            }),
        lists:foreach(fun(Pid) ->
                          erlang:send(Pid, {message, BlockJS})
                      end, BS)
    end, Txs),
  {noreply, State};

handle_cast({subscribe, logs, Pid, _Filter}, #{logssub:=LS, pidsub:=PS}=State) ->
  monitor(process, Pid),
  {noreply, State#{
              logssub=>[{Pid,[]}|LS],
              pidsub=>maps:put(Pid, [logs|maps:get(Pid, PS, [])], PS)
             }
  };

handle_cast({subscribe, tx, Pid}, #{pidsub:=PS}=State) ->
  TS=maps:get(txsub, State, []),
  monitor(process, Pid),
  {noreply, State#{
              txsub=>[Pid|TS],
              pidsub=>maps:put(Pid, [tx|maps:get(Pid, PS, [])], PS)
             }
  };

handle_cast({subscribe, block, Pid}, State) ->
  handle_cast({subscribe, {block, json, full}, Pid}, State);

handle_cast({subscribe, {block, Format, Part}, Pid},
            #{blocksub:=BS, pidsub:=PS}=State) ->
    monitor(process, Pid),
    {noreply, State#{
                blocksub=>[{Pid,Format,Part}|BS],
                pidsub=>maps:put(Pid, [block|maps:get(Pid, PS, [])], PS)
               }
    };

handle_cast({subscribe, address, Address, Subs, Pid}, #{addrsub:=AS, pidsub:=PS}=State) ->
    monitor(process, Pid),
    {noreply, State#{
                addrsub=>maps:put(Address, [{Pid, Subs}|maps:get(Address, AS, [])], AS),
                pidsub=>maps:put(Pid, [{addr, Address}|maps:get(Pid, PS, [])], PS)
               }
    }.

handle_info({'DOWN', _Ref, process, Pid, _Reason},
            #{addrsub:=AS0, blocksub:=BS0, pidsub:=PS, logssub:=LS0}=State) ->
  TS0=maps:get(txsub, State, []),
  Subs=maps:get(Pid, PS, []),
  {BS1, TS1, AS1, LS1}=lists:foldl(
                    fun(block, {BS, TS, AS, LS}) ->
                        {lists:filter(
                           fun({XPid,_,_}) ->
                               XPid=/=Pid;
                              (XPid) ->
                               XPid=/=Pid
                           end, BS), TS, AS, LS};
                       (tx, {BS, TS, AS, LS}) ->
                        {BS, lists:delete(Pid, TS), AS, LS};
                       (logs, {BS, TS, AS, LS}) ->
                        {BS, TS, AS,
                         lists:keydelete(Pid,1,LS)
                        };
                       ({addr, A}, {BS, TS, AS, LS}) ->
                        AAS=lists:filter(
                              fun({PP, _}) -> PP=/=Pid
                              end, maps:get(A, AS, [])),
                        if AAS == [] ->
                             {BS, TS, maps:remove(A, AS), LS};
                           true ->
                             {BS, TS, maps:put(A, AAS, AS), LS}
                        end
                    end, {BS0, TS0, AS0, LS0}, Subs),
  {noreply, State#{
              blocksub=>BS1,
              addrsub=>AS1,
              logssub=>LS1,
              txsub=>TS1,
              pidsub=>maps:remove(Pid, PS)
             }
  };


handle_info(_Info, State) ->
  ?LOG_INFO("Unknown INFO ~p", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

format_reason(#{address:=Addr}=Reason) when is_binary(Addr) ->
  Reason#{address=>naddress:encode(Addr)};
format_reason(Reason) when is_map(Reason) -> Reason;
format_reason(Reason) when is_atom(Reason) -> Reason;
format_reason(Reason) -> iolist_to_binary( io_lib:format("~p", [Reason])).

