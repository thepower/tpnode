-module(tpnode_tools).
-export([node_id/0]).
node_id() ->
    {ok,K1}=application:get_env(tpnode,privkey),
    address:pub2addr(node,tpecdsa:calc_pub(hex:parse(K1), true)).


