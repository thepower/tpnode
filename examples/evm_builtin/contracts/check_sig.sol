// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract checkSig {
  struct tpCall {
    string func;
    uint256[] args;
  }
  struct tpSig {
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
    tpSig[] signatures;
  }
  struct settings {
    uint256 settings;
    bytes res_bin;
    uint256 res_int;
    string[] keys;
  }

  mapping(uint256 => address) public rewardAddresses;
  mapping(uint256 => bytes) public keys;
  mapping(bytes => uint256) public key2id;
  uint256 public count=0;

  event changed(bytes pubkey, uint256 chain, string name, address addr, uint256 id);
  event info(string txt, uint256 val);
  event info(string txt, uint256 val, uint256 val2);
  event info(string txt, bytes data);
  event info2(bytes);
  event info2(bytes[]);
  event info2(uint256[]);

  constructor() {}

  function blockSigs() public returns (bytes[] memory sigs) {
    require(block.number > 10, "block number is less than 10");
    address blks=address(0xAFFFFFFFFF000004);
    uint i=block.number-1;
    emit info("block number:",i);
    (bool success, bytes memory returnBytes1) = blks.staticcall(
      abi.encodeWithSignature("get_signatures_pubkeys(uint256 height)",i)
    );
    emit info("success:",success?1:0);
    if(success){
      (bytes[] memory signatures) = abi.decode(returnBytes1, (bytes[]));
      emit info2(signatures);
      return signatures;
    }
  }

  function blockCheck() public returns (uint256 sigs) {
    require(block.number > 10, "block number is less than 10");
    address blks=address(0xAFFFFFFFFF000004);
    uint[] memory foundcnt=new uint[](count);
    emit info("blockCheck",count);
    emit info("addr0",keys[0]);
    emit info("addr1",keys[1]);
    for(uint i=1;i<10;i++){ // last 10 blocks
      emit info("blk",i);
      (bool success, bytes memory returnBytes1) = blks.staticcall(
        abi.encodeWithSignature("get_signatures_pubkeys(uint256 height)",i)
      );
      if(success){
        emit info("1succ_blk",i);
        (bytes[] memory signatures) = abi.decode(returnBytes1, (bytes[]));
        emit info("2succ_blk",i);
        for(uint j=0;j<signatures.length;j++){
          emit info("sig",signatures[j]);
          uint256 registered=key2id[signatures[j]];
          emit info("sig_reg",registered);
          if(registered>0){
            emit info("registered:",registered);
            foundcnt[registered]++;
          }else{
            emit info("noreg",signatures[j]);
          }
        }
      }else{
        emit info("failed_blk",i);
        emit info2(returnBytes1);
      }

    }
    uint n=0;
    for(uint i=0;i<foundcnt.length;i++){
      emit info("found",i,foundcnt[i]);
      if(foundcnt[i]>0){
        n++;
      }
    }
    emit info2(foundcnt);
    return n;
  }

  function setAddr() public returns (uint256) {
    address taddr=address(0xAFFFFFFFFF000002);
    (bool success1, bytes memory returnBytes) = taddr.staticcall("");
    require(success1 == true, "tx fetch failed");
    tpTx memory ret = abi.decode(returnBytes, (tpTx));
    uint256 i=0;
    uint256 c=0;

    address kaddr=address(0xAFFFFFFFFF000003);
    for(i=0;i<ret.signatures.length;i++){
      (bool success, bytes memory returnBytes1) = kaddr.staticcall(
        abi.encodeWithSignature("isNodeKnown(bytes)",ret.signatures[i].pubkey)
      );
      if(success){
        (uint8 known, uint256 chain, string memory name) = abi.decode(returnBytes1, (uint8, uint256, string));
        if(known>0){
          uint256 n=key2id[ret.signatures[i].pubkey];
          if(n==0){
            n=count;
            count++;
            keys[n]=ret.signatures[i].pubkey;
          }
          rewardAddresses[n]=msg.sender;
          emit changed(ret.signatures[i].pubkey,chain,name,msg.sender, n);
          c++;
        }
      }else{
        emit info2(returnBytes1);
      }
    }
    return c;
  }
}
