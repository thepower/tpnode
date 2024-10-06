-module(genesis_c7).
-compile([nowarn_export_all, export_all]).

local_chain() -> 7.
local_group() -> 65535.

genesis() ->
  Blk=make_block(),
  SignedBlock=lists:foldl(
    fun(Priv,Acc) ->
        block:sign(Acc,Priv)
    end, Blk, privs()),
  file:write_file("examples/test_chain7/0.txt",io_lib:format("~p.~n",[SignedBlock])),
  file:write_file("examples/test_chain7/0.blk",block:pack(SignedBlock)),
  Blk.

chainstate() ->
  naddress:construct_public(local_group(),local_chain(),1).
chainfee() ->
  naddress:construct_private(local_group(), 1).
minter() ->
  naddress:construct_private(local_group(), 2).
admin() ->
  naddress:construct_private(local_group(), 3).

code_chainstate() ->
  read_contract("examples/evm_builtin/build/ChainState.bin-runtime").

pre_tx() ->
  [
   {<<0>>, code, [], read_contract("examples/evm_builtin/build/ChainSettings.bin-runtime")},
   {chainstate(), code, [], code_chainstate()},
   {chainfee(), code, [], read_contract("examples/evm_builtin/build/ChainFee.bin-runtime")},

   {<<0>>, pubkey, [], pub_example("chainsettings1")},
   {chainstate(), pubkey, [], pub_example("chainstate1")},
   {chainfee(), pubkey, [], pub_example("chainfee1")},
   {minter(), pubkey, [], pub_example("minter1")},

   {admin(), balance, <<"SK">>, 100000_000000000}, %100000 SK
   {admin(), pubkey, [], pub_example("admin1")}
  ].

priv_example(ToHash) ->
  ASN1=hex:decode("302E020100300506032B657004220420"), %ed25519 keys
  Digest=crypto:hash(sha256,ToHash),
  <<ASN1/binary,Digest/binary>>.

pub_example(ToHash) ->
  ASN1=hex:decode("302E020100300506032B657004220420"), %ed25519 keys
  Digest=crypto:hash(sha256,ToHash),
  tpecdsa:calc_pub(<<ASN1/binary,Digest/binary>>).

privs() ->
  [
   priv_example("node1"),
   priv_example("node2"),
   priv_example("node3")
  ].

node_keys() ->
  MkKey=fun(Priv) ->
            Pub=tpecdsa:calc_pub(Priv),
            {pub,ed25519}=tpecdsa:keytype(Pub),
            Pub
        end,
  [ MkKey(Priv) || Priv <- privs() ].

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

init(State0) ->
  State1
  = lists:foldl(fun({Address, Field, Path, Value}, Acc) ->
                    pstate:set_state(Address, Field, Path, Value, Acc)
                end, State0, pre_tx()),
  State2
  = lists:foldl(fun
                ({TxBody,GasLimit,Check},Acc) ->
                    {Res, Ret, _GasLeft, Acc1}=process_txs:process_tx(TxBody, GasLimit, Acc, #{}),
                    Check(Res,Ret,Acc1),
                    Acc1;
                ({TxBody,GasLimit},Acc) ->
                  {Res, Ret, _GasLeft, Acc1}=process_txs:process_tx(TxBody, GasLimit, Acc, #{}),
                  if(Res==1) ->
                      Acc1;
                    true ->
                      io:format("TX ~p failed ~p~n",[maps:without([body, hash],TxBody), Ret]),
                      io:format("LOG: ~p~n",[maps:get(log,Acc1)]),
                      throw('tx_failed')
                  end
              end, State1, make_txs()),
  io:format("LOG: ~p~n",[maps:get(log,State2)]),
  io:format("Patch: ~p~n",[pstate:patch(State2)--pstate:patch(State1)]),
  State3
  = lists:foldl(fun({Address, Field, Path, Value}, Acc) ->
                    pstate:set_state(Address, Field, Path, Value, Acc)
                end, State2, post_tx()),
  State3.



make_block() ->
  {LedgerHash, Patch}
  = mledger:deploy4test(test, [],
                        fun(LedgerName) ->
                            S0=process_txs:new_state(
                              fun mledger:getfun/2,
                              LedgerName
                             ),
                            Acc=init(S0),
                            P=lists:reverse(pstate:patch(Acc)),
                            {ok,H} = mledger:apply_patch(LedgerName,
                                                mledger:patch_pstate2mledger(
                                                  P
                                                 ),
                                                check),
                            {H, P}
                        end),
	BlkData=#{
            txs=>[],
            receipt => [],
            parent=><<0:64/big>>,
            mychain=>7,
            height=>0,
            failed=>[],
            temporary=>false,
            ledger_hash=>LedgerHash,
            ledger_patch=>Patch,
            settings=>[],
            extra_roots=>[],
            extdata=>[]
           },
  Blk=block:mkblock2(BlkData),

  % TODO: Remove after testing
  % Verify myself
  % Ensure block may be packed/unapcked correctly
  case block:verify(block:unpack(block:pack(Blk))) of
    {true, _} -> ok;
    false ->
      throw("invalid_block")
  end,
  Blk.


read_contract(Filename) ->
  {ok,HexBin} = file:read_file(Filename),
  hex:decode(HexBin).


