// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract LStore {
  struct skey {
    uint256 datatype;
    bytes res_bin;
  }
  struct settings {
    uint256 datatype;
    bytes res_bin;
    uint256 res_int;
    skey[] keys;
  }
	function setByPath(bytes[] calldata,uint256,bytes calldata) public virtual returns (uint256) {}
  function getByPath(bytes[] calldata path) public virtual returns (settings memory) {}
  function getByPath(address addr, bytes[] calldata path) public virtual returns (settings memory) {}
}

contract LSTest {
	mapping(uint => uint) public chatCounters;
	LStore private lstore=LStore(address(0xAFFFFFFFFF000005));

	event textbin(string text,bytes data);

	constructor() {
	}

	function registerMessage(uint256 id, string memory message) public  {
		bytes[] memory path = new bytes[](3);
		path[0] = toBytes(id);//id
		path[1] = toBytes(chatCounters[id]);//number of meessage
		chatCounters[id]++;
		path[2] = bytes('acc');//index of meessage

		bytes[] memory pathCounter = new bytes[](2);
		pathCounter[0] = path[0];//id
		pathCounter[1] = bytes("count");//index of counter

		bytes memory acc = toBytes(uint256(uint160(msg.sender)));

		bytes memory message_bin = bytes(message);
		bytes memory count  = toBytes(chatCounters[id]);

		require(lstore.setByPath(pathCounter,1,count)==1,"can't set lstore");
		require(lstore.setByPath(path,1,acc)==1,"can't set lstore");
		path[2] = bytes('msg');//index of message
		require(lstore.setByPath(path,1,message_bin)==1,"can't set lstore");
	}

	function testLStore() public returns (LStore.settings memory) {
		bytes[] memory path = new bytes[](3);
		path[0] = bytes('a');
		path[1] = bytes('b');
		path[2] = bytes('acc');

		bytes memory val=hex'c0ffeedeadc0de';
		require(lstore.setByPath(path,1,val)==1,"can't set lstore");

		address _addr=address(0xAFFFFFFFFF000005);
		(bool success, bytes memory returnBytes) =
			_addr.staticcall(abi.encodeWithSignature("getByPath(bytes[])", path));
		require(success == true, "Call failed");
		LStore.settings memory ret = abi.decode(returnBytes, (LStore.settings));
		emit textbin('getByPath',returnBytes);
		//emit textset('getByPath',ret);
		return ret;
	}

	event A(uint256 t,address a, bytes b);
	event B(LStore.settings r);
	event P(bytes[] b);
	function delMessage(uint256 id, uint256 msgid) public  {
		bytes[] memory path = new bytes[](3);
		path[0] = toBytes(id);//id
		path[1] = toBytes(msgid);//number of meessage
		path[2] = bytes('acc');//index of meessage
		emit P(path);

		LStore.settings memory acc=lstore.getByPath(path);
		emit B(acc);
		address a=bytesToAddress(acc.res_bin);
		emit A(acc.datatype,a,acc.res_bin);

		address _addr=address(0xAFFFFFFFFF000005);
		(bool success, bytes memory returnBytes) =
			_addr.staticcall(abi.encodeWithSignature("getByPath(bytes[])", path));
		require(success == true, "Call failed");
		LStore.settings memory ret = abi.decode(returnBytes, (LStore.settings));
		emit textbin('getByPath',returnBytes);
		emit B(ret);

		/*
		require(acc.datatype==2,"bad address in msg");
		require(a==msg.sender || msg.sender==address(0x0102030405060708),"permission denied");

		path[2] = bytes('msg');//index of message
		bytes memory message_bin = bytes("");
		require(lstore.setByPath(path,1,message_bin)==1,"can't set lstore");
		*/
	}

	function bytesToAddress (bytes memory b) public pure returns (address) {
		uint result = 0;
		for (uint i = 0; i < b.length; i++) {
			uint c = uint(uint8(b[i]));
			result = result * 256 + c;
		}
		return address(uint160(result));
	}

	function toBytes(uint256 x) public pure returns (bytes memory b) {
		if (x==0) {
			return new bytes (1);	
		}
		uint l = 32;

		if (x < 0x100000000000000000000000000000000) { x <<= 128; l -= 16; }
		if (x < 0x1000000000000000000000000000000000000000000000000) { x <<= 64; l -= 8; }
		if (x < 0x100000000000000000000000000000000000000000000000000000000) { x <<= 32; l -= 4; }
		if (x < 0x1000000000000000000000000000000000000000000000000000000000000) { x <<= 16; l -= 2; }
		if (x < 0x100000000000000000000000000000000000000000000000000000000000000) { x <<= 8; l -= 1; }
		if (x < 0x100000000000000000000000000000000000000000000000000000000000000) { x <<= 8; l -= 1; }

		b = new bytes (l);

		assembly { mstore(add(b, 32), x) }
	}

	function getChatCounters(uint id) public view returns(uint counter) {
		return chatCounters[id];
	}
}
