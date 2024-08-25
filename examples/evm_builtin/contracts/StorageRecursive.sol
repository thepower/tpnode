pragma solidity ^0.8.20;

contract StorageRecursive1 {
  string public name;
  StorageRecursive2 public c2addr;
  uint256 public calls;
  uint256 public callsp0;
  uint256 public callsp1;
  constructor(string memory _name, address _c2){
    name=_name;
    c2addr=StorageRecursive2(_c2);
  }
  event L(string);
  function test(uint256 i) public {
    emit L(name);
    calls++;
    c2addr.test2(i);
  }
  function rcall(address target, bytes calldata data) public returns (bytes memory returnData) {
    bool success;
    callsp0++;
    (success, returnData) = target.call(data);
    callsp1++;
    require(success, "Multicall3: call failed");
  }
}

contract StorageRecursive2 {
  uint256 public counter1;
  uint256 public counter;
  uint256 public calls;
  uint256 public callsp0;
  uint256 public callsp1;
  function test2(uint256 i) public {
    calls++;
    counter+=i;
  }
  function rcall(address target, bytes calldata data) public returns (bytes memory returnData) {
    bool success;
    callsp0++;
    (success, returnData) = target.call(data);
    callsp1++;
    require(success, "Multicall3: call failed");
  }
}

