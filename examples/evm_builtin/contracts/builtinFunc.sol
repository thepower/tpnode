// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "contracts/lstore.sol";
import "contracts/GetTx.sol";

contract BronKerbosch {
  struct node_info {
    uint256 node_id;
    uint256[] nodes;
  }
  struct node_info2 {
    uint256 src_node;
    uint256 dst_node;
  }
  function max_clique(node_info[] calldata) public pure virtual returns (uint256[] memory) {}
  function max_clique(node_info2[] calldata) public pure virtual returns (uint256[] memory) {}
}
contract Chkey {
  function setKey(bytes calldata) public virtual {}
}

contract builtinFunc {
	/*
  struct tpCall {
    string func;
    uint256[] args;
  }
  */
  struct tpSig {
    bytes raw;
    uint256 timestamp;
    bytes pubkey;
    bytes rawkey;
    bytes signature;
  }
  struct tpTx {
    uint256 kind;
    address from;
    address to;
    uint256 t;
    uint256 seq;
    //tpCall[] call;
    bytes call;
    tpPayload[] payload;
    tpSig[] signatures;
  }
  struct tpPayload {
    uint256 purpose;
    string cur;
    uint256 amount;
  }

  struct structTextExample {
    uint256 id;
    string text;
  }
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

  uint256 public exampleTextCount;
  uint256[] public uarr;
  structTextExample[] public sarr;
  mapping(uint256 => structTextExample) public mapText;
  mapping(bytes => address) public rewardAddresses;

  uint256 public exampleIntCount;
  mapping(uint256 => uint256) public mapInt;

  event callFunction(string nameFunction);
  event newTx(tpTx tx);
  event sig(bytes tx);
  event Debug(bytes);
  event sig1(uint256 chain, string name);
  event textbin(string text,bytes data);
  event textpayload(string text,tpPayload data);
//  event textset(string text,settings data);

  constructor() {}

  /*
  function retcl() public returns (tpCall[] memory){
    tpCall[] memory call1=new tpCall[](2);
    uarr.push(1);
    uarr.push(3);
    uarr.push(5);
    call1[0] = tpCall("test", uarr);
    return call1;
  }*/


  function rettx() public returns (tpTx memory){
    //tpCall[] memory call1=new tpCall[](1);
    //uarr.push(1);
    //uarr.push(3);
    //uarr.push(5);
    //call1[0] = tpCall("test", uarr);
    uint8 len=3;
    tpSig[] memory sigs=new tpSig[](len);
    sigs[0]=tpSig("",1,"bytes112345678923456789uebwryeyreriewuyrewbruewyrwyroewrybewoyrewyirewybriweyriuqweybrewqyrybqbytes112345678923456789uebwryeyreriewuyrewbruewyrwyroewrybewoyrewyirewybriweyriuqweybrewqyryq","raw","signature");
    tpPayload[] memory payload1=new tpPayload[](1);
    payload1[0]=tpPayload(0,"SK",10);

	bytes memory call1 = abi.encodePacked(uint256(1),uint256(2),uint256(3));

    return tpTx({
      kind:4100,
      from:msg.sender,
      to:msg.sender,
      t:123,
      seq:243,
      call:call1,
      payload:payload1,
      signatures:sigs
      });
  }

  function rettuple() public pure returns (structTextExample memory){
    return structTextExample({ id:123, text: "321"});
  }

  function retsarr() public returns (structTextExample[] memory){
    sarr.push(structTextExample({ id:999, text: "999"}));
    sarr.push(structTextExample({ id:666, text: "666"}));
    return sarr;
  }


  function retarr() public returns (uint[] memory){
    //uint[] memory ar1=[1,2,3];
    uarr.push(1);
    uarr.push(2);
    uarr.push(8);
    return uarr;//[1,2,3];
  }

  function getS() public view returns (settings memory) {
    address _addr=address(0xAFFFFFFFFF000003);
    string[] memory path=new string[](3);
    path[0]="current";
    path[1]="rewards";
    path[2]="c1n1";
    (bool success, bytes memory returnBytes) = _addr.staticcall(
      abi.encodeWithSignature("byPath(string[])",path)
    );
    require(success == true, "Call to byPath([]) failed");
    settings memory ret = abi.decode(returnBytes, (settings));
    return ret;
  }
  function changeKey1() public {
    (bool success,/* bytes memory data*/) = address(0xAFFFFFFFFF000006).call{gas: 5000}(
      abi.encodeWithSignature("setKey(bytes)", bytes("\x00\x01"))
    );
    require(success,"something wrong");
  }
  function checkKeys() public returns (uint256) {
    address kaddr=address(0xAFFFFFFFFF000003);
    address taddr=address(0xAFFFFFFFFF000002);
    (bool success, bytes memory returnBytes) = taddr.staticcall("");
    require(success == true, "Call 0xAFFFFFFFFF000002 failed");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    uint256 i=0;
    uint256 c=0;
    for(i=0;i<ret.signatures.length;i++){
      (bool success1, bytes memory returnBytes1) = kaddr.staticcall(
        abi.encodeWithSignature("isNodeKnown(bytes)",ret.signatures[i].pubkey)
      );
      require(success1 == true, "Call to isNodeKnown(bytes) failed");
      if(success1){
        (uint8 known, uint256 chain, string memory name) = abi.decode(returnBytes1, (uint8, uint256, string));
        if(known>0){
          emit sig1(chain,name);
          rewardAddresses[ret.signatures[i].pubkey]=taddr;
        }
      }
    }
    return c;
  }

  function getExtra(string memory ex) public view returns (uint256, bytes memory) {
		return GetTx(address(0xAFFFFFFFFF000002)).getExtra(ex);
  }
  function getTx() public view returns (tpTx memory) {
    address _addr=address(0xAFFFFFFFFF000002);
    (bool success, bytes memory returnBytes) = _addr.staticcall("");
    require(success == true, "Call failed");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    return ret;
  }

  function exampleTx() public pure returns (tpTx memory ret) {
    ret.kind=16;
    ret.from=address(0x8000000000000001);
    ret.to=address(0x8000000000000002);
    ret.t=0x12345678;
    ret.seq=0x123;
  }

  function bron_kerbosch() public pure returns (uint256[] memory) {
    BronKerbosch.node_info[] memory n=new BronKerbosch.node_info[](3);
    n[0].node_id=1;
    n[0].nodes=new uint256[](2);
    n[0].nodes[0]=2;
    n[0].nodes[1]=3;
    n[1].node_id=2;
    n[1].nodes=new uint256[](2);
    n[1].nodes[0]=1;
    n[1].nodes[1]=3;
    n[2].node_id=3;
    n[2].nodes=new uint256[](2);
    n[2].nodes[0]=2;
    n[2].nodes[1]=3;
    return BronKerbosch(address(0xAFFFFFFFFF000007)).max_clique(n);
  }

  function getTxs() public returns (bytes memory) {
    address _addr=address(0xAFFFFFFFFF000002);
    emit callFunction("a0");
    (bool success, bytes memory returnBytes) = _addr.staticcall("");
    require(success == true, "Call failed");
    emit callFunction("a1");
    emit Debug(returnBytes);
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    emit callFunction("a2");
    uint256 i=0;
    for(i=0;i<ret.signatures.length;i++){
      emit sig(ret.signatures[i].rawkey);
    }
    return ret.call;
  }

  function callText(address _addr, uint256 id) public returns (uint256){
    (bool success, bytes memory returnBytes) = _addr.staticcall(abi.encodeWithSignature("structText(uint256)", id));
    require(success == true, "Call to structText() failed");
    structTextExample memory returnValue = abi.decode(returnBytes, (structTextExample));
    exampleTextCount=exampleTextCount+1;
    mapText[exampleTextCount]=returnValue;
    emit callFunction('structText');
    return exampleTextCount;
  }

  function callInt(address _addr, uint256 id) public returns (uint256){
    (bool success, bytes memory returnBytes) = _addr.staticcall(abi.encodeWithSignature("int(uint256)", id));
    require(success == true, "Call to int() failed");
    uint256 returnValue = abi.decode(returnBytes, (uint256));
    exampleIntCount=exampleIntCount+1;
    mapInt[exampleIntCount]=returnValue;
    emit callFunction('int');
    return exampleIntCount;
  }

  function getTextCount() public view returns(
      uint256 textCount
      ) {
    return exampleTextCount;
  }

  function getIntCount() public view returns(
      uint256 intCount
      ) {
    return exampleIntCount;
  }

  function getText(uint256 _id) public view returns(
      structTextExample memory structText
      ) {
    return mapText[_id];
  }
  function getInt(uint256 _id) public view returns(
      uint256 rsInt
      ) {
    return mapInt[_id];
  }
  /*
  function setByPath(bytes[] calldata,uint256,skey calldata) public returns (uint256) {
	  return 0;
  }
  */

  function setLStore(bytes[] calldata d) public returns (uint256) {
    address _addr=address(0xAFFFFFFFFF000005);
    bytes memory val=hex'c0ffeedeadc0de';
    (bool success, bytes memory returnBytes) =
      _addr.staticcall(abi.encodeWithSignature("setByPath(bytes[],uint256,bytes)", d, 1, val));
    if (success) {
      emit textbin('setByPath:success',returnBytes);
      return 1;
    }else {
      emit textbin('fail:setByPath',returnBytes);
      return 0;
    }
  }

  function getLStore(bytes[] calldata d) public returns (settings memory) {
    address _addr=address(0xAFFFFFFFFF000005);
    (bool success, bytes memory returnBytes) =
      _addr.staticcall(abi.encodeWithSignature("getByPath(address,bytes[])", address(this), d));
    require(success == true, "Call failed");
    settings memory ret = abi.decode(returnBytes, (settings));
    emit textbin('getByPath',returnBytes);
    //emit textset('getByPath',ret);
    return ret;
  }

  function lstoreCheck(bytes calldata i) public returns (LStore.settings memory) {
    bytes[] memory path = new bytes[](3);
    path[0] = bytes('a');
    path[1] = bytes('b');
    path[2] = bytes('c');

    bytes memory val=hex'c0ffeedeadc0de';
	address _addr=address(0xAFFFFFFFFF000005);
	LStore lstore=LStore(_addr);
    require(lstore.setByPath(path,1,val)==1,"can't set lstore");

    (bool success, bytes memory returnBytes) =
      _addr.staticcall(abi.encodeWithSignature("getByPath(bytes[])", path));
    require(success == true, "Call failed");
    emit textbin('getByPath',returnBytes);
    LStore.settings memory ret = abi.decode(returnBytes, (LStore.settings));
    return ret;
  }


  function PairingTest() public returns (uint) {
      uint256[12] memory input;
      //(G1)x
      input[0] = uint256(0x2cf44499d5d27bb186308b7af7af02ac5bc9eeb6a3d147c186b21fb1b76e18da);
      //(G1)y
      input[1] = uint256(0x2c0f001f52110ccfe69108924926e45f0b0c868df0e7bde1fe16d3242dc715f6);
      //(G2)x_1
      input[2] = uint256(0x1fb19bb476f6b9e44e2a32234da8212f61cd63919354bc06aef31e3cfaff3ebc);
      //(G2)x_0
      input[3] = uint256(0x22606845ff186793914e03e21df544c34ffe2f2f3504de8a79d9159eca2d98d9);
      //(G2)y_1
      input[4] = uint256(0x2bd368e28381e8eccb5fa81fc26cf3f048eea9abfdd85d7ed3ab3698d63e4f90);
      //(G2)y_0
      input[5] = uint256(0x2fe02e47887507adf0ff1743cbac6ba291e66f59be6bd763950bb16041a0a85e);
      //(G1)x
      input[6] = uint256(0x0000000000000000000000000000000000000000000000000000000000000001);
      //(G1)y
      input[7] = uint256(0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45);
      //(G2)x_1
      input[8] = uint256(0x1971ff0471b09fa93caaf13cbf443c1aede09cc4328f5a62aad45f40ec133eb4);
      //(G2)x_0
      input[9] = uint256(0x091058a3141822985733cbdddfed0fd8d6c104e9e9eff40bf5abfef9ab163bc7);
      //(G2)y_1
      input[10] = uint256(0x2a23af9a5ce2ba2796c1f4e453a370eb0af8c212d9dc9acd8fc02c2e907baea2);
      //(G2)y_0
      input[11] = uint256(0x23a8eb0b0996252cb548a4487da97b02422ebc0e834613f954de6c7e0afdc1fc);
      //multiplies the pairings and stores a 1 in the first element of input
      assembly {
          if iszero(
              call(not(0), 0x08, 0, input, 0x0180, input, 0x20)
          ) {
              revert(0, 0)
          }
      }
      return input[0];
  }
}
