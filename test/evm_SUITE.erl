-module(evm_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

init_per_suite(Config) ->
  application:ensure_all_started(gun),
  EAddr=case application:get_env(tptest,endless_addr) of
    {ok,Val} -> Val;
    undefined -> <<128,1,64,0,4,0,0,1>>
  end,
  EKey=case application:get_env(tptest,endless_addr_pk) of
    {ok,KVal} -> KVal;
    undefined -> <<194,124,65,109,233,236,108,24,50,
                   151,189,216,23,42,215,220,24,240,
                   248,115,150,54,239,58,218,221,145,
                   246,158,15,210,165>>
  end,
  contract_evm_abi:init(),

  [{endless_addr,EAddr}, {endless_addr_pk, EKey} |Config].

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

end_per_suite(Config) ->
    Config.

logger(Format) when is_list(Format) ->
  logger(Format, []).

logger(Format, Args) when is_list(Format), is_list(Args) ->
  utils:logger(Format, Args).



%{ok,Bin} = file:read_file("examples/evm_builtin/build/checkSig.hex"),

all() -> [
          evm_erc20_test,
          deployless_run_test,
          evm_apis_test
         ].
 
get_base_url() ->
  DefaultUrl = "http://pwr.local:49842",
  os:getenv("API_BASE_URL", DefaultUrl).

get_wallet_priv_key() ->
  %address:parsekey(<<"5KHwT1rGjWiNzoZeFuDT85tZ6KTTZThd4xPfaKWRUKNqvGQQtqK">>).
  hex:decode("302E020100300506032B6570042204207FB2A32DAEC110847F60A1408E4EC513B52B51231747176C03271C7ECAE48D61").

wallet_async_fin(Node, TxID) ->
  RTX = tpapi2:wait_tx(Node, TxID, erlang:system_time(second)+10),
  {ok,#{<<"address">>:=TAddr}} = RTX,
  {ok, naddress:decode(TAddr)}.


new_wallet_async(Node) ->
  PrivKey = get_wallet_priv_key(),
  case tpapi2:reg(Node, PrivKey, [nowait]) of
    {ok, TxID} ->
      {ok, TxID};
    {error, Details} ->
      logger(
        "wallet registration error: ~p~n", [Details]
      ),
      throw({wallet_registration_error,Details});
    Other ->
      logger("wallet registration error: ~p~n", [Other]),
      throw({wallet_registration_error,Other})
  end.


new_wallet(Node) ->
  PrivKey = get_wallet_priv_key(),
  case tpapi2:reg(Node, PrivKey, []) of
    {ok, #{<<"address">>:=TxtAddress}} ->
      {ok, naddress:decode(TxtAddress)};
    {error, Details} ->
      logger(
        "wallet registration error: ~p~n", [Details]
      ),
      throw(wallet_registration_error);
    Other ->
      logger("wallet registration error: ~p~n", [Other]),
      throw({wallet_registration_error,Other})
  end.

mkstring(Bin) when size(Bin)<32 ->
  PadL=32-size(Bin),
  <<Bin/binary,0:(PadL*8)/integer>>.

make_transaction(Node, From, To, Seq1, Currency, Amount, Message, FromKey, Opts) ->
  Tx = tx:construct_tx(#{
                         ver=>2,
                         kind=>generic,
                         from => From,
                         to => To,
                         t => os:system_time(millisecond),
                         payload => [
                                     #{purpose=>transfer, amount => Amount, cur => Currency}
                                    ],
                         txext =>#{
                                   msg=>Message
                                  },
                         seq=> Seq1
                        }),
  SignedTx = tx:pack(tx:sign(Tx, FromKey)),
  tpapi2:submit_tx(Node, SignedTx,Opts).

evm_erc20_test(Config) ->
  {endless_addr,EAddr}=proplists:lookup(endless_addr,Config),
  {endless_addr_pk,EPriv}=proplists:lookup(endless_addr_pk,Config),
%
  ?assertMatch(true, is_binary(EAddr)),
  ?assertMatch(true, is_binary(EPriv)),
  logger("endless address ~p ~n", [EAddr]),
  logger("endless address pk ~p ~n", [EPriv]),

  Priv = get_wallet_priv_key(),
  {ok,Node}=tpapi2:connect(get_base_url()),

  {ok, Addr}= new_wallet(Node),
  Wallet = naddress:encode(Addr),
  {ok,Seq}=tpapi2:get_seq(Node, EAddr),
  logger("seq for wallet ~p is ~p ~n", [EAddr, Seq]),

  logger("New wallet ~p / ~p~n",[Wallet,Addr]),
  {ok, TxId0} = make_transaction(Node,(EAddr), Addr, Seq+1, <<"FTT">>,
                                 1000000, <<"hello to EVM">>, EPriv, [nowait]),
  {ok, TxId1} = make_transaction(Node,(EAddr), Addr, Seq+2, <<"SK">>,
                                 200, <<"Few SK 4 U">>, EPriv, [nowait]),
  logger("TxId0: ~p", [TxId0]),
  {ok, ResTx0} = tpapi2:wait_tx(Node, TxId0, erlang:system_time(second)+10),
  logger("ResTx0: ~p", [ResTx0]),
  {ok, ResTx1} = tpapi2:wait_tx(Node, TxId1, erlang:system_time(second)+5),
  logger("ResTx1: ~p", [ResTx1]),


  Code0=erc20_code(),

  CoinSym=mkstring(<<"CoinSym">>),
  Code= <<Code0/binary,(131072):256/big,CoinSym/binary,CoinSym/binary,3:256/big>>,

  DeployTx=tx:pack(
             tx:sign(
             tx:construct_tx(
               #{ver=>2,
                 kind=>deploy,
                 from=>Addr,
                 seq=>os:system_time(millisecond),
                 t=>os:system_time(millisecond),
                 payload=>[#{purpose=>gas, amount=>150000, cur=><<"FTT">>}],
                 txext=>#{ "code"=> Code, "vm" => "evm" }
                }
              ),Priv)),

  {ok, #{<<"txid">> := TxID1, <<"res">>:=TxID1Res}} = tpapi2:submit_tx(Node, DeployTx),
  io:format("Deploy txid ~p~n",[TxID1]),
  ?assertMatch(<<"ok">>, TxID1Res),

  GenTx=tx:pack(
          tx:sign(
          tx:construct_tx(
            #{ver=>2,
              kind=>generic,
              to=>Addr,
              from=>Addr,
              seq=>os:system_time(millisecond),
              t=>os:system_time(millisecond),
              payload=>[#{purpose=>gas, amount=>150000, cur=><<"FTT">>}],
              call=>#{
                      args=>[<<12345:256/big>>, 1024],
                      function => "transfer(address,uint256)"
                     }
             }
           ),Priv)),

  STx=tx:pack(
          tx:sign(
          tx:construct_tx(
            #{ver=>2,
              kind=>generic,
              to=>Addr,
              from=>Addr,
              seq=>os:system_time(millisecond)+2,
              t=>os:system_time(millisecond)+2,
              payload=>[#{purpose=>transfer, amount=>1500, cur=><<"FTT">>},
                        #{purpose=>gas,amount=>0,cur=><<"NORUN">>}]
             }
           ),Priv)),

  {ok, #{<<"txid">> := TxID2, <<"block">>:=Blkid2}=Status2} = tpapi2:submit_tx(Node, GenTx),
  {ok, #{<<"txid">> := TxID3, <<"block">>:=Blkid3}=Status3} = tpapi2:submit_tx(Node, STx),
  io:format("ERC20 transfer txid ~p~n",[TxID2]),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
  io:format("Send token tx to ERC20 txid ~p~n",[TxID3]),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status3),
  gun:close(Node),

  #{bals:=Bals}=tpapi:get_fullblock(Blkid2,get_base_url()),
  AddrStorage=maps:get(state,maps:get(Addr,Bals)),
  StorageVals=lists:usort(maps:values(AddrStorage)),
  [
  ?assertMatch(true,lists:member(binary:encode_unsigned(1024),StorageVals)),
  ?assertMatch(true,lists:member(binary:encode_unsigned(131072-1024),StorageVals))
  ].

erc20_code() -> 
  HexCode="606060405260008060146101000a81548160ff0219169083151502179055506000600355600060045534156200003457600080fd5b60405162002d7a38038062002d7a83398101604052808051906020019091908051820191906020018051820191906020018051906020019091905050336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff160217905550836001819055508260079080519060200190620000cf9291906200017a565b508160089080519060200190620000e89291906200017a565b508060098190555083600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000600a60146101000a81548160ff0219169083151502179055505050505062000229565b828054600181600116156101000203166002900490600052602060002090601f016020900481019282601f10620001bd57805160ff1916838001178555620001ee565b82800160010185558215620001ee579182015b82811115620001ed578251825591602001919060010190620001d0565b5b509050620001fd919062000201565b5090565b6200022691905b808211156200022257600081600090555060010162000208565b5090565b90565b612b4180620002396000396000f30060606040523615610194576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff16806306fdde03146101995780630753c30c14610227578063095ea7b3146102605780630e136b19146102a25780630ecb93c0146102cf57806318160ddd1461030857806323b872dd1461033157806326976e3f1461039257806327e235e3146103e7578063313ce56714610434578063353907141461045d5780633eaaf86b146104865780633f4ba83a146104af57806359bf1abe146104c45780635c658165146105155780635c975abb1461058157806370a08231146105ae5780638456cb59146105fb578063893d20e8146106105780638da5cb5b1461066557806395d89b41146106ba578063a9059cbb14610748578063c0324c771461078a578063cc872b66146107b6578063db006a75146107d9578063dd62ed3e146107fc578063dd644f7214610868578063e47d606014610891578063e4997dc5146108e2578063e5b5019a1461091b578063f2fde38b14610944578063f3bdc2281461097d575b600080fd5b34156101a457600080fd5b6101ac6109b6565b6040518080602001828103825283818151815260200191508051906020019080838360005b838110156101ec5780820151818401526020810190506101d1565b50505050905090810190601f1680156102195780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b341561023257600080fd5b61025e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610a54565b005b341561026b57600080fd5b6102a0600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091908035906020019091905050610b71565b005b34156102ad57600080fd5b6102b5610cbf565b604051808215151515815260200191505060405180910390f35b34156102da57600080fd5b610306600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610cd2565b005b341561031357600080fd5b61031b610deb565b6040518082815260200191505060405180910390f35b341561033c57600080fd5b610390600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff16906020019091908035906020019091905050610ebb565b005b341561039d57600080fd5b6103a561109b565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b34156103f257600080fd5b61041e600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506110c1565b6040518082815260200191505060405180910390f35b341561043f57600080fd5b6104476110d9565b6040518082815260200191505060405180910390f35b341561046857600080fd5b6104706110df565b6040518082815260200191505060405180910390f35b341561049157600080fd5b6104996110e5565b6040518082815260200191505060405180910390f35b34156104ba57600080fd5b6104c26110eb565b005b34156104cf57600080fd5b6104fb600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506111a9565b604051808215151515815260200191505060405180910390f35b341561052057600080fd5b61056b600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff169060200190919050506111ff565b6040518082815260200191505060405180910390f35b341561058c57600080fd5b610594611224565b604051808215151515815260200191505060405180910390f35b34156105b957600080fd5b6105e5600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611237565b6040518082815260200191505060405180910390f35b341561060657600080fd5b61060e611346565b005b341561061b57600080fd5b610623611406565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561067057600080fd5b61067861142f565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b34156106c557600080fd5b6106cd611454565b6040518080602001828103825283818151815260200191508051906020019080838360005b8381101561070d5780820151818401526020810190506106f2565b50505050905090810190601f16801561073a5780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b341561075357600080fd5b610788600480803573ffffffffffffffffffffffffffffffffffffffff169060200190919080359060200190919050506114f2565b005b341561079557600080fd5b6107b4600480803590602001909190803590602001909190505061169c565b005b34156107c157600080fd5b6107d76004808035906020019091905050611781565b005b34156107e457600080fd5b6107fa6004808035906020019091905050611978565b005b341561080757600080fd5b610852600480803573ffffffffffffffffffffffffffffffffffffffff1690602001909190803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611b0b565b6040518082815260200191505060405180910390f35b341561087357600080fd5b61087b611c50565b6040518082815260200191505060405180910390f35b341561089c57600080fd5b6108c8600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611c56565b604051808215151515815260200191505060405180910390f35b34156108ed57600080fd5b610919600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611c76565b005b341561092657600080fd5b61092e611d8f565b6040518082815260200191505060405180910390f35b341561094f57600080fd5b61097b600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611db3565b005b341561098857600080fd5b6109b4600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050611e88565b005b60078054600181600116156101000203166002900480601f016020809104026020016040519081016040528092919081815260200182805460018160011615610100020316600290048015610a4c5780601f10610a2157610100808354040283529160200191610a4c565b820191906000526020600020905b815481529060010190602001808311610a2f57829003601f168201915b505050505081565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515610aaf57600080fd5b6001600a60146101000a81548160ff02191690831515021790555080600a60006101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055507fcc358699805e9a8b7f77b522628c7cb9abd07d9efb86b6fb616af1609036a99e81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b604060048101600036905010151515610b8957600080fd5b600a60149054906101000a900460ff1615610caf57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1663aee92d333385856040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050600060405180830381600087803b1515610c9657600080fd5b6102c65a03f11515610ca757600080fd5b505050610cba565b610cb9838361200c565b5b505050565b600a60149054906101000a900460ff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515610d2d57600080fd5b6001600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060006101000a81548160ff0219169083151502179055507f42e160154868087d6bfdc0ca23d96a1c1cfa32f1b72ba9ba27b69b98a0d819dc81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b6000600a60149054906101000a900460ff1615610eb257600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166318160ddd6000604051602001526040518163ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401602060405180830381600087803b1515610e9057600080fd5b6102c65a03f11515610ea157600080fd5b505050604051805190509050610eb8565b60015490505b90565b600060149054906101000a900460ff16151515610ed757600080fd5b600660008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff16151515610f3057600080fd5b600a60149054906101000a900460ff161561108a57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16638b477adb338585856040518563ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001828152602001945050505050600060405180830381600087803b151561107157600080fd5b6102c65a03f1151561108257600080fd5b505050611096565b6110958383836121a9565b5b505050565b600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b60026020528060005260406000206000915090505481565b60095481565b60045481565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614151561114657600080fd5b600060149054906101000a900460ff16151561116157600080fd5b60008060146101000a81548160ff0219169083151502179055507f7805862f689e2f13df9f062ff482ad3ad112aca9e0847911ed832e158c525b3360405160405180910390a1565b6000600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff169050919050565b6005602052816000526040600020602052806000526040600020600091509150505481565b600060149054906101000a900460ff1681565b6000600a60149054906101000a900460ff161561133557600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166370a08231836000604051602001526040518263ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001915050602060405180830381600087803b151561131357600080fd5b6102c65a03f1151561132457600080fd5b505050604051805190509050611341565b61133e82612650565b90505b919050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156113a157600080fd5b600060149054906101000a900460ff161515156113bd57600080fd5b6001600060146101000a81548160ff0219169083151502179055507f6985a02210a168e66602d3235cb6db0e70f92b3ba4d376a33c0f3d9434bff62560405160405180910390a1565b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b60088054600181600116156101000203166002900480601f0160208091040260200160405190810160405280929190818152602001828054600181600116156101000203166002900480156114ea5780601f106114bf576101008083540402835291602001916114ea565b820191906000526020600020905b8154815290600101906020018083116114cd57829003601f168201915b505050505081565b600060149054906101000a900460ff1615151561150e57600080fd5b600660003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff1615151561156757600080fd5b600a60149054906101000a900460ff161561168d57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16636e18980a3384846040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050600060405180830381600087803b151561167457600080fd5b6102c65a03f1151561168557600080fd5b505050611698565b6116978282612699565b5b5050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156116f757600080fd5b60148210151561170657600080fd5b60328110151561171557600080fd5b81600381905550611734600954600a0a82612a0190919063ffffffff16565b6004819055507fb044a1e409eac5c48e5af22d4af52670dd1a99059537a78b31b48c6500a6354e600354600454604051808381526020018281526020019250505060405180910390a15050565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156117dc57600080fd5b60015481600154011115156117f057600080fd5b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205481600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054011115156118c057600080fd5b80600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008282540192505081905550806001600082825401925050819055507fcb8241adb0c3fdb35b70c24ce35c5eb0c17af7431c99f827d44a445ca624176a816040518082815260200191505060405180910390a150565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415156119d357600080fd5b80600154101515156119e457600080fd5b80600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205410151515611a5357600080fd5b8060016000828254039250508190555080600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020600082825403925050819055507f702d5967f45f6513a38ffc42d6ba9bf230bd40e8f53b16363c7eb4fd2deb9a44816040518082815260200191505060405180910390a150565b6000600a60149054906101000a900460ff1615611c3d57600a60009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1663dd62ed3e84846000604051602001526040518363ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200192505050602060405180830381600087803b1515611c1b57600080fd5b6102c65a03f11515611c2c57600080fd5b505050604051805190509050611c4a565b611c478383612a3c565b90505b92915050565b60035481565b60066020528060005260406000206000915054906101000a900460ff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611cd157600080fd5b6000600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060006101000a81548160ff0219169083151502179055507fd7e9ec6e6ecd65492dce6bf513cd6867560d49544421d0783ddf06e76c24470c81604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a150565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611e0e57600080fd5b600073ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff16141515611e8557806000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055505b50565b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16141515611ee557600080fd5b600660008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060009054906101000a900460ff161515611f3d57600080fd5b611f4682611237565b90506000600260008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002081905550806001600082825403925050819055507f61e6e66b0d6339b2980aecc6ccc0039736791f0ccde9ed512e789a7fbdd698c68282604051808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019250505060405180910390a15050565b60406004810160003690501015151561202457600080fd5b600082141580156120b257506000600560003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205414155b1515156120be57600080fd5b81600560003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055508273ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040518082815260200191505060405180910390a3505050565b60008060006060600481016000369050101515156121c657600080fd5b600560008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054935061226e61271061226060035488612a0190919063ffffffff16565b612ac390919063ffffffff16565b92506004548311156122805760045492505b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84101561233c576122bb8585612ade90919063ffffffff16565b600560008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055505b61234f8386612ade90919063ffffffff16565b91506123a385600260008a73ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612ade90919063ffffffff16565b600260008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000208190555061243882600260008973ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000208190555060008311156125e2576124f783600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168773ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef856040518082815260200191505060405180910390a35b8573ffffffffffffffffffffffffffffffffffffffff168773ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040518082815260200191505060405180910390a350505050505050565b6000600260008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b6000806040600481016000369050101515156126b457600080fd5b6126dd6127106126cf60035487612a0190919063ffffffff16565b612ac390919063ffffffff16565b92506004548311156126ef5760045492505b6127028385612ade90919063ffffffff16565b915061275684600260003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612ade90919063ffffffff16565b600260003373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506127eb82600260008873ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008773ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000831115612995576128aa83600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054612af790919063ffffffff16565b600260008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020819055506000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef856040518082815260200191505060405180910390a35b8473ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef846040518082815260200191505060405180910390a35050505050565b6000806000841415612a165760009150612a35565b8284029050828482811515612a2757fe5b04141515612a3157fe5b8091505b5092915050565b6000600560008473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054905092915050565b6000808284811515612ad157fe5b0490508091505092915050565b6000828211151515612aec57fe5b818303905092915050565b6000808284019050838110151515612b0b57fe5b80915050929150505600a165627a7a72305820b998c49c782be6163974806b4787b7c008b8b8df9199674cea8c302ddfba7ee10029",
  hex:decode(HexCode).


evm_apis_test(Config) ->
  {endless_addr,EAddr}=proplists:lookup(endless_addr,Config),
  {endless_addr_pk,EPriv}=proplists:lookup(endless_addr_pk,Config),
%
  ?assertMatch(true, is_binary(EAddr)),
  ?assertMatch(true, is_binary(EPriv)),
  Priv = get_wallet_priv_key(),
  {ok,Node}=tpapi2:connect(get_base_url()),

  {ok, TMy1Addr}= new_wallet_async(Node),
  {ok, TMy2Addr}= new_wallet_async(Node),
  {ok, TSkAddr}= new_wallet_async(Node),
  {ok, SkAddr}= wallet_async_fin(Node, TSkAddr),
  {ok, My1Addr}= wallet_async_fin(Node, TMy1Addr),
  {ok, My2Addr}= wallet_async_fin(Node, TMy2Addr),
  
  {ok,Seq}=tpapi2:get_seq(Node, EAddr),
  logger("seq for wallet ~p is ~p ~n", [EAddr, Seq]),

  io:format("New SK address ~p 0x~s ~s~n",[SkAddr,hex:encode(SkAddr),naddress:encode(SkAddr)]),
  {ok,TxId0} = make_transaction(Node,EAddr, SkAddr, Seq+1, <<"FTT">>,
                                 1000000, <<"hello to EVM">>, EPriv, [nowait]),
  {ok,TxId1} = make_transaction(Node,EAddr, SkAddr, Seq+2, <<"SK">>,
                                 200, <<"Few SK 4 U">>, EPriv, [nowait]),
  {ok,TxId2} = make_transaction(Node,EAddr, My1Addr, Seq+3, <<"FTT">>,
                                 100000, <<"hello to EVM">>, EPriv, [nowait]),
  {ok,TxId2s} = make_transaction(Node,EAddr, My1Addr, Seq+4, <<"SK">>,
                                 100, <<"SK 4 test">>, EPriv, [nowait]),
  {ok,TxId3} = make_transaction(Node,EAddr, My2Addr, Seq+5, <<"FTT">>,
                                 100000, <<"hello to EVM">>, EPriv, [nowait]),
  {ok,TxId3s} = make_transaction(Node,EAddr, My2Addr, Seq+6, <<"SK">>,
                                 100, <<"SK 4 test">>, EPriv, [nowait]),

  logger("TxId0: ~p", [TxId0]),
  logger("TxId1: ~p", [TxId1]),
  logger("TxId2: ~p", [TxId2]),
  logger("TxId3: ~p", [TxId3]),
  
  BaseFile=filename:join(
             proplists:get_value("PWD",os:env(),"."),
             "examples/evm_builtin/build/checkSig"
            ),
  {ok,HexBin} = file:read_file(BaseFile++".bin"),
  ABI=contract_evm_abi:parse_abifile(BaseFile++".abi"),
  Code=hex:decode(hd(binary:split(HexBin,<<"\n">>))),

  DeployTx=tx:pack(
             tx:sign(
             tx:construct_tx(
               #{ver=>2,
                 kind=>deploy,
                 from=>SkAddr,
                 seq=>os:system_time(millisecond),
                 t=>os:system_time(millisecond),
                 payload=>[#{purpose=>gas, amount=>150000, cur=><<"FTT">>}],
                 txext=>#{ "code"=> Code, "vm" => "evm" }
                }
              ),Priv)),

  {ok, #{<<"txid">> := _DTxID1, <<"block">>:=_Blkid1}=DeployRes} = tpapi2:submit_tx(Node, DeployTx),
  %io:format("Deploy txid ~p~n~p~n",[DTxID1, DeployRes]),
  ?assertMatch(#{<<"ok">> := true}, DeployRes),

  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId2, erlang:system_time(second)+10),
  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId3, erlang:system_time(second)+2),
  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId2s, erlang:system_time(second)+2),
  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId3s, erlang:system_time(second)+2),
  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId1, erlang:system_time(second)+2),
  {ok, #{<<"block">> := _, <<"ok">> := true}} = tpapi2:wait_tx(Node, TxId0, erlang:system_time(second)+2),


  CallTx1=tx:pack(
            tx:sign(
              tx:sign(
                tx:construct_tx(
                  #{ver=>2,
                    kind=>generic,
                    from=>My1Addr,
                    to=>SkAddr,
                    seq=>1,
                    t=>os:system_time(millisecond)-1,
                    payload=>[#{purpose=>gas, amount=>10000, cur=><<"FTT">>}],
                    call=>#{
                            args=>[],
                            function => "setAddr()"
                           }
                   }
                 ),Priv),
              hex:decode(<<"302E020100300506032B657004220420077A31031D901BA9"
                           "78D9D258166FE03FC1399FF718AE09259341E4B54AA3403A">>)
             )
           ),

  CallTx2=tx:pack(
            tx:sign(
              tx:sign(
                tx:construct_tx(
                  #{ver=>2,
                    kind=>generic,
                    from=>My2Addr,
                    to=>SkAddr,
                    seq=>1,
                    t=>os:system_time(millisecond)-1,
                    payload=>[#{purpose=>gas, amount=>10000, cur=><<"FTT">>}],
                    call=>#{
                            args=>[],
                            function => "setAddr()"
                           }
                   }
                 ),Priv),
              hex:decode(
                <<"302E020100300506032B657004220420440521F8B059A5D6"
                  "4AB83DC2AF5C955D73A81D29BFBA1278861053449213F5F7">>
               )
             )
           ),
  CallTxF=tx:pack(
            tx:sign(
              tx:construct_tx(
                #{ver=>2,
                  kind=>generic,
                  to=>SkAddr,
                  from=>SkAddr,
                  seq=>os:system_time(millisecond),
                  t=>os:system_time(millisecond),
                  payload=>[#{purpose=>gas, amount=>10000, cur=><<"FTT">>}],
                  call=>#{
                          args=>[],
                          function => "blockCheck()"
                         }
                 }
               ),Priv)
           ),

  {ok, TxID2a} = tpapi2:submit_tx(Node, CallTx1, [nowait]),
  {ok, TxID2b} = tpapi2:submit_tx(Node, CallTx2, [nowait]),
  {ok, TxIDCall} = tpapi2:submit_tx(Node, CallTxF, [nowait]),
  io:format("TxID2a: ~p~n",[TxID2a]),
  io:format("TxID2b: ~p~n",[TxID2b]),
  io:format("TxIDCall: ~p~n",[TxIDCall]),
  {ok, #{<<"block">>:=BlkId1}=Status2} = tpapi2:wait_tx(Node,
                                                        TxIDCall,
                                                        erlang:system_time(second)+50),
  {ok, #{<<"block">>:=BlkId2}=ResTx2a} = tpapi2:wait_tx(Node,
                                                        TxID2a,
                                                        erlang:system_time(second)+20),
  ?assertMatch({ok, #{<<"block">>:=_}},
               tpapi2:wait_tx(Node,
                              TxID2b,
                              erlang:system_time(second)+2)),
  %?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
  io:format("call res ~p~n",[Status2]),
  io:format("call res2a ~p~n",[ResTx2a]),
  io:format("call Blkid ~p / ~p~n",[BlkId2, BlkId1]),
  timer:sleep(100),
  {ok,#{<<"logs">>:=R}}=tpapi2:logs(Node, hex:decode(BlkId2)),
  display_logs(R, ABI),
  if(BlkId1 =/= BlkId2) ->
      {ok,#{<<"logs">>:=R2}}=tpapi2:logs(Node, hex:decode(BlkId1)),
      display_logs(R2, ABI);
    true -> ok
  end,

  io:format("New SK address ~p 0x~s ~s~n",[SkAddr,hex:encode(SkAddr),naddress:encode(SkAddr)]),
  %#{bals:=Bals}=tpapi:get_fullblock(Blkid1,get_base_url()),
  gun:close(Node),
  ok.

display_logs(Log, ABI) ->
  Events=contract_evm_abi:sig_events(ABI),

  DoLog = fun (BBin) ->
              case msgpack:unpack(BBin) of
                {ok,[_,<<"evm">>,_,_,DABI,[Arg]]} ->
                  case lists:keyfind(Arg,2,Events) of
                    false ->
                      {DABI,Arg};
                    {EvName,_,EvABI}->
                      {EvName,contract_evm_abi:decode_abi(DABI,EvABI)}
                  end;
                {ok,Any} ->
                  Any
              end
          end,
  [ io:format("Logs ~p~n",[ DoLog(LL)]) || LL <- Log ].

deployless_run_test(Config) ->
  {ok,Node}=tpapi2:connect(get_base_url()),
  {endless_addr,EAddr}=proplists:lookup(endless_addr,Config),
  {endless_addr_pk,EPriv}=proplists:lookup(endless_addr_pk,Config),
  Code = eevm_asm:asm(
           [{push,1,0},
            sload,
            {push,1,1},
            add,
            {dup,1},
            {push,1,0},
            sstore,
            {push,1,0},
            mstore,
            calldatasize,
            {dup,1},
            {push,1,0},
            {push,1,0},
            calldatacopy,
            {push,1,0},
            return]
          ),

  {ok,Seq}=tpapi2:get_seq(Node, EAddr),
  Tx=tx:sign(
    tx:construct_tx(#{
                      ver=>2,
                      kind=>generic,
                      from=>EAddr,
                      to=>EAddr,
                      call=>#{
                              function => "test()", args => []
                             },
                      payload=>[
                                #{purpose=>gas, amount=>55300, cur=><<"FTT">>}
                               ],
                      seq=>Seq+1,
                      txext => #{
                                 "vm" => "evm",
                                 "code" => Code
                                },
                      t=>os:system_time(millisecond)
                     }), EPriv),
  {ok, #{<<"txid">> := _TxID, <<"block">>:=BlkID}=Status} = tpapi2:submit_tx(Node, Tx),
  {ok,#{bals:=BlkBal}}=tpapi2:block(Node,hex:decode(BlkID)),
  [
   ?assertMatch(#{state := #{<<0>> := _}},maps:get(EAddr,BlkBal)),
   ?assertMatch(4171824493,maps:get(<<"retval">>,Status,undefined))
  ].

