// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "contracts/access/Ownable.sol";

contract ChainManagement is Ownable {
  constructor (address _owner) Ownable(_owner) {
  }
  function allow_register() public {
  }
  event EpochUpdate(uint256 consensus_mask,
                     uint256 or_mask,
                     uint256 and_mask);
  function epoch_update(uint256 consensus_mask,
                        uint256 or_mask,
                        uint256 and_mask) public returns 
                        (uint256 emergency_mask, uint256 next_mask) {
    emit EpochUpdate(consensus_mask, or_mask, and_mask);
    //set_nodekind(bytes calldata nodekey, NodeKind k) public returns (NodeKind res) {
    return(0, 1);
  }
}

