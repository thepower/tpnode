// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
  //function max_clique_list(uint256[2][] calldata) public pure virtual returns (uint256[] memory) {}
  function max_clique_list(uint256[2][] calldata) public virtual returns (uint256[] memory) {}
  function max_clique_mask(uint256[2][] calldata) public virtual returns (uint256) {}
}

