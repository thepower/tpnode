// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "contracts/lstore.sol";

contract ChainSettings {
  address public admin;
  mapping ( address => bool ) public admins;

  struct patch {
    bytes[] path;
    uint256 action;
    bytes val;
  }

  constructor() {
  }

  function set_admin(address new_admin) public {
    require(msg.sender==admin || admin==address(0),"permission denied");
    admin=new_admin;
  }
  function allow_admin(address new_admin, bool enable) public {
    require(msg.sender==admin || admins[msg.sender],"permission denied");
    admins[new_admin]=enable;
  }
  function set_key(bytes calldata newkey) public {
    require(msg.sender==admin || admins[msg.sender],"permission denied");
    ChKey service = ChKey(address(0xAFFFFFFFFF000006));
    require(service.setKey(newkey)==1,"can't set key");
  }
  function apply_patch(patch[] calldata patches) public {
    require(msg.sender==admin || admins[msg.sender],"permission denied");
    address _addr=address(0xAFFFFFFFFF000005);
    LStore lstore=LStore(_addr);
    for(uint i=0;i<patches.length;i++){
      require(lstore.setByPath(patches[i].path,
                               patches[i].action,
                               patches[i].val)==1,"can't set lstore");
    }
  }
}
