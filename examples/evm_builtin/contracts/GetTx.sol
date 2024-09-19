// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract GetTx {
  struct tpTx {
    uint256 kind;
    address from;
    address to;
    uint256 t;
    uint256 seq;
    bytes call;
    tpPayload[] payload;
    tpSig[] signatures;
  }
  struct tpPayload {
    uint256 purpose;
    string cur;
    uint256 amount;
  }
  struct tpSig {
    bytes raw;
    uint256 timestamp;
    bytes pubkey;
    bytes rawkey;
    bytes signature;
  }

  function getTx() public virtual view returns (tpTx memory) {}
  function getExtra(string calldata keyname) public virtual view returns (uint256, bytes memory) {}
}

