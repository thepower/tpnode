-module(nodekey).

-export([get_priv/0,
         get_pub/0,
         node_id/0,
         node_id/1,
         node_name/0
        ]).

get_priv() ->
    {ok, K1}=application:get_env(tpnode, privkey),
    hex:parse(K1).

get_pub() ->
    tpecdsa:calc_pub(get_priv(), true).

node_id() ->
  case application:get_env(tpnode, nodeid) of
    undefined -> 
      ID=node_id(get_pub()),
      application:set_env(tpnode, nodeid, ID),
      ID;
    {ok, ID} -> ID
  end.

node_id(PubKey) ->
    Hash=crypto:hash(sha, PubKey),
    base58:encode(Hash).

node_name() ->
    case application:get_env(tpnode, nodename) of
      undefined -> 
        case chainsettings:is_our_node(get_pub()) of
          Name when is_binary(Name) ->
            application:set_env(tpnode, nodename, Name),
            Name;
          _ -> 
            node_id()
        end;
      {ok, Name} -> Name
    end.



