pragma solidity ^0.8.20;

contract Callee {
  event Sender(address sender);
  function callX(uint _x) public returns (uint) {
    emit Sender(msg.sender);
    return _x;
  }
}

contract Caller {
  event Sender(address sender);
  function setXFromAddress(address _addr, uint _x) public {
    emit Sender(msg.sender);
    Callee callee = Callee(_addr);
    callee.callX(_x);
  }
}
