// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "src/ChainState.sol";
//import "src/GetTx.sol";

contract EvmCall is Test {
  function iToHex(bytes memory buffer) public pure returns (string memory) {
    // Fixed buffer size for hexadecimal convertion
    bytes memory converted = new bytes(buffer.length * 2);
    bytes memory _base = "0123456789abcdef";
    for (uint256 i = 0; i < buffer.length; i++) {
      converted[i * 2] = _base[uint8(buffer[i]) / _base.length];
      converted[i * 2 + 1] = _base[uint8(buffer[i]) % _base.length];
    }
    return string(converted);
  }
  function h2i(uint8 c1, uint8 c2) private pure returns(uint8){
    uint8 r0=0;
    if(c1>=0x30 && c1<=0x39){ r0+=(c1-0x30)*16;
    }else if(c1>=0x97 && c1<=0x102){ r0+=(c1-0x97+10)*16;
    }else if(c1>=0x65 && c1<=0x70){ r0+=(c1-0x65+10)*16;
    }

    if(c2>=0x30 && c2<=0x39){ r0+=(c2-0x30);
    }else if(c2>=0x97 && c2<=0x102){ r0+=(c2-0x97+10);
    }else if(c2>=0x65 && c2<=0x70){ r0+=(c2-0x65+10);
    }
    return r0;
  }
  function rpc_call(address addr, bytes memory reqd) public returns (bytes memory){
    string memory req= string(
      abi.encodePacked(
        "[{\"data\":\"0x",
        iToHex(reqd),
        "\",\"to\":\"0x",
        iToHex(abi.encodePacked(addr)),
        "\"},\"last\"]"
      )
    );
    bytes memory s= vm.rpc("pwr","eth_call",req);
    bytes memory ret = new bytes(s.length/2);
    for(uint16 i=0;i<s.length/2;i++){
      ret[i]=bytes1(h2i(uint8(s[i*2]),uint8(s[i*2+1])));
    }
    return ret;
  }
}

contract MockBronKerbosch is BronKerbosch, EvmCall {
  function max_clique_mask(uint256[2][] calldata arg) public virtual override returns (uint256) {
    bytes memory cd=abi.encodeWithSignature("max_clique_mask(uint256[2][])",arg);
    bytes memory result = rpc_call(address(0xAFFFFFFFFF000007), cd);
    (uint256 r) = abi.decode(result, (uint256));
    return r;
  }
  function max_clique_list(uint256[2][] calldata arg) public virtual override returns (uint256[] memory) {
    bytes memory cd=abi.encodeWithSignature("max_clique_list(uint256[2][])",arg);
    //emit log_bytes(cd);
    bytes memory result = rpc_call(address(0xAFFFFFFFFF000007), cd);
    //emit log_bytes(result);
    (uint256[] memory r) = abi.decode(result, (uint256[]));
    return r;
  }
}

contract MockGetTx is GetTx {
  function getTx() public override pure returns (tpTx memory) {
    tpSig[] memory signatures = new tpSig[](1);
    signatures[0].pubkey=abi.encodePacked(keccak256("ok"));
    tpTx memory rtx;
    rtx.signatures=signatures;
    return rtx;
  }
  function getExtra(string calldata keyname) public override pure returns (uint256, bytes memory) {
    bytes memory r = abi.encodePacked(keccak256(abi.encodePacked(keyname)));
    return(0,r);
  }
  function getSigners() public override pure returns (bytes[] memory) {
    bytes[] memory r;
    return r;
  }
}

contract TestContract is Test {
	ChainState cs;

	address admin;
	address deployer;
	address node1;
	address node2;
	address node3;

  function setUp() public {
    deployer   = address(0x010203040506070809FffFfFffFFffFFFFfFFf00);
    admin      = address(0x010203040506070809FFffFFffFffFFFFfFF0000);
    node1      = address(0x0102030405060708090000000000000000000001);
    node2      = address(0x0102030405060708090000000000000000000002);
    node3      = address(0x0102030405060708090000000000000000000003);

    vm.prank(deployer);
    bytes[] memory initial_nodes=new bytes[](0);
    cs=new ChainState(true,initial_nodes);

    address mgt=address(new MockGetTx());
    address targetAddr = 0x000000000000000000000000AFffFFfFFf000002;
    vm.etch(targetAddr, mgt.code);

    vm.etch(address(0xAFFFFFFFFF000007), address(new MockBronKerbosch()).code);

    FakeChainFee fcf=new FakeChainFee(address(0));
    cs.set_chainfee(payable(fcf));
  }

  function test_a_bk() public {
    uint256[2][] memory args = new uint256[2][](3);
    uint256 res;
    args[0][0]=0;args[0][1]=(1<<2)|(1<<1);
    args[1][0]=1;args[1][1]=(1<<2)|(1<<0);
    args[2][0]=2;args[2][1]=(1<<0);
    res=BronKerbosch(address(0xAFFFFFFFFF000007)).max_clique_mask(args);
    assertEq(3,res);
    args[2][0]=2;args[2][1]=(1<<0)|(1<<1);
    res=BronKerbosch(address(0xAFFFFFFFFF000007)).max_clique_mask(args);
    assertEq(7,res);
  }
  function test_b_fee() public {
    ChainFee cf=new ChainFee(address(0));
    vm.deal(address(cf),10);
    cf.new_epoch(1);
    vm.deal(address(cf),40);
    cf.new_epoch(2);
    vm.deal(address(cf),80);
    address[] memory a=new address[](3);
    a[0]=(address(0x100));
    a[1]=(address(0x101));
    a[2]=(address(0x102));
    address bad=address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    assertEq(0,a[0].balance);
    assertEq(0,a[1].balance);
    assertEq(0,a[2].balance);
    assertEq(0,bad.balance);

    cf.payout(a,1);
    assertEq(10,a[0].balance);
    assertEq(10,a[1].balance);
    assertEq(10,a[2].balance);
    assertEq(10,bad.balance);
  }

  function test_c_cs() public {
    emit log_bytes(abi.encodePacked(block.chainid));  

    vm.prank(node1);
    emit log_bytes(abi.encodePacked(cs.register()));

    vm.prank(address(0));
    emit log_bytes(abi.encodePacked(cs.afterBlock()));
    
    cs.info();
    emit log_bytes(abi.encodePacked(
      cs.afterBlock()
    ));
    cs.info();

    uint8[] memory test=new uint8[](3);
    test[0]=1;
    test[1]=2;
    test[2]=3;
    cs._updateDataRaw(1, 1, test);
    cs._updateDataRaw(2, 1, test);
    cs._updateDataRaw(3, 1, test);

    assertEq(vm.getBlockNumber(), 1);
    vm.roll(vm.getBlockNumber()+cs.CALC_DELAY());
    assertEq(vm.getBlockNumber(), 13);

    vm.prank(address(0));
    emit log_bytes(abi.encodePacked(
      cs.afterBlock()
    ));


    (uint256 f1,
    uint256 f2,
    uint256 f3,
    uint256 f4,
    uint256 f5) = cs.info();
    emit log_bytes(abi.encodePacked(f3));

    vm.roll(f3);
    vm.prank(address(0));
    emit log_bytes(abi.encodePacked(
      cs.afterBlock()
    ));
  }

    /*
	function testErc20() public {
		bytes memory orig_token=src_ser_erc20.prepare(address(src_erc20));

		vm.expectRevert(
			abi.encodeWithSelector(
				bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
				address(this),
				keccak256("TOKEN_ADMIN_ROLE")
				)
		);
		erc20_1=dst.newToken(address(dst_erc20_factory), orig_token);

		vm.prank(admin);
		erc20_1=dst.newToken(address(dst_erc20_factory), orig_token);

        assertEq(ERC20(src_erc20).name(), ERC20(erc20_1).name(), "ok");
        assertEq(ERC20(src_erc20).symbol(), ERC20(erc20_1).symbol(), "ok");
        assertEq(ERC20(src_erc20).decimals(), ERC20(erc20_1).decimals(), "ok");

		//vm.expectRevert("Unauthorized");
		vm.expectRevert(
			abi.encodeWithSelector(
				bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
				address(this),
				keccak256("TOKEN_ADMIN_ROLE")
				)
		);
		src.allowToken(address(src_erc20),
					   block.chainid,
					   bytes32(uint256(uint160(erc20_1))),
					   address(src_ser_erc20));

		vm.prank(admin);
		src.allowToken(address(src_erc20),
					   block.chainid,
					   bytes32(uint256(uint160(erc20_1))),
					   address(src_ser_erc20));


		address me=address(this);
		assertEq(src_erc20.balanceOf(me),0,"ok");

		uint256 amount=1000;

		src_erc20.mint(amount);
		assertEq(src_erc20.balanceOf(me),amount,"ok");
		address approve_to = src.checkMigrateTo(address(src_erc20),
												block.chainid);

		src_erc20.approve(approve_to, amount);

		address dusr = address(0x0001020304050607080910010203040506070809);
		bytes32 dusr32 = bytes32(uint256(uint160(dusr)));

		bytes memory migrate_data = src.migrateTo(address(src_erc20),
					  me,
					  abi.encode(amount),
					  block.chainid,
					  dusr32
					 );

		bytes memory attestation=sign(migrate_data);

		//bytes memory digest =  abi.encodePacked(dst.getDataHash(migrate_data));
		//assertEq(attestation,digest,"ok");

		assertEq(src_erc20.balanceOf(me),0,"ok");
		assertEq(src_erc20.balanceOf(address(1)),amount,"ok");

		assertEq(ERC20(erc20_1).balanceOf(dusr),0,"ok");
		dst.migrateFrom(migrate_data, attestation);
		assertEq(ERC20(erc20_1).balanceOf(dusr),amount,"ok");
		vm.expectRevert("Already done");
		dst.migrateFrom(migrate_data, attestation);
		assertEq(ERC20(erc20_1).balanceOf(dusr),amount,"ok");

		//check with exists but not authorized tokens
		src_erc20.mint(amount);
		assertEq(src_erc20.balanceOf(me),amount,"ok");
		//vm.expectRevert("transferFrom unsuccessull");

		vm.expectRevert(
			abi.encodeWithSignature(
			"ERC20InsufficientAllowance(address,uint256,uint256)",
			approve_to, 0, amount)
		);
		src.migrateTo(address(src_erc20),
					  me,
					  abi.encode(amount),
					  block.chainid,
					  dusr32
					 );
    }
    */

}

