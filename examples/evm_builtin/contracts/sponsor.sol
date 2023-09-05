// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract sponsor {
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

  event textbin(string text,bytes data);
  event textpayload(string text,tpPayload data);

  constructor() {}

  function areYouSponsor() public pure returns (bool,bytes memory,uint256) {
    return (true,'SK',100000);
  }

  function wouldYouLikeToPayTx(tpTx calldata utx) public returns(string memory iWillPay, tpPayload[] memory pay) {
    uint i=0;
    uint found_fee_hint=0;
    uint found_gas_hint=0;
    for (i=0;i<utx.payload.length;i++){
      if(utx.payload[i].purpose==33){
        found_fee_hint=i+1;
      }
      if(utx.payload[i].purpose==35){
        found_gas_hint=i+1;
      }
    }

    uint c=0;
    if(found_fee_hint>0) c++;
    if(found_gas_hint>0) c++;

    tpPayload[] memory payload1=new tpPayload[](c+1);
    if(c==2){
      payload1[0]=utx.payload[found_fee_hint-1];
      payload1[0].purpose=1;
      payload1[1]=utx.payload[found_gas_hint-1];
      payload1[1].purpose=3;
    }else if(c==1 && found_gas_hint>0){
      payload1[0]=utx.payload[found_gas_hint-1];
      payload1[0].purpose=3;
    }else if(c==1 && found_fee_hint>0){
      payload1[0]=utx.payload[found_fee_hint-1];
      payload1[0].purpose=3;
    }
    payload1[c]=tpPayload(0,"TST",10000);
    //payload1[0]=tpPayload(1,"SK",1000000);
    //payload1[1]=tpPayload(3,"SK",1000000000);
    return ("i will pay",payload1);
  }
}
