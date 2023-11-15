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
          evm_erc721_test,
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

  {ok, #{<<"txid">> := TxID2, <<"block">>:=Blkid2}=Status2} = tpapi2:submit_tx(Node, GenTx),
  io:format("ERC20 transfer txid ~p~n",[TxID2]),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
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
  {ok, #{<<"txid">> := TxID, <<"block">>:=BlkID}=Status} = tpapi2:submit_tx(Node, Tx),
  {ok,#{bals:=BlkBal}}=tpapi2:block(Node,hex:decode(BlkID)),
  [
   ?assertMatch(#{state := #{<<0>> := _}},maps:get(EAddr,BlkBal)),
   ?assertMatch(4171824493,maps:get(<<"retval">>,Status,undefined))
  ].


evm_erc721_test(Config) ->
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

  Code=erc721_code_1(),

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

  {ok, #{<<"txid">> := TxID1, <<"res">>:=TxID1Res, <<"block">>:=TxID1Blk}} = tpapi2:submit_tx(Node, DeployTx),
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

  {ok, #{<<"txid">> := TxID2, <<"block">>:=Blkid2}=Status2} = tpapi2:submit_tx(Node, GenTx),
  io:format("ERC721 transfer txid ~p in block ~p~n",[TxID2,Blkid2]),
  ?assertMatch(#{<<"res">> := <<"ok">>}, Status2),
  gun:close(Node),

  #{bals:=Bals}=tpapi:get_fullblock(TxID1Blk,get_base_url()),
  Bals.


erc721_code_1() ->
  hex:decode("60806040523480156200001157600080fd5b506040518060400160405280600781526020016626bcaa37b5b2b760c91b815250604051806040016040528060038152602001624d544b60e81b81525081600090816200005f919062000156565b5060016200006e828262000156565b505050620000a762000085620000ad60201b60201c565b600b80546001600160a01b0319166001600160a01b0392909216919091179055565b62000222565b3390565b634e487b7160e01b600052604160045260246000fd5b600181811c90821680620000dc57607f821691505b602082108103620000fd57634e487b7160e01b600052602260045260246000fd5b50919050565b601f8211156200015157600081815260208120601f850160051c810160208610156200012c5750805b601f850160051c820191505b818110156200014d5782815560010162000138565b5050505b505050565b81516001600160401b03811115620001725762000172620000b1565b6200018a81620001838454620000c7565b8462000103565b602080601f831160018114620001c25760008415620001a95750858301515b600019600386901b1c1916600185901b1785556200014d565b600085815260208120601f198616915b82811015620001f357888601518255948401946001909101908401620001d2565b5085821015620002125787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b611cec80620002326000396000f3fe608060405234801561001057600080fd5b506004361061012c5760003560e01c806370a08231116100ad578063b88d4fde11610071578063b88d4fde14610266578063c87b56dd14610279578063d204c45e1461028c578063e985e9c51461029f578063f2fde38b146102db57600080fd5b806370a082311461021f578063715018a6146102325780638da5cb5b1461023a57806395d89b411461024b578063a22cb4651461025357600080fd5b806323b872dd116100f457806323b872dd146101c05780632f745c59146101d357806342842e0e146101e65780634f6ccce7146101f95780636352211e1461020c57600080fd5b806301ffc9a71461013157806306fdde0314610159578063081812fc1461016e578063095ea7b31461019957806318160ddd146101ae575b600080fd5b61014461013f3660046116a5565b6102ee565b60405190151581526020015b60405180910390f35b6101616102ff565b6040516101509190611712565b61018161017c366004611725565b610391565b6040516001600160a01b039091168152602001610150565b6101ac6101a736600461175a565b6103b8565b005b6008545b604051908152602001610150565b6101ac6101ce366004611784565b6104d2565b6101b26101e136600461175a565b610503565b6101ac6101f4366004611784565b610599565b6101b2610207366004611725565b6105b4565b61018161021a366004611725565b610647565b6101b261022d3660046117c0565b6106a7565b6101ac61072d565b600b546001600160a01b0316610181565b610161610741565b6101ac6102613660046117db565b610750565b6101ac6102743660046118a3565b61075f565b610161610287366004611725565b610797565b6101ac61029a36600461191f565b6107a2565b6101446102ad366004611981565b6001600160a01b03918216600090815260056020908152604080832093909416825291909152205460ff1690565b6101ac6102e93660046117c0565b6107d9565b60006102f982610852565b92915050565b60606000805461030e906119b4565b80601f016020809104026020016040519081016040528092919081815260200182805461033a906119b4565b80156103875780601f1061035c57610100808354040283529160200191610387565b820191906000526020600020905b81548152906001019060200180831161036a57829003601f168201915b5050505050905090565b600061039c82610877565b506000908152600460205260409020546001600160a01b031690565b60006103c382610647565b9050806001600160a01b0316836001600160a01b0316036104355760405162461bcd60e51b815260206004820152602160248201527f4552433732313a20617070726f76616c20746f2063757272656e74206f776e656044820152603960f91b60648201526084015b60405180910390fd5b336001600160a01b0382161480610451575061045181336102ad565b6104c35760405162461bcd60e51b815260206004820152603d60248201527f4552433732313a20617070726f76652063616c6c6572206973206e6f7420746f60448201527f6b656e206f776e6572206f7220617070726f76656420666f7220616c6c000000606482015260840161042c565b6104cd83836108d6565b505050565b6104dc3382610944565b6104f85760405162461bcd60e51b815260040161042c906119ee565b6104cd8383836109c3565b600061050e836106a7565b82106105705760405162461bcd60e51b815260206004820152602b60248201527f455243373231456e756d657261626c653a206f776e657220696e646578206f7560448201526a74206f6620626f756e647360a81b606482015260840161042c565b506001600160a01b03919091166000908152600660209081526040808320938352929052205490565b6104cd8383836040518060200160405280600081525061075f565b60006105bf60085490565b82106106225760405162461bcd60e51b815260206004820152602c60248201527f455243373231456e756d657261626c653a20676c6f62616c20696e646578206f60448201526b7574206f6620626f756e647360a01b606482015260840161042c565b6008828154811061063557610635611a3b565b90600052602060002001549050919050565b6000818152600260205260408120546001600160a01b0316806102f95760405162461bcd60e51b8152602060048201526018602482015277115490cdcc8c4e881a5b9d985b1a59081d1bdad95b88125160421b604482015260640161042c565b60006001600160a01b0382166107115760405162461bcd60e51b815260206004820152602960248201527f4552433732313a2061646472657373207a65726f206973206e6f7420612076616044820152683634b21037bbb732b960b91b606482015260840161042c565b506001600160a01b031660009081526003602052604090205490565b610735610b34565b61073f6000610b8e565b565b60606001805461030e906119b4565b61075b338383610bb0565b5050565b6107693383610944565b6107855760405162461bcd60e51b815260040161042c906119ee565b61079184848484610c7e565b50505050565b60606102f982610cb1565b6107aa610b34565b60006107b5600c5490565b90506107c5600c80546001019055565b6107cf8382610db9565b6104cd8183610dd3565b6107e1610b34565b6001600160a01b0381166108465760405162461bcd60e51b815260206004820152602660248201527f4f776e61626c653a206e6577206f776e657220697320746865207a65726f206160448201526564647265737360d01b606482015260840161042c565b61084f81610b8e565b50565b60006001600160e01b03198216632483248360e11b14806102f957506102f982610e9e565b6000818152600260205260409020546001600160a01b031661084f5760405162461bcd60e51b8152602060048201526018602482015277115490cdcc8c4e881a5b9d985b1a59081d1bdad95b88125160421b604482015260640161042c565b600081815260046020526040902080546001600160a01b0319166001600160a01b038416908117909155819061090b82610647565b6001600160a01b03167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b92560405160405180910390a45050565b60008061095083610647565b9050806001600160a01b0316846001600160a01b0316148061099757506001600160a01b0380821660009081526005602090815260408083209388168352929052205460ff165b806109bb5750836001600160a01b03166109b084610391565b6001600160a01b0316145b949350505050565b826001600160a01b03166109d682610647565b6001600160a01b0316146109fc5760405162461bcd60e51b815260040161042c90611a51565b6001600160a01b038216610a5e5760405162461bcd60e51b8152602060048201526024808201527f4552433732313a207472616e7366657220746f20746865207a65726f206164646044820152637265737360e01b606482015260840161042c565b610a6b8383836001610ec3565b826001600160a01b0316610a7e82610647565b6001600160a01b031614610aa45760405162461bcd60e51b815260040161042c90611a51565b600081815260046020908152604080832080546001600160a01b03199081169091556001600160a01b0387811680865260038552838620805460001901905590871680865283862080546001019055868652600290945282852080549092168417909155905184937fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef91a4505050565b600b546001600160a01b0316331461073f5760405162461bcd60e51b815260206004820181905260248201527f4f776e61626c653a2063616c6c6572206973206e6f7420746865206f776e6572604482015260640161042c565b600b80546001600160a01b0319166001600160a01b0392909216919091179055565b816001600160a01b0316836001600160a01b031603610c115760405162461bcd60e51b815260206004820152601960248201527f4552433732313a20617070726f766520746f2063616c6c657200000000000000604482015260640161042c565b6001600160a01b03838116600081815260056020908152604080832094871680845294825291829020805460ff191686151590811790915591519182527f17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31910160405180910390a3505050565b610c898484846109c3565b610c9584848484610ecf565b6107915760405162461bcd60e51b815260040161042c90611a96565b6060610cbc82610877565b6000828152600a602052604081208054610cd5906119b4565b80601f0160208091040260200160405190810160405280929190818152602001828054610d01906119b4565b8015610d4e5780601f10610d2357610100808354040283529160200191610d4e565b820191906000526020600020905b815481529060010190602001808311610d3157829003601f168201915b505050505090506000610d6c60408051602081019091526000815290565b90508051600003610d7e575092915050565b815115610db0578082604051602001610d98929190611ae8565b60405160208183030381529060405292505050919050565b6109bb84610fd0565b61075b828260405180602001604052806000815250611044565b6000828152600260205260409020546001600160a01b0316610e4e5760405162461bcd60e51b815260206004820152602e60248201527f45524337323155524953746f726167653a2055524920736574206f66206e6f6e60448201526d32bc34b9ba32b73a103a37b5b2b760911b606482015260840161042c565b6000828152600a60205260409020610e668282611b65565b506040518281527ff8e1a15aba9398e019f0b49df1a4fde98ee17ae345cb5f6b5e2c27f5033e8ce79060200160405180910390a15050565b60006001600160e01b0319821663780e9d6360e01b14806102f957506102f982611077565b610791848484846110c7565b60006001600160a01b0384163b15610fc557604051630a85bd0160e11b81526001600160a01b0385169063150b7a0290610f13903390899088908890600401611c25565b6020604051808303816000875af1925050508015610f4e575060408051601f3d908101601f19168201909252610f4b91810190611c62565b60015b610fab573d808015610f7c576040519150601f19603f3d011682016040523d82523d6000602084013e610f81565b606091505b508051600003610fa35760405162461bcd60e51b815260040161042c90611a96565b805181602001fd5b6001600160e01b031916630a85bd0160e11b1490506109bb565b506001949350505050565b6060610fdb82610877565b6000610ff260408051602081019091526000815290565b90506000815111611012576040518060200160405280600081525061103d565b8061101c846111fb565b60405160200161102d929190611ae8565b6040516020818303038152906040525b9392505050565b61104e838361128e565b61105b6000848484610ecf565b6104cd5760405162461bcd60e51b815260040161042c90611a96565b60006001600160e01b031982166380ac58cd60e01b14806110a857506001600160e01b03198216635b5e139f60e01b145b806102f957506301ffc9a760e01b6001600160e01b03198316146102f9565b60018111156111365760405162461bcd60e51b815260206004820152603560248201527f455243373231456e756d657261626c653a20636f6e7365637574697665207472604482015274185b9cd9995c9cc81b9bdd081cdd5c1c1bdc9d1959605a1b606482015260840161042c565b816001600160a01b0385166111925761118d81600880546000838152600960205260408120829055600182018355919091527ff3f7a9fe364faab93b216da50a3214154f22a0a2b415b23a84c8169e8b636ee30155565b6111b5565b836001600160a01b0316856001600160a01b0316146111b5576111b58582611427565b6001600160a01b0384166111d1576111cc816114c4565b6111f4565b846001600160a01b0316846001600160a01b0316146111f4576111f48482611573565b5050505050565b60606000611208836115b7565b600101905060008167ffffffffffffffff81111561122857611228611817565b6040519080825280601f01601f191660200182016040528015611252576020820181803683370190505b5090508181016020015b600019016f181899199a1a9b1b9c1cb0b131b232b360811b600a86061a8153600a850494508461125c57509392505050565b6001600160a01b0382166112e45760405162461bcd60e51b815260206004820181905260248201527f4552433732313a206d696e7420746f20746865207a65726f2061646472657373604482015260640161042c565b6000818152600260205260409020546001600160a01b0316156113495760405162461bcd60e51b815260206004820152601c60248201527f4552433732313a20746f6b656e20616c7265616479206d696e74656400000000604482015260640161042c565b611357600083836001610ec3565b6000818152600260205260409020546001600160a01b0316156113bc5760405162461bcd60e51b815260206004820152601c60248201527f4552433732313a20746f6b656e20616c7265616479206d696e74656400000000604482015260640161042c565b6001600160a01b038216600081815260036020908152604080832080546001019055848352600290915280822080546001600160a01b0319168417905551839291907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef908290a45050565b60006001611434846106a7565b61143e9190611c7f565b600083815260076020526040902054909150808214611491576001600160a01b03841660009081526006602090815260408083208584528252808320548484528184208190558352600790915290208190555b5060009182526007602090815260408084208490556001600160a01b039094168352600681528383209183525290812055565b6008546000906114d690600190611c7f565b600083815260096020526040812054600880549394509092849081106114fe576114fe611a3b565b90600052602060002001549050806008838154811061151f5761151f611a3b565b600091825260208083209091019290925582815260099091526040808220849055858252812055600880548061155757611557611ca0565b6001900381819060005260206000200160009055905550505050565b600061157e836106a7565b6001600160a01b039093166000908152600660209081526040808320868452825280832085905593825260079052919091209190915550565b60008072184f03e93ff9f4daa797ed6e38ed64bf6a1f0160401b83106115f65772184f03e93ff9f4daa797ed6e38ed64bf6a1f0160401b830492506040015b6d04ee2d6d415b85acef81000000008310611622576d04ee2d6d415b85acef8100000000830492506020015b662386f26fc10000831061164057662386f26fc10000830492506010015b6305f5e1008310611658576305f5e100830492506008015b612710831061166c57612710830492506004015b6064831061167e576064830492506002015b600a83106102f95760010192915050565b6001600160e01b03198116811461084f57600080fd5b6000602082840312156116b757600080fd5b813561103d8161168f565b60005b838110156116dd5781810151838201526020016116c5565b50506000910152565b600081518084526116fe8160208601602086016116c2565b601f01601f19169290920160200192915050565b60208152600061103d60208301846116e6565b60006020828403121561173757600080fd5b5035919050565b80356001600160a01b038116811461175557600080fd5b919050565b6000806040838503121561176d57600080fd5b6117768361173e565b946020939093013593505050565b60008060006060848603121561179957600080fd5b6117a28461173e565b92506117b06020850161173e565b9150604084013590509250925092565b6000602082840312156117d257600080fd5b61103d8261173e565b600080604083850312156117ee57600080fd5b6117f78361173e565b91506020830135801515811461180c57600080fd5b809150509250929050565b634e487b7160e01b600052604160045260246000fd5b600067ffffffffffffffff8084111561184857611848611817565b604051601f8501601f19908116603f0116810190828211818310171561187057611870611817565b8160405280935085815286868601111561188957600080fd5b858560208301376000602087830101525050509392505050565b600080600080608085870312156118b957600080fd5b6118c28561173e565b93506118d06020860161173e565b925060408501359150606085013567ffffffffffffffff8111156118f357600080fd5b8501601f8101871361190457600080fd5b6119138782356020840161182d565b91505092959194509250565b6000806040838503121561193257600080fd5b61193b8361173e565b9150602083013567ffffffffffffffff81111561195757600080fd5b8301601f8101851361196857600080fd5b6119778582356020840161182d565b9150509250929050565b6000806040838503121561199457600080fd5b61199d8361173e565b91506119ab6020840161173e565b90509250929050565b600181811c908216806119c857607f821691505b6020821081036119e857634e487b7160e01b600052602260045260246000fd5b50919050565b6020808252602d908201527f4552433732313a2063616c6c6572206973206e6f7420746f6b656e206f776e6560408201526c1c881bdc88185c1c1c9bdd9959609a1b606082015260800190565b634e487b7160e01b600052603260045260246000fd5b60208082526025908201527f4552433732313a207472616e736665722066726f6d20696e636f72726563742060408201526437bbb732b960d91b606082015260800190565b60208082526032908201527f4552433732313a207472616e7366657220746f206e6f6e20455243373231526560408201527131b2b4bb32b91034b6b83632b6b2b73a32b960711b606082015260800190565b60008351611afa8184602088016116c2565b835190830190611b0e8183602088016116c2565b01949350505050565b601f8211156104cd57600081815260208120601f850160051c81016020861015611b3e5750805b601f850160051c820191505b81811015611b5d57828155600101611b4a565b505050505050565b815167ffffffffffffffff811115611b7f57611b7f611817565b611b9381611b8d84546119b4565b84611b17565b602080601f831160018114611bc85760008415611bb05750858301515b600019600386901b1c1916600185901b178555611b5d565b600085815260208120601f198616915b82811015611bf757888601518255948401946001909101908401611bd8565b5085821015611c155787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b6001600160a01b0385811682528416602082015260408101839052608060608201819052600090611c58908301846116e6565b9695505050505050565b600060208284031215611c7457600080fd5b815161103d8161168f565b818103818111156102f957634e487b7160e01b600052601160045260246000fd5b634e487b7160e01b600052603160045260246000fdfea2646970667358221220ea4a72632ce115f503d6c50a3d4101c513ce8fad749aba3736e148e3c457223664736f6c63430008120033").

erc721_code() ->
  base64:decode("YIBgQFI0gBViAAARV2AAgP1bUGBAUYBgQAFgQFKAYAeBUmAgAX9NeVRva2VuAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSUGBAUYBgQAFgQFKAYAOBUmAgAX9NVEsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSUIFgAJCBYgAAj5GQYgAEElZbUIBgAZCBYgAAoZGQYgAEElZbUFBQYgAAxGIAALhiAADKYCAbYCAcVltiAADSYCAbYCAcVltiAAT5VltgADOQUJBWW2AAYApgAJBUkGEBAAqQBHP//////////////////////////xaQUIFgCmAAYQEACoFUgXP//////////////////////////wIZFpCDc///////////////////////////FgIXkFVQgXP//////////////////////////xaBc///////////////////////////Fn+L4AecUxZZFBNEzR/QpPKEGUl/lyKj2q/jtBhva2RX4GBAUWBAUYCRA5CjUFBWW2AAgVGQUJGQUFZbf05Ie3EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYABSYEFgBFJgJGAA/Vt/Tkh7cQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgAFJgImAEUmAkYAD9W2AAYAKCBJBQYAGCFoBiAAIaV2B/ghaRUFtgIIIQgQNiAAIwV2IAAi9iAAHSVltbUJGQUFZbYACBkFCBYABSYCBgACCQUJGQUFZbYABgIGAfgwEEkFCRkFBWW2AAgoIbkFCSkVBQVltgAGAIgwJiAAKaf///////////////////////////////////////////gmIAAltWW2IAAqaGg2IAAltWW5VQgBmEFpNQgIYWhBeSUFBQk5JQUFBWW2AAgZBQkZBQVltgAIGQUJGQUFZbYABiAALzYgAC7WIAAueEYgACvlZbYgACyFZbYgACvlZbkFCRkFBWW2AAgZBQkZBQVltiAAMPg2IAAtJWW2IAAydiAAMegmIAAvpWW4SEVGIAAmhWW4JVUFBQUFZbYACQVltiAAM+YgADL1ZbYgADS4GEhGIAAwRWW1BQUFZbW4GBEBViAANzV2IAA2dgAIJiAAM0VltgAYEBkFBiAANRVltQUFZbYB+CERViAAPCV2IA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W4Bz//////////////////////////8WYQWiYQ0VVltz//////////////////////////8WFIBhBdFXUGEF0IFhBcthDRVWW2ELOVZbW2EGEFdgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEGB5BhKcRWW2BAUYCRA5D9W2EGGoODYQ0dVltQUFBWW2AAYAiAVJBQkFCQVlthBj1hBjdhDRVWW4JhDdZWW2EGfFdgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEGc5BhKlZWW2BAUYCRA5D9W2EGh4ODg2EOa1ZbUFBQVltgAGEGl4NhCNJWW4IQYQbYV2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYQbPkGEq6FZbYEBRgJEDkP1bYAZgAIRz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgYACDgVJgIAGQgVJgIAFgACBUkFCSkVBQVlthBzlhEWRWW2AAYQdFYAthEeJWW5BQYQdRYAthEfBWW2EHW4KCYRIGVltQUFZbYQd6g4ODYEBRgGAgAWBAUoBgAIFSUGEKb1ZbUFBQVlthB5BhB4phDRVWW4JhDdZWW2EHz1dgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEHxpBhKlZWW2BAUYCRA5D9W2EH2IFhEiRWW1BWW2AAYQflYQYfVluCEGEIJldgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEIHZBhK3pWW2BAUYCRA5D9W2AIgoFUgRBhCDpXYQg5YSuaVltbkGAAUmAgYAAgAVSQUJGQUFZbYACAYQhYg2ETclZbkFBgAHP//////////////////////////xaBc///////////////////////////FgNhCMlXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhCMCQYSwVVltgQFGAkQOQ/VuAkVBQkZBQVltgAIBz//////////////////////////8WgnP//////////////////////////xYDYQlCV2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYQk5kGEsp1ZbYEBRgJEDkP1bYANgAINz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgVJBQkZBQVlthCZFhEWRWW2EJm2AAYROvVltWW2AAYApgAJBUkGEBAAqQBHP//////////////////////////xaQUJBWW2BgYAGAVGEJ1pBhKI9WW4BgHwFgIICRBAJgIAFgQFGQgQFgQFKAkpGQgYFSYCABgoBUYQoCkGEoj1ZbgBVhCk9XgGAfEGEKJFdhAQCAg1QEAoNSkWAgAZFhCk9WW4IBkZBgAFJgIGAAIJBbgVSBUpBgAQGQYCABgIMRYQoyV4KQA2AfFoIBkVtQUFBQUJBQkFZbYQprYQpkYQ0VVluDg2EUdVZbUFBWW2EKgGEKemENFVZbg2EN1lZbYQq/V2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYQq2kGEqVlZbYEBRgJEDkP1bYQrLhISEhGEV4VZbUFBQUFZbYGBhCtyCYQzKVltgAGEK5mEWPVZbkFBgAIFREWELBldgQFGAYCABYEBSgGAAgVJQYQsxVluAYQsQhGEWVFZbYEBRYCABYQshkpGQYS0DVltgQFFgIIGDAwOBUpBgQFJbkVBQkZBQVltgAGAFYACEc///////////////////////////FnP//////////////////////////xaBUmAgAZCBUmAgAWAAIGAAg3P//////////////////////////xZz//////////////////////////8WgVJgIAGQgVJgIAFgACBgAJBUkGEBAAqQBGD/FpBQkpFQUFZbYQvVYRFkVltgAHP//////////////////////////xaBc///////////////////////////FgNhDERXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhDDuQYS2ZVltgQFGAkQOQ/VthDE2BYROvVltQVltgAH94Dp1jAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHv/////////////////////////////////////GRaCe/////////////////////////////////////8ZFhSAYQzDV1BhDMKCYRciVltbkFCRkFBWW2EM04FhGARWW2ENEldgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWENCZBhLBVWW2BAUYCRA5D9W1BWW2AAM5BQkFZbgWAEYACDgVJgIAGQgVJgIAFgACBgAGEBAAqBVIFz//////////////////////////8CGRaQg3P//////////////////////////xYCF5BVUICCc///////////////////////////FmENkINhCExWW3P//////////////////////////xZ/jFvh5evsfVvRT3FCfR6E890DFMD3sikeWyAKyMfDuSVgQFFgQFGAkQOQpFBQVltgAIBhDeKDYQhMVluQUIBz//////////////////////////8WhHP//////////////////////////xYUgGEOJFdQYQ4jgYVhCzlWW1uAYQ5iV1CDc///////////////////////////FmEOSoRhBMJWW3P//////////////////////////xYUW5FQUJKRUFBWW4Jz//////////////////////////8WYQ6LgmEITFZbc///////////////////////////FhRhDuFXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhDtiQYS4rVltgQFGAkQOQ/VtgAHP//////////////////////////xaCc///////////////////////////FgNhD1BXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhD0eQYS69VltgQFGAkQOQ/VthD12Dg4NgAWEYRVZbgnP//////////////////////////xZhD32CYQhMVltz//////////////////////////8WFGEP01dgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEPypBhLitWW2BAUYCRA5D9W2AEYACCgVJgIAGQgVJgIAFgACBgAGEBAAqBVJBz//////////////////////////8CGRaQVWABYANgAIVz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgYACCglQDklBQgZBVUGABYANgAIRz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgYACCglQBklBQgZBVUIFgAmAAg4FSYCABkIFSYCABYAAgYABhAQAKgVSBc///////////////////////////AhkWkINz//////////////////////////8WAheQVVCAgnP//////////////////////////xaEc///////////////////////////Fn/d8lKtG+LIm2nCsGj8N42qlSun8WPEoRYo9VpN9SOz72BAUWBAUYCRA5CkYRFfg4ODYAFhGFdWW1BQUFZbYRFsYQ0VVltz//////////////////////////8WYRGKYQmdVltz//////////////////////////8WFGER4FdgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWER15BhLylWW2BAUYCRA5D9W1ZbYACBYAABVJBQkZBQVltgAYFgAAFgAIKCVAGSUFCBkFVQUFZbYRIggoJgQFGAYCABYEBSgGAAgVJQYRhdVltQUFZbYABhEi+CYQhMVluQUGESP4FgAIRgAWEYRVZbYRJIgmEITFZbkFBgBGAAg4FSYCABkIFSYCABYAAgYABhAQAKgVSQc///////////////////////////AhkWkFVgAWADYACDc///////////////////////////FnP//////////////////////////xaBUmAgAZCBUmAgAWAAIGAAgoJUA5JQUIGQVVBgAmAAg4FSYCABkIFSYCABYAAgYABhAQAKgVSQc///////////////////////////AhkWkFWBYABz//////////////////////////8WgnP//////////////////////////xZ/3fJSrRviyJtpwrBo/DeNqpUrp/FjxKEWKPVaTfUjs+9gQFFgQFGAkQOQpGETboFgAIRgAWEYV1ZbUFBWW2AAYAJgAIOBUmAgAZCBUmAgAWAAIGAAkFSQYQEACpAEc///////////////////////////FpBQkZBQVltgAGAKYACQVJBhAQAKkARz//////////////////////////8WkFCBYApgAGEBAAqBVIFz//////////////////////////8CGRaQg3P//////////////////////////xYCF5BVUIFz//////////////////////////8WgXP//////////////////////////xZ/i+AHnFMWWRQTRM0f0KTyhBlJf5cio9qv47QYb2tkV+BgQFFgQFGAkQOQo1BQVluBc///////////////////////////FoNz//////////////////////////8WA2EU41dgQFF/CMN5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBUmAEAWEU2pBhL5VWW2BAUYCRA5D9W4BgBWAAhXP//////////////////////////xZz//////////////////////////8WgVJgIAGQgVJgIAFgACBgAIRz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgYABhAQAKgVSBYP8CGRaQgxUVAheQVVCBc///////////////////////////FoNz//////////////////////////8Wfxcwfqs5q2EH6ImYRa09Wb2WU/IA8iCSBInKK1k3aWwxg2BAUWEV1JGQYSNaVltgQFGAkQOQo1BQUFZbYRXshISEYQ5rVlthFfiEhISEYRi4VlthFjdXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhFi6QYTAnVltgQFGAkQOQ/VtQUFBQVltgYGBAUYBgIAFgQFKAYACBUlCQUJBWW2BgYABgAWEWY4RhGj9WWwGQUGAAgWf//////////4ERFWEWgldhFoFhJnJWW1tgQFGQgIJSgGAfAWAfGRZgIAGCAWBAUoAVYRa0V4FgIAFgAYICgDaDN4CCAZFQUJBQW1CQUGAAgmAgAYIBkFBbYAEVYRcXV4CAYAGQA5FQUH8wMTIzNDU2Nzg5YWJjZGVmAAAAAAAAAAAAAAAAAAAAAGAKhgYagVNgCoWBYRcLV2EXCmEwR1ZbWwSUUGAAhQNhFsJXW4GTUFBQUJGQUFZbYAB/gKxYzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB7/////////////////////////////////////xkWgnv/////////////////////////////////////GRYUgGEX7VdQf1teE58AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAe/////////////////////////////////////8ZFoJ7/////////////////////////////////////xkWFFuAYRf9V1BhF/yCYRuSVltbkFCRkFBWW2AAgHP//////////////////////////xZhGCaDYRNyVltz//////////////////////////8WFBWQUJGQUFZbYRhRhISEhGEb/FZbUFBQUFZbUFBQUFZbYRhng4NhHVpWW2EYdGAAhISEYRi4VlthGLNXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhGKqQYTAnVltgQFGAkQOQ/VtQUFBWW2AAYRjZhHP//////////////////////////xZhH3dWWxVhGjJXg3P//////////////////////////xZjFQt6AmEZAmENFVZbh4aGYEBRhWP/////FmDgG4FSYAQBYRkklJOSkZBhMMtWW2AgYEBRgIMDgWAAh1rxklBQUIAVYRlgV1BgQFE9YB8ZYB+CARaCAYBgQFJQgQGQYRldkZBhMSxWW2ABW2EZ4lc9gGAAgRRhGZBXYEBRkVBgHxlgPz0BFoIBYEBSPYJSPWAAYCCEAT5hGZVWW2BgkVBbUGAAgVEDYRnaV2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYRnRkGEwJ1ZbYEBRgJEDkP1bgFGBYCAB/VtjFQt6AmDgG3v/////////////////////////////////////GRaBe/////////////////////////////////////8ZFhSRUFBhGjdWW2ABkFBblJNQUFBQVltgAIBgAJBQehhPA+k/+fTap5ftbjjtZL9qHwEAAAAAAAAAAIMQYRqdV3oYTwPpP/n02qeX7W447WS/ah8BAAAAAAAAAACDgWEak1dhGpJhMEdWW1sEklBgQIEBkFBbbQTuLW1BW4Ws74EAAAAAgxBhGtpXbQTuLW1BW4Ws74EAAAAAg4FhGtBXYRrPYTBHVltbBJJQYCCBAZBQW2YjhvJvwQAAgxBhGwlXZiOG8m/BAACDgWEa/1dhGv5hMEdWW1sEklBgEIEBkFBbYwX14QCDEGEbMldjBfXhAIOBYRsoV2EbJ2EwR1ZbWwSSUGAIgQGQUFthJxCDEGEbV1dhJxCDgWEbTVdhG0xhMEdWW1sEklBgBIEBkFBbYGSDEGEbeldgZIOBYRtwV2Ebb2EwR1ZbWwSSUGACgQGQUFtgCoMQYRuJV2ABgQGQUFuAkVBQkZBQVltgAH8B/8mnAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHv/////////////////////////////////////GRaCe/////////////////////////////////////8ZFhSQUJGQUFZbYRwIhISEhGEfmlZbYAGBERVhHExXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhHEOQYTHLVltgQFGAkQOQ/VtgAIKQUGAAc///////////////////////////FoVz//////////////////////////8WA2Eck1dhHI6BYR+gVlthHNJWW4Nz//////////////////////////8WhXP//////////////////////////xYUYRzRV2Ec0IWCYR/pVltbW2AAc///////////////////////////FoRz//////////////////////////8WA2EdFFdhHQ+BYSFWVlthHVNWW4Rz//////////////////////////8WhHP//////////////////////////xYUYR1SV2EdUYSCYSInVltbW1BQUFBQVltgAHP//////////////////////////xaCc///////////////////////////FgNhHclXYEBRfwjDeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgVJgBAFhHcCQYTI3VltgQFGAkQOQ/VthHdKBYRgEVlsVYR4SV2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYR4JkGEyo1ZbYEBRgJEDkP1bYR4gYACDg2ABYRhFVlthHimBYRgEVlsVYR5pV2BAUX8Iw3mgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIFSYAQBYR5gkGEyo1ZbYEBRgJEDkP1bYAFgA2AAhHP//////////////////////////xZz//////////////////////////8WgVJgIAGQgVJgIAFgACBgAIKCVAGSUFCBkFVQgWACYACDgVJgIAGQgVJgIAFgACBgAGEBAAqBVIFz//////////////////////////8CGRaQg3P//////////////////////////xYCF5BVUICCc///////////////////////////FmAAc///////////////////////////Fn/d8lKtG+LIm2nCsGj8N42qlSun8WPEoRYo9VpN9SOz72BAUWBAUYCRA5CkYR9zYACDg2ABYRhXVltQUFZbYACAgnP//////////////////////////xY7EZBQkZBQVltQUFBQVltgCIBUkFBgCWAAg4FSYCABkIFSYCABYAAggZBVUGAIgZCAYAGBVAGAglWAkVBQYAGQA5BgAFJgIGAAIAFgAJCRkJGQkVBVUFZbYABgAWEf9oRhCNJWW2EgAJGQYTLyVluQUGAAYAdgAISBUmAgAZCBUmAgAWAAIFSQUIGBFGEg5VdgAGAGYACGc///////////////////////////FnP//////////////////////////xaBUmAgAZCBUmAgAWAAIGAAhIFSYCABkIFSYCABYAAgVJBQgGAGYACHc///////////////////////////FnP//////////////////////////xaBUmAgAZCBUmAgAWAAIGAAhIFSYCABkIFSYCABYAAggZBVUIFgB2AAg4FSYCABkIFSYCABYAAggZBVUFBbYAdgAISBUmAgAZCBUmAgAWAAIGAAkFVgBmAAhXP//////////////////////////xZz//////////////////////////8WgVJgIAGQgVJgIAFgACBgAIOBUmAgAZCBUmAgAWAAIGAAkFVQUFBQVltgAGABYAiAVJBQYSFqkZBhMvJWW5BQYABgCWAAhIFSYCABkIFSYCABYAAgVJBQYABgCIOBVIEQYSGaV2EhmWErmlZbW5BgAFJgIGAAIAFUkFCAYAiDgVSBEGEhvFdhIbthK5pWW1uQYABSYCBgACABgZBVUIFgCWAAg4FSYCABkIFSYCABYAAggZBVUGAJYACFgVJgIAGQgVJgIAFgACBgAJBVYAiAVIBhIgtXYSIKYTMmVltbYAGQA4GBkGAAUmAgYAAgAWAAkFWQVVBQUFBWW2AAYSIyg2EI0lZbkFCBYAZgAIVz//////////////////////////8Wc///////////////////////////FoFSYCABkIFSYCABYAAgYACDgVJgIAGQgVJgIAFgACCBkFVQgGAHYACEgVJgIAGQgVJgIAFgACCBkFVQUFBQVltgAGBAUZBQkFZbYACA/VtgAID9W2AAf/////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAghaQUJGQUFZbYSLvgWEiulZbgRRhIvpXYACA/VtQVltgAIE1kFBhIwyBYSLmVluSkVBQVltgAGAggoQDEhVhIyhXYSMnYSKwVltbYABhIzaEgoUBYSL9VluRUFCSkVBQVltgAIEVFZBQkZBQVlthI1SBYSM/VluCUlBQVltgAGAgggGQUGEjb2AAgwGEYSNLVluSkVBQVltgAIFRkFCRkFBWW2AAgoJSYCCCAZBQkpFQUFZbYABbg4EQFWEjr1eAggFRgYQBUmAggQGQUGEjlFZbYACEhAFSUFBQUFZbYABgHxlgH4MBFpBQkZBQVltgAGEj14JhI3VWW2Ej4YGFYSOAVluTUGEj8YGFYCCGAWEjkVZbYSP6gWEju1ZbhAGRUFCSkVBQVltgAGAgggGQUIGBA2AAgwFSYSQfgYRhI8xWW5BQkpFQUFZbYACBkFCRkFBWW2EkOoFhJCdWW4EUYSRFV2AAgP1bUFZbYACBNZBQYSRXgWEkMVZbkpFQUFZbYABgIIKEAxIVYSRzV2EkcmEisFZbW2AAYSSBhIKFAWEkSFZbkVBQkpFQUFZbYABz//////////////////////////+CFpBQkZBQVltgAGEktYJhJIpWW5BQkZBQVlthJMWBYSSqVluCUlBQVltgAGAgggGQUGEk4GAAgwGEYSS8VluSkVBQVlthJO+BYSSqVluBFGEk+ldgAID9W1BWW2AAgTWQUGElDIFhJOZWW5KRUFBWW2AAgGBAg4UDEhVhJSlXYSUoYSKw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").

