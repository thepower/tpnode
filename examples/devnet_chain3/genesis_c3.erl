-module(genesis_c3).
-compile([nowarn_export_all, export_all]).

local_chain() -> 3.
local_group() -> 10.
prefix() -> "examples/devnet_chain3/".

chainstate() ->
  naddress:construct_public(local_group(),local_chain(),1).
chainfee() ->
  naddress:construct_private(local_group(), 1).
minter() ->
  naddress:construct_private(local_group(), 2).
admin() ->
  naddress:construct_private(local_group(), 3).

node_privs() ->
  lists:map(fun priv_file/1,
            [ "node1", "node2", "node3"]
           ).
  %wildcard("c3n*",".pvt").

node_keys() ->
  lists:map(fun pub_file/1,
            wildcard("node?",".pub")
           ).

code_chainstate() ->
  genesis2:read_contract("examples/evm_builtin/build/ChainState.bin-runtime").

pre_tx() ->
  [
   {<<0>>, code, [], genesis2:read_contract("examples/evm_builtin/build/ChainSettings.bin-runtime")},
   {chainstate(), code, [], code_chainstate()},
   {chainfee(), code, [], genesis2:read_contract("examples/evm_builtin/build/ChainFee.bin-runtime")},

   {<<0>>, pubkey, [], pub_file("chainsettings1")},
   {chainstate(), pubkey, [], pub_file("chainstate1")},
   {chainfee(), pubkey, [], pub_file("chainfee1")},
   {minter(), pubkey, [], pub_file("minter1")},

   {admin(), balance, <<"SK">>, 100000_000000000}, %100000 SK
   {admin(), pubkey, [], pub_file("admin1")}
  ].

make_txs() ->
  lists:flatten(
  [
   {
    #{
      ver=>2,
      kind=>lstore,
      from=><<0>>,
      patches=>[
                #{<<"t">>=><<"set">>, <<"p">>=>[<<"configured">>], <<"v">>=>1}
                | settings:get_patches(settings())
               ]
     }, 1000},
   {
   tx:construct_tx(#{
                     kind => generic,
                     t => os:system_time(millisecond),
                     seq => 1,
                     from => chainstate(),
                     to => chainstate(),
                     ver => 2,
                     payload => [],
                     call => #{
                               function=>"allow_self_registration(bool)",
                               args=>[1]
                              }
                    }), 100000},
   {
    tx:construct_tx(#{
                      kind => generic,
                      t => os:system_time(millisecond),
                      seq => 1,
                      from => chainstate(),
                      to => chainstate(),
                      ver => 2,
                      payload => [],
                      call => #{
                                function=>"set_chainfee(address)",
                                args=>[chainfee()]
                               }
                     }), 100000}
   | [
      [
       {
       tx:construct_tx(#{
                         kind => generic,
                         t => 0,
                         seq => 0,
                         from => chainstate(),
                         to => chainstate(),
                         ver => 2,
                         payload => [],
                         call => #{
                                   function=>"register(bytes)",
                                   args=>[Node]
                                  }
                        }), 100000,
       fun(1,<<Id:256/big>>,_) ->
           true=(Id>0)
       end},
      {
       tx:construct_tx(#{
                         kind => generic,
                         t => 0,
                         seq => 0,
                         from => chainstate(),
                         to => chainstate(),
                         ver => 2,
                         payload => [],
                         call => #{
                                   function=>"set_nodekind(bytes,uint8)",
                                   args=>[Node,3]
                                  }
                        }), 100000
      }] || Node <- node_keys() ]
  ]).

post_tx() ->
  [
   {<<1,2,3,4,5,6,7,8>>, balance, <<"SK">>, 100500}
  ].


settings() ->
  #{
    <<"allocblock">> => #{
                          block => local_chain(),
                          group => local_group(),
                          last => 16
                         },
    <<"fee">> => #{
                   <<"SK">> => #{ <<"base">> => 10000000,
                                  <<"baseextra">> => 80,
                                  <<"kb">> => 100000000
                                },
                   <<"params">> => #{ <<"feeaddr">> => chainfee() }
                  },
    <<"freegas2">> => #{ chainstate() => 5_000_000 },
    <<"autorun">> => #{ <<"afterBlock">> => chainstate() },
    <<"gas">> => #{
                   <<"SK">> => #{
                                 <<"gas">> => 1,
                                 <<"tokens">> => 1000
                                }
                  },
    <<"chainstate">> => chainstate(),
    <<"minter">> => #{ minter() => #{ <<"SK">> => 1 } }
   }.

key_absend(KeyName, Filename) ->
%  throw({error,
%             list_to_binary(
%               io_lib:format("No key found for ~s",[KeyName])
%              )}).
%
  io:format("No key found for ~s, creating new ed25519~n",[KeyName]),
  Priv=tpecdsa:generate_priv(ed25519),
  ok=file:write_file(Filename,hex:encodex(Priv)),
  Priv.

priv_file(KeyName) ->
  genesis2:priv_file(?MODULE, KeyName).

pub_file(KeyName) ->
  genesis2:pub_file(?MODULE, KeyName).
 
wildcard(Pattern, Ext) ->
  genesis2:wildcard(?MODULE, Pattern, Ext).
 
