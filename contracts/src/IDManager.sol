// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract IDManager {
  bytes32 private constant IDSTATUS_SLOT = keccak256("idmanager.idstatus");
  bytes32 private constant AVAILABLE_SLOT = keccak256("idmanager.available");
  function _getIdStatus() internal pure returns (mapping(uint8 => uint8) storage idStatus) {
    bytes32 slot = IDSTATUS_SLOT;
    assembly {
      idStatus.slot := slot
    }
  }
  function _getAvailable() internal pure returns (uint8[]  storage available) {
    bytes32 slot = AVAILABLE_SLOT;
    assembly {
      available.slot := slot
    }
  }

    //uint8[] private available;
    //mapping(uint8 => uint8) private idStatus; // 0 = does not exist, 1 = available, 2 = allocated

    constructor(uint8 i1, uint8 num) {
      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      uint8[] storage available = _getAvailable();
      // Initialize the "available" list with values [1, 240]
      for (uint8 i = i1+num; i >= i1; i--) {
        available.push(i);
        idStatus[i] = 1; // Mark as available
      }
    }

    /**
     * @dev Checks if an ID is in the "available" list.
     * @param id The ID to check.
     * @return bool indicating whether the ID is available.
     */
    function is_available(uint8 id) internal view returns (bool) {
      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      return idStatus[id] == 1;
    }

    /**
     * @dev Checks if an ID is in the "allocated" state.
     * @param id The ID to check.
     * @return bool indicating whether the ID is allocated.
     */
    function is_allocated(uint8 id) internal view returns (bool) {
      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      return idStatus[id] == 2;
    }

    /**
     * @dev Allocates an ID from the "available" list.
     * @return uint8 The allocated ID, or 0 if no IDs are available.
     */
    function alloc() internal returns (uint8) {
      uint8[] storage available = _getAvailable();
      if (available.length == 0) {
        return 0; // No IDs available
      }
      uint8 id = available[available.length - 1];
      available.pop();

      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      idStatus[id] = 2; // Mark as allocated
      return id;
    }

    function alloc(uint8 id) internal returns (uint8) {
      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      uint8[] storage available = _getAvailable();
      if (idStatus[id] != 1) {
        return 0; // ID is not available or does not exist
      }

      // Mark ID as allocated
      idStatus[id] = 2;

      // Remove the ID from the "available" list
      for (uint256 i = 0; i < available.length; i++) {
        if (available[i] == id) {
          available[i] = available[available.length - 1];
          available.pop();
          break;
        }
      }

      return id; // Return the allocated ID
    }

    /**
     * @dev Deallocates an ID, returning it back to the "available" list.
     * @param id The ID to deallocate.
     */
    function dealloc(uint8 id) internal {
      mapping(uint8 => uint8) storage idStatus = _getIdStatus();
      require(idStatus[id] == 2, "ID is not allocated");

      idStatus[id] = 1; // Mark as available
      uint8[] storage available = _getAvailable();
      available.push(id);
    }

    /**
     * @dev Returns the number of available IDs (for testing purposes).
     * @return uint256 The length of the available list.
     */
    function getAvailableLength() internal view returns (uint256) {
      uint8[] storage available = _getAvailable();
      return available.length;
    }
}

