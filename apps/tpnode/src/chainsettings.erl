-module(chainsettings).
-include("include/tplog.hrl").

-export([get/2,get/3]).
-export([get_val/1,get_val/2]).
-export([get_setting/1,
         is_our_node/1,
         is_our_node/2,
         is_net_node/1,
         settings_to_ets/1,
         settings_to_ets/2,
         all/0,
         as_map/1,
         nodechain/2,
         select_by_path/2,
         by_path/1,
         by_path/2,
         all_nodes/2
        ]).
-export([contacts/1,contacts/2]).
-export([checksum/0]).

is_net_node(PubKey) ->
  case ets:match(blockchain,{[<<"keys">>,'$1'],'_',<<"set">>,PubKey}) of
    [] -> false;
    [[Name]] -> {true, Name}
  end.

nodechain(PubKey, Settings) ->
  KeyDB=maps:get(<<"keys">>, Settings, #{}),
  NodeChain=maps:get(<<"nodechain">>, Settings, #{}),
  AllNodes=maps:fold(
             fun(Name, XPubKey, Acc) ->
                 maps:put(tpecdsa:cmp_pubkey(XPubKey), {Name,maps:get(Name,NodeChain,0)}, Acc)
             end, #{}, KeyDB),
  maps:get(tpecdsa:cmp_pubkey(PubKey), AllNodes, false).

all_nodes(Settings,Chain) ->
  KeyDB=maps:get(<<"keys">>, Settings, #{}),
  NodeChain=maps:get(<<"nodechain">>, Settings, #{}),
  maps:fold(
    fun(<<".">>,_,Acc) ->
        Acc;
       (Name, XPubKey, Acc) when Chain==undefined ->
        maps:put(tpecdsa:cmp_pubkey(XPubKey), Name, Acc);
       (Name, XPubKey, Acc) ->
        UC=maps:get(Name,NodeChain,0),
        if(UC==Chain) ->
            maps:put(tpecdsa:cmp_pubkey(XPubKey), Name, Acc);
          true ->
            Acc
        end
    end, #{}, KeyDB).

is_our_node(PubKey, Settings) ->
  ChainNodes0=all_nodes(Settings,0),
  NodeChain=maps:get(<<"nodechain">>, Settings, #{}),
  MyName=maps:get(tpecdsa:cmp_pubkey(nodekey:get_pub()), ChainNodes0, undefined),
  MyChain=maps:get(MyName, NodeChain, 0),
  ChainNodes=maps:filter(
               fun(_PubKey, Name) ->
                   maps:get(Name, NodeChain, 0) == MyChain
               end, ChainNodes0),
  maps:get(tpecdsa:cmp_pubkey(tpecdsa:upgrade_pubkey(PubKey)), ChainNodes, false).

is_our_node(PubKey) when is_binary(PubKey) ->
  {ok, NMap} = chainsettings:get_setting(chainnodes),
  maps:get(tpecdsa:cmp_pubkey(tpecdsa:upgrade_pubkey(PubKey)), NMap, false).

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

select_by_path(GetPath, [_|_]=Tables) ->
  lists:foldl(fun({Tab,Fun}, A) when is_function(Fun,1) ->
                  TR=ets:match(Tab,{GetPath++'$1','_','$3','$2'}),
                  lists:foldl(
                    fun(Arr,A1) ->
                        case Fun(Arr) of
                          true ->
                            [Arr|A1];
                          false ->
                            A1
                        end
                    end, A, TR);
                 (Tab, A) ->
                  TR=ets:match(Tab,{GetPath++'$1','_','$3','$2'}),
                  A++TR
              end, [], Tables).


by_path(GetPath) ->
  by_path(GetPath, [blockchain]).

by_path(GetPath, default) ->
  TBL=case ets:info(mgmt) of
        undefined -> [blockchain] ;
        _ ->
          [{blockchain,
            fun([Path|_]) ->
                         case Path of
                           [<<"current">>|_] -> true;
                           _ -> false
                         end
                     end},
           {mgmt,
           fun([Path|_]) ->
               case Path of
                 [<<"current">>|_] -> false;
                 _ -> true
               end
           end}
          ]
  end,
  as_map(select_by_path(GetPath,TBL));

by_path(GetPath, [_|_]=Tables) ->
  R=select_by_path(GetPath, Tables),
  as_map(R).

as_map(R) ->
  case R of
    [] ->
      #{};
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
settings_to_ets(NewSettings, blockchain).

settings_to_ets(NewSettings, Table) ->
  ?LOG_DEBUG("Settings2ets ~p",[maps:with([<<"current">>],settings:clean_meta(NewSettings))]),
  Patches=settings:get_patches(NewSettings,ets),
  Ver=erlang:system_time(),
  SetApply=lists:map(fun(#{<<"p">>:=Path,<<"t">>:=Action,<<"v">>:=Value}) ->
                  %?LOG_INFO("Path ~p:~p",[Path,Action]),
                  {Path, Ver, Action, Value}
              end,  Patches),
  %ets:match(blockchain,{[<<"current">>,<<"fee">>|'$1'],'_','$2'})
  %-- ets:fun2ms( fun({_,T,_}=M) when T < Ver -> M end)
  ets:insert(Table,SetApply),
  ets:select_delete(Table,
                    [{{'_','$1','_','_'},[{'<','$1',Ver}],[true]}]
                   ),

  %KeyDB=maps:get(<<"keys">>, NewSettings, #{}),
  %NodeChain=maps:get(<<"nodechain">>, NewSettings, #{}),
  %PubKey=nodekey:get_pub(),
  %ChainNodes0=maps:fold(
  %              fun(Name, XPubKey, Acc) ->
  %                  maps:put(XPubKey, Name, Acc)
  %              end, #{}, KeyDB),
  %MyName=maps:get(PubKey, ChainNodes0, undefined),
  %MyChain=maps:get(MyName, NodeChain, 0),
  %ChainNodes=maps:filter(
  %             fun(_PubKey, Name) ->
  %                 maps:get(Name, NodeChain, 0) == MyChain
  %             end, ChainNodes0),
  %if Table == blockchain ->
  %     blockchain_updater:store_mychain(MyName, ChainNodes, MyChain);
  %   true ->
  %     ok
  %end,
  NewSettings.

contacts(Name, Protocol) when is_binary(Protocol) ->
  contacts(Name, [Protocol]);

contacts(Name, Protocols) when is_list(Protocols) ->
  C=contacts(Name),
  lists:foldl(
    fun(URL,A) ->
        try
          #{scheme:=P}=uri_string:parse(URL),
          case lists:member(P,Protocols) of
            true ->
              [URL|A];
            false ->
              A
          end
        catch _:_ ->
                A
        end
    end, [], C).

contacts(Name) ->
  Config = application:get_env(tpnode, contacts, #{}),
  R=case maps:get(Name, Config, undefined) of
    Value when is_list(Value) ->
      Value;
    undefined ->
      chainsettings:by_path([<<"contacts">>,<<"default">>,Name],default);
    Any ->
      logger:notice("Error value for contact ~p in config: ~p",[Name,Any]),
      chainsettings:by_path([<<"contacts">>,<<"default">>,Name],default)
  end,
  if R==#{} ->
       [];
     R==undefined ->
       [];
     true ->
       R
  end.

get_val(mychain) ->
  throw('use_get_setting');

get_val(Name) ->
  get_val(Name, undefined).

get_val(Name, Default) when Name==minsig; Name==patchsig ->
  Val=by_path([<<"current">>,<<"chain">>,atom_to_binary(Name,utf8)]),
  if is_integer(Val) -> Val;
     true ->
       case ets:lookup(blockchain,chainnodes) of
         [{chainnodes,Map}] ->
           ?LOG_ERROR("No ~s specified!!!!!",[Name]),
           (maps:size(Map) div 2)+1;
         _ ->
           Default
       end
  end;

get_val(Name, Default) when Name==blocktime ->
  Val=by_path([<<"current">>,<<"chain">>,atom_to_binary(Name,utf8)]),
  if is_integer(Val) -> Val;
     true -> Default
  end;


get_val(Name,Default) ->
  Val=by_path([<<"current">>,<<"chain">>,Name]),
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
  case settings:get([<<"current">>,<<"chain">>,<<"patchsig">>],Settings) of
    I when is_integer(I) ->
      I;
    _ ->
      case settings:get([<<"current">>,<<"chain">>,<<"minsig">>],Settings) of
        I when is_integer(I) ->
          I;
        _ ->
          try
            Chain=GetChain(),
            R=settings:get([<<"chain">>,Chain,<<"minsig">>],Settings),
            true=is_integer(R),
            R
          catch _:_ ->
                  3
          end
      end
  end;


get(Name, Sets, GetChain) ->
  MinSig=settings:get([<<"current">>,<<"chain">>,Name], Sets),
  if is_integer(MinSig) -> MinSig;
     true ->
       MinSig_old=settings:get([<<"chain">>,GetChain(),Name], Sets),
       if is_integer(MinSig_old) ->
            ?LOG_INFO("Got setting ~p from deprecated place",[Name]),
            MinSig_old;
          true -> undefined
       end
  end.




checksum() ->
  Settings = all(),
  Settings.
