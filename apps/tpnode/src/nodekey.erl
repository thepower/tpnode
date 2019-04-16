-module(nodekey).

-export([get_priv/0,
         get_pub/0,
         node_id/0,
         node_id/1,
         node_name/1,
         node_name/0
        ]).

get_priv() ->
  {ok, K1}=application:get_env(tpnode, privkey),
  case K1 of
    <<_:32/binary>> -> K1;
    _ -> 
      Res=hex:parse(K1),
      32=size(Res),
      application:set_env(tpnode, privkey, Res),
      Res
  end.

get_pub() ->
  case application:get_env(tpnode, pubkey) of
    {ok, Bin} when is_binary(Bin) ->
      Bin;
    _ -> 
      Pub=tpecdsa:calc_pub(get_priv(), true),
      application:set_env(tpnode, pubkey, Pub),
      Pub
  end.

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

node_name(Default) ->
  case node_name() of
    Any when is_binary(Any) -> Any;
    _ -> Default
  end.

node_name() ->
  try
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
    end
  catch
    error:{badmatch,_} -> undefined;
    error:badarg -> undefined
  end.



