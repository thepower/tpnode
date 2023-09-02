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
    for (i=0;i<utx.payload.length;i++){
      emit textpayload('wouldYouLikeToPayTx',utx.payload[i]);
    }

    tpPayload[] memory payload1=new tpPayload[](1);
    payload1[0]=tpPayload(0,"SK",10);
    return ("i will pay",payload1);
  }
}
