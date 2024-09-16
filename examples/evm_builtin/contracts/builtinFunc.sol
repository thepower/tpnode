// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "contracts/lstore.sol";

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
}
