-module(tpic2_response).

-export([handle/6]).

handle(PK, SID, ReqID, <<>>, Data, State) ->
  From={PK,SID,ReqID},
  case tpic2_cmgr:lookup_trans(ReqID) of
    {ok, Pid} ->
      Alive=is_process_alive(Pid),
      if Alive ->
           lager:debug("send to pid ~p",[Pid]),
           tpnode_tpic_handler:handle_response(From, Pid, <<>>, Data, State);
         true ->
           lager:debug("send to default handler ~p because pid ~p is dead",[SID, Pid]),
           tpnode_tpic_handler:handle_tpic(From, SID, <<>>, Data, State)
      end;
    error ->
      lager:debug("send to default handler ~p",[SID]),
      tpnode_tpic_handler:handle_tpic(From, SID, <<>>, Data, State)
  end;

handle(PK, SID, ReqID, Proc, Data, State) ->
  From={PK,SID,ReqID},
  tpnode_tpic_handler:handle_tpic(From, SID, Proc, Data, State).


