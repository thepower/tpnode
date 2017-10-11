-module(tpnode_tools).
-export([node_id/0]).
node_id() ->
    {ok,K1}=application:get_env(tpnode,privkey),
    address:pub2addr(node,secp256k1:secp256k1_ec_pubkey_create(hex:parse(K1), true)).


