// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "contracts/access/Ownable.sol";
import "contracts/Popcnt.sol";

contract ChainManagement is Ownable, Popcnt {
  constructor (address _owner) Ownable(_owner) {
  }
  function allow_register() public {
  }
  event EpochUpdate(uint256 consensus_mask,
                    uint256 or_mask,
                    uint256 and_mask,
                    uint256 visible_mask);
  event Emergency(uint256 mask);
  event Trace(uint256[] hist_visible_mask);
  event ConsensusFullyValid(uint256 mask);
  function epoch_update(uint256 consensus_mask,
                        uint256 or_mask,
                        uint256 and_mask,
                        uint256 visible_mask0,
                        uint256[] calldata hist_visible_mask) public returns 
                        (uint256 emergency_mask, uint256 next_mask) {
    emit EpochUpdate(consensus_mask, or_mask, and_mask, hist_visible_mask[0]);
    bool full_valid = (visible_mask0 & consensus_mask) == consensus_mask;
    if (full_valid) {
      emit ConsensusFullyValid(consensus_mask);
      return(0, consensus_mask);
    }
    emit Trace(hist_visible_mask);

    uint256 consensus_nodes = popcnt(consensus_mask);
    uint256 cur_alive_mask = visible_mask0 & consensus_mask;
    uint256 current_minsig = (consensus_nodes/2)+1;
    uint256 cur_alive = popcnt(cur_alive_mask);

    bool emergency = !(cur_alive>current_minsig);
    if (emergency)
      emit Emergency(visible_mask0 & consensus_mask);

    //visible mask is a sum of all visible masks
    uint256 visible_mask = visible_mask0;
    for (uint256 i = 0; i < hist_visible_mask.length; i++) {
      visible_mask &= hist_visible_mask[i];
    }

    uint256 new_consensus_mask = 0;
    if (consensus_nodes == cur_alive) {
      new_consensus_mask = consensus_mask;
    } else {
      /*
      for (uint256 i = 0; i < 256; i++) {
        if (cur_alive_mask & (1 << i) != 0) {
          if (cur_alive >= current_minsig) {
            new_consensus_mask |= (1 << i);
          }
        }
      }
     */
    }



    //set_nodekind(bytes calldata nodekey, NodeKind k) public returns (NodeKind res)

    return(0, 1);
  }
}

