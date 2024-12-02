// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Popcnt {
  function popcnt(uint256 value) public pure returns (uint256) {
    uint256 count = 0;

    // Brian Kernighan's algorithm: clear the least significant set bit until `value` becomes 0
    while (value > 0) {
      value &= (value - 1); // clears the lowest set bit
      count++;
    }

    return count;
  }
  function insertionSort(uint256[] memory a) internal pure {
    for (uint i = 1;i < a.length;i++){
      uint temp = a[i];
      uint j;
      for (j = i -1; j >= 0 && temp < a[j]; j--)
      a[j+1] = a[j];
      a[j + 1] = temp;
    }
  }
}
