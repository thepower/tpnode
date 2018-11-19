-module(genuml).

-export([bv/1]).

bv(BLog) ->
  stout_reader:fold(
    fun(T,bv_gotblock, PL, _Acc) ->
        Hash=proplists:get_value(hash, PL, <<>>),
        H=proplists:get_value(height, PL, -1),
        Sig=[
             nodekey:node_id(
               proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(S)))
              ) || S<-
             proplists:get_value(sig, PL,[]) ],
        io:format("~w ~w ~s ~p~n",[T,H,hex:encode(Hash), Sig]);


       (T,bv_gotsig, PL, _Acc) ->
        Hash=proplists:get_value(hash, PL, <<>>),
        Sig=[
             nodekey:node_id(
               proplists:get_value(pubkey,maps:get(extra,bsig:unpacksig(S)))
              ) || S<-
             proplists:get_value(sig, PL,[]) ],
        io:format("~w ~s ~p~n",[T,hex:encode(Hash),Sig]),
        ok;

%       (T,K,PL,Acc) ->
%        io:format("~w ~s ~p~n",[T,K,proplists:get_value(hash,PL)]),
%        Acc+1;
       (_,_,_,Acc) ->
        Acc
    end, 0, BLog).


