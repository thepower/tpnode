// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract StaticOwnable {
    // Define a static storage slot for the owner
    bytes32 private constant OWNER_SLOT = keccak256("openzeppelin.contracts.owner");

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Internal function to get the owner from the static slot.
     */
    function _getOwner() internal view returns (address _owner) {
        bytes32 slot = OWNER_SLOT;
        assembly {
            _owner := sload(slot)
        }
    }

    /**
     * @dev Internal function to set the owner in the static slot.
     */
    function _setOwner(address newOwner) private {
        bytes32 slot = OWNER_SLOT;
        assembly {
            sstore(slot, newOwner)
        }
    }

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor(address _owner) {
        _setOwner(_owner);
        emit OwnershipTransferred(address(0), _owner);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _getOwner();
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_getOwner() == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_getOwner(), address(0));
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_getOwner(), newOwner);
        _setOwner(newOwner);
    }
}

