-module(chainsettings).

-export([get/2,get/3]).
-export([get_val/1,get_val/2]).
-export([get_setting/1,
         is_our_node/1,
         is_our_node/2,
         settings_to_ets/1,
         all/0, by_path/1]).
-export([checksum/0]).

is_our_node(PubKey, Settings) ->
  KeyDB=maps:get(keys, Settings, #{}),
  NodeChain=maps:get(nodechain, Settings, #{}),
  ChainNodes0=maps:fold(
                fun(Name, XPubKey, Acc) ->
                    maps:put(XPubKey, Name, Acc)
                end, #{}, KeyDB),
  MyName=maps:get(nodekey:get_pub(), ChainNodes0, undefined),
  MyChain=maps:get(MyName, NodeChain, 0),
  ChainNodes=maps:filter(
               fun(_PubKey, Name) ->
                   maps:get(Name, NodeChain, 0) == MyChain
               end, ChainNodes0),
  maps:get(PubKey, ChainNodes, false).

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

all() ->
  R=ets:match(blockchain,{'$1','_','$3','$2'}),
  lists:foldl(
    fun([Path,Val,Act],Acc) ->
        settings:patch([#{<<"t">>=>Act, <<"p">>=>Path, <<"v">>=>Val}], Acc)
    end,
    #{},
    R
   ).

by_path(GetPath) ->
  R=ets:match(blockchain,{GetPath++'$1','_','$3','$2'}),
  case R of
    [[[],Val,<<"set">>]] ->
      Val;
    Any ->
      lists:foldl(
        fun([Path,Val,Act],Acc) ->
            settings:patch([#{<<"t">>=>Act, <<"p">>=>Path, <<"v">>=>Val}], Acc)
        end,
        #{},
        Any
       )
  end.

settings_to_ets(NewSettings) ->
  lager:debug("Settings2ets ~p",[maps:with([<<"current">>],settings:clean_meta(NewSettings))]),
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
  lager:info("My name ~s chain ~p our chain nodes ~p", [MyName, MyChain, maps:values(ChainNodes)]),
  ets:insert(blockchain,[{myname,MyName},{chainnodes,ChainNodes},{mychain,MyChain}]),
  NewSettings.

get_val(Name) ->
  get_val(Name, undefined).

get_val(mychain, Def) ->
  case ets:lookup(blockchain,mychain) of
    [{mychain,X}] -> X;
    _ -> Def
  end;

get_val(Name, Default) when Name==minsig; Name==patchsig ->
  Val=by_path([<<"current">>,chain,Name]),
  if is_integer(Val) -> Val;
     true ->
       case ets:lookup(blockchain,chainnodes) of
         [{chainnodes,Map}] ->
           lager:error("No ~s specified!!!!!",[Name]),
           (maps:size(Map) div 2)+1;
         _ ->
           Default
       end
  end;

get_val(Name,Default) ->
  Val=by_path([<<"current">>,chain,Name]),
  if is_integer(Val) -> Val;
     true -> Default
  end.

get(Key, Settings) ->
  get(Key, Settings, fun() ->
                         Chain=blockchain:chain(),
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




checksum() ->
  Settings = all(),
  Settings.
