-module(chainsettings).

-export([get/2,get/3]).
-export([get_setting/1,
         is_our_node/1,
         settings_to_ets/1,
         get_settings_by_path/1]).

is_our_node(PubKey) ->
  {ok, NMap} = chainsettings:get_setting(chainnodes),
  maps:get(PubKey, NMap, false).

get_setting(Named) ->
  case ets:lookup(blockchain,Named) of
    [{Named, Value}] ->
      {ok, Value};
    [] ->
      error
  end.

get_settings_by_path(GetPath) ->
  lists:foldl(
    fun([Path,Val,Act],Acc) ->
        settings:patch([#{<<"t">>=>Act, <<"p">>=>Path, <<"v">>=>Val}], Acc)
    end,
    #{},
    ets:match(blockchain,{GetPath++'$1','_','$3','$2'})
   ).

settings_to_ets(NewSettings) ->
  Patches=settings:get_patches(NewSettings,ets),
  Ver=erlang:system_time(),
  SetApply=lists:map(fun(#{<<"p">>:=Path,<<"t">>:=Action,<<"v">>:=Value}) ->
                  lager:info("Path ~p:~p",[Path,Action]),
                  {Path, Ver, Action, Value}
              end,  Patches),
  %ets:match(blockchain,{[<<"current">>,<<"fee">>|'$1'],'_','$2'})
  %-- ets:fun2ms( fun({_,T,_}=M) when T < Ver -> M end)
  ets:insert(blockchain,SetApply),
  ets:select_delete(blockchain,
                    [{{'_','$1','_','_'},[{'<','$1',Ver}],[true]}]
                   ),

  KeyDB=maps:get(keys, NewSettings, #{}),
  NodeChain=maps:get(nodechain, NewSettings, #{}),
  PubKey=nodekey:get_pub(),
  lager:info("My key ~s", [bin2hex:dbin2hex(PubKey)]),
  ChainNodes0=maps:fold(
                fun(Name, XPubKey, Acc) ->
                    maps:put(XPubKey, Name, Acc)
                end, #{}, KeyDB),
  MyName=maps:get(PubKey, ChainNodes0, undefined),
  MyChain=maps:get(MyName, NodeChain, 0),
  ChainNodes=maps:filter(
               fun(_PubKey, Name) ->
                   maps:get(Name, NodeChain, 0) == MyChain
               end, ChainNodes0),
  lager:info("My name ~p chain ~p ournodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
  ets:insert(blockchain,[{myname,MyName},{chainnodes,ChainNodes},{mychain,MyChain}]),
  NewSettings.


get(Key, Settings) ->
  get(Key, Settings, fun() ->
               {Chain, _}=gen_server:call(blockchain, last_block_height, -1),
               true=is_integer(Chain),
               Chain
           end).


get(allowempty, Settings, GetChain) ->
  get(<<"allowempty">>, Settings, GetChain);

get(patchsig, Settings, GetChain) ->
  case settings:get([<<"current">>,chain,patchsig],Settings) of
    I when is_integer(I) ->
      I;
    _ ->
      case settings:get([<<"current">>,chain,minsig],Settings) of
        I when is_integer(I) ->
          I;
        _ ->
          try
            Chain=GetChain(),
            R=settings:get([chain,Chain,minsig],Settings),
            true=is_integer(R),
            R
          catch _:_ ->
                  3
          end
      end
  end;


get(Name, Sets, GetChain) ->
  MinSig=settings:get([<<"current">>,chain,Name], Sets),
  if is_integer(MinSig) -> MinSig;
     true ->
       MinSig_old=settings:get([chain,GetChain(),Name], Sets),
       if is_integer(MinSig_old) -> 
            lager:info("Got setting ~p from deprecated place",[Name]),
            MinSig_old;
          true -> undefined
       end
  end.

