-module(genesis_c7b).
-compile([nowarn_export_all, export_all]).

local_chain() -> 7.
local_group() -> 1024.
prefix() -> "examples/test_chain7/".

chainstate() ->
  naddress:construct_public(local_group(),local_chain(),1).
chainfee() ->
  naddress:construct_private(local_group(), 1).
minter() ->
  naddress:construct_private(local_group(), 2).
admin() ->
  naddress:construct_private(local_group(), 3).

node_priv_file(KeyName) ->
  File=prefix()++KeyName,
  {ok, L} = file:consult(File),
  {privkey, K} = lists:keyfind(privkey, 1, L),
  hex:decode(K).

node_privs() ->
  lists:map(fun node_priv_file/1,
            wildcard("c7n?.conf","")
           ).

node_keys() ->
  lists:map(fun tpecdsa:calc_pub/1,
            node_privs()
           ).

code(Name) ->
  genesis2:read_contract("examples/evm_builtin/build/"++Name).

pre_tx() ->
  [
   {<<0>>, code, [], code("ChainSettings.bin-runtime")},
   {chainstate(), code, [], code("ChainState.bin-runtime")},
   {chainfee(), code, [], code("ChainFee.bin-runtime")},

   {<<0>>, pubkey, [], pub_example("chainsettings1")},
   {chainstate(), pubkey, [], pub_example("chainstate1")},
   {chainfee(), pubkey, [], pub_example("chainfee1")},
   {minter(), pubkey, [], pub_example("minter1")},

   {admin(), balance, <<"SK">>, 100000_000000000}, %100000 SK
   {admin(), pubkey, [], pub_example("admin1")}
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
    <<"tag">> => <<"test_chain7">>,
    <<"blocktime">> => 3,
    <<"allocblock">> => #{
                          <<"block">> => local_chain(),
                          <<"group">> => local_group(),
                          <<"last">> => 16
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
 
priv_example(ToHash) ->
  ASN1=hex:decode("302E020100300506032B657004220420"), %ed25519 keys
  Digest=crypto:hash(sha256,ToHash),
  <<ASN1/binary,Digest/binary>>.

pub_example(ToHash) ->
  ASN1=hex:decode("302E020100300506032B657004220420"), %ed25519 keys
  Digest=crypto:hash(sha256,ToHash),
  tpecdsa:calc_pub(<<ASN1/binary,Digest/binary>>).

wildcard(Pattern, Ext) ->
  genesis2:wildcard(?MODULE, Pattern, Ext).
 
