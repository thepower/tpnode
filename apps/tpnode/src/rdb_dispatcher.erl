%%%-------------------------------------------------------------------
%% @doc rdb_dispatcher gen_server
%% @end
%%%-------------------------------------------------------------------
-module(rdb_dispatcher).
-author("cleverfox <devel@viruzzz.org>").
-create_date("2018-02-13").

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

init(Args) ->
  process_flag(trap_exit, true),
    {ok, #{
       args=>Args,
       dbs=>#{}
      }}.

handle_call({open, DBPath, Args}, _Form, #{dbs:=DBS}=State) ->
  filelib:ensure_dir(DBPath),
  case maps:is_key(DBPath, DBS) of
    true ->
      {reply, maps:get(DBPath, DBS), State};
    false ->
      R=rocksdb:open(DBPath, Args),
      case R of
        {ok, Pid} ->
          {reply,
           R,
           State#{
             dbs=> maps:put(DBPath, {ok, Pid}, DBS)
            }
          };
        Any ->
          {reply, Any, State}
      end
  end;

handle_call({close, DBPath}, _Form, #{dbs:=DBS}=State) ->
    case maps:is_key(DBPath, DBS) of
        true ->
            case maps:get(DBPath, DBS) of
                {ok, DBH} ->
                    rocksdb:close(DBH),
                    {reply, ok, State#{
                                  dbs=>maps:remove(DBPath, DBS)
                                 }
                    };
                _Any ->
                    {reply, {error, _Any}, State}
            end;
        false ->
            {reply, nodb, State}
    end;

handle_call(_Request, _From, State) ->
    ?LOG_NOTICE("Unknown call ~p", [_Request]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    ?LOG_NOTICE("Unknown cast ~p", [_Msg]),
    {noreply, State}.

handle_info({'EXIT', From, Reason}, #{dbs:=DBS}=State) ->
  ?LOG_NOTICE("~s exit from ~p reason ~p", [?MODULE,From,Reason]),
  maps:fold(
    fun(_Path, {ok, DBH}, _) ->
        rocksdb:close(DBH)
    end, undefined, DBS),
  {stop, Reason, State};

handle_info(_Info, State) ->
  ?LOG_NOTICE("~s Unknown info ~p", [?MODULE,_Info]),
  {noreply, State}.

terminate(_Reason, #{dbs:=DBS}=_State) ->
    maps:fold(
      fun(_Path, {ok, DBH}, _) ->
              rocksdb:close(DBH)
      end, undefined, DBS),
    ?LOG_NOTICE("Terminate me ~p", [_State]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

