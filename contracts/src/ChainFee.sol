// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ChainFee {
  address cs;
  uint256 pre_age_balance;
  uint256 age;
  bool epoch_payed;

  constructor(address _cs) {
    cs=_cs;
  }

  receive() external payable {}

  function new_epoch(uint256 _age) public returns (uint256 ret) {
    require(msg.sender==address(cs) || address(cs) == address(0),
            "Only ChainState can call this");
    require(_age>age,"epoch must be really new");
    pre_age_balance=address(this).balance;
    ret=age;
    age=_age;
    epoch_payed=false;
  }
  event CantSend(address,uint256);
  event Payed(address,uint256);
  event Burned(uint256);
  event TryPayout(uint256,uint256,uint256);
  event NotBurned(bytes);
  function payout(address[] calldata _payto, uint256 _toburn) public returns (uint256 payed,
                                                                              uint256 burned) {
    require(msg.sender==address(cs) || address(cs) == address(0),
            "Only ChainState can call this"); //for tests mught be deployed without cs address
    require(epoch_payed==false, "Epoch already payed");
    uint256 parts=_payto.length+_toburn;
    require(parts>0,"not enough recipients");
    uint256 part=pre_age_balance/parts;
    emit TryPayout(pre_age_balance,parts,_toburn);

    // Call returns a boolean value indicating success or failure.
    // This is the current recommended method to use.
    for(uint256 i=0;i<_payto.length;i++){
      (bool sent, ) = _payto[i].call{value: part}("");
      if (!sent) {
        emit CantSend(_payto[i],part);
        _toburn+=1;
      }else{
        payed+=part;
        emit Payed(_payto[i],part);
      }
    }
    if(_toburn>0){
      uint256 burnsum=part*_toburn;
      address bad=address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
      (bool ok, bytes memory data) = bad.call{value: burnsum}("");
      burned=burnsum;
      if(ok)
        emit Burned(burnsum);
      else
        emit NotBurned(data);
    }
    epoch_payed=true;
  }
}

