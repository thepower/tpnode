-module(tpic2_response).

-export([handle/6]).

handle(PK, SID, ReqID, <<>>, Data, State) ->
  From={PK,SID,ReqID},
  case tpic2_cmgr:lookup_trans(ReqID) of
    {ok, Pid} ->
      error_logger:info_msg("Got reply to ~p msg ~p from ~p",[Pid,Data,From]),
      gen_server:cast(Pid, {tpic, From, Data});
    error ->
      error_logger:info_msg("Got msg ~p from ~p",[Data,From]),
      tpnode_tpic_handler:handle_tpic(From, SID, <<>>, Data, State)
  end;

handle(PK, SID, ReqID, Proc, Data, State) ->
  From={PK,SID,ReqID},
  error_logger:info_msg("Got srv ~p msg ~p from ~p",[Proc,Data,From]),
  tpnode_tpic_handler:handle_tpic(From, SID, Proc, Data, State).



