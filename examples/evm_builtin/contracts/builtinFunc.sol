// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract builtinFunc {
  //enum TasksStatus { TaskAdded, TaskUpdated, UploadComplete, AllnodeSync }

  struct tpCall {
    string func;
    uint256[] args;
  }
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
    tpCall[] call;
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
  struct settings {
    uint256 settings;
    bytes res_bin;
    uint256 res_int;
    string[] keys;
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
  event sig1(uint256 chain, string name);

  constructor() {}

  function retcl() public returns (tpCall[] memory){
    tpCall[] memory call1=new tpCall[](2);
    uarr.push(1);
    uarr.push(3);
    uarr.push(5);
    call1[0] = tpCall("test", uarr);
    return call1;
  }

 
  function rettx() public returns (tpTx memory){
    tpCall[] memory call1=new tpCall[](1);
    uarr.push(1);
    uarr.push(3);
    uarr.push(5);
    call1[0] = tpCall("test", uarr);
    uint8 len=3;
    tpSig[] memory sigs=new tpSig[](len);
    sigs[0]=tpSig("",1,"bytes112345678923456789uebwryeyreriewuyrewbruewyrwyroewrybewoyrewyirewybriweyriuqweybrewqyrybqbytes112345678923456789uebwryeyreriewuyrewbruewyrwyroewrybewoyrewyirewybriweyriuqweybrewqyryq","raw","signature");
    tpPayload[] memory payload1=new tpPayload[](1);
    payload1[0]=tpPayload(0,"SK",10);

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

  function getS() public returns (settings memory) {
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
  function checkKeys() public returns (uint256) {
    address kaddr=address(0xAFFFFFFFFF000003);
    address taddr=address(0xAFFFFFFFFF000002);
    (bool success, bytes memory returnBytes) = taddr.staticcall("");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    uint256 i=0;
    uint256 c=0;
    for(i=0;i<ret.signatures.length;i++){
      (bool success1, bytes memory returnBytes1) = kaddr.staticcall(
        abi.encodeWithSignature("isNodeKnown(bytes)",ret.signatures[i].pubkey)
      );
      //require(success == true, "Call to isNodeKnown(bytes) failed");
      if(success){
        (uint8 known, uint256 chain, string memory name) = abi.decode(returnBytes1, (uint8, uint256, string));
        if(known>0){
          emit sig1(chain,name);
          rewardAddresses[ret.signatures[i].pubkey]=taddr;
        }
      }
    }
    return c;
  }

  function getTx() public returns (tpTx memory) {
    address _addr=address(0xAFFFFFFFFF000002);
    (bool success, bytes memory returnBytes) = _addr.staticcall("");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    return ret;
  }

  function getTxs() public returns (tpCall memory) {
    address _addr=address(0xAFFFFFFFFF000002);
    (bool success, bytes memory returnBytes) = _addr.staticcall("");
    emit callFunction("a1");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    emit callFunction("a2");
    uint256 i=0;
    for(i=0;i<ret.signatures.length;i++){
      emit sig(ret.signatures[i].rawkey);
    }
    return ret.call[0];
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

}
