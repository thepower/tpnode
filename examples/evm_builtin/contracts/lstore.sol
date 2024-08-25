// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract LStore {
	struct skey {
		uint256 datatype;
		bytes res_bin;
	}
	struct settings {
		uint256 datatype;
		bytes res_bin;
		uint256 res_int;
		skey[] keys;
	}
	function setByPath(bytes[] calldata,uint256,bytes calldata) public virtual returns (uint256) {}
	function getByPath(bytes[] calldata path) public virtual returns (settings memory) {}
	function getByPath(address addr, bytes[] calldata path) public virtual returns (settings memory) {}
}

