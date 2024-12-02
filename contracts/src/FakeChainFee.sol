// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FakeChainFee {
  uint256 public age;
  bool public epoch_payed;
  constructor(address _cs) {
  }

  receive() external payable {}

  event NewEpoch(uint256 indexed age);

  function new_epoch(uint256 _age) public returns (uint256 ret) {
    emit NewEpoch(_age);
    ret=age;
    age=_age;
    epoch_payed=false;
  }
  event Pay(address);
  event Burn(uint256);
  function payout(address[] calldata _payto, uint256 _toburn) public returns (uint256 payed,
  uint256 burned) {
    require(epoch_payed==false, "Epoch already payed");
    for(uint256 i=0;i<_payto.length;i++){
      emit Pay(_payto[i]);
    }
    if(_toburn>0){
      emit Burn(_toburn);
    }
    epoch_payed=true;
    payed=_payto.length;
    burned=_toburn;
  }
}

