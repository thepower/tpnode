// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "contracts/Popcnt.sol";
import "contracts/IChainNode.sol";
import "contracts/IChainState.sol";

/// @title ChainManagement Contract
/// @notice Manages nodes participating in consensus based on ChainNode NFTs
contract ChainManagement is Ownable, ReentrancyGuard, Popcnt {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Reference to the ChainState contract
    IChainState public chainState;

    /// @notice Reference to the ChainNode (ERC721) contract
    IChainNode public chainNode;

    /// @notice Minimum number of nodes required for consensus
    uint8 public min_nodes;

    /// @notice Maximum number of nodes allowed for consensus
    uint8 public max_nodes;

    /// @notice Minimum stake required to join as a node
    uint256 public min_stake;

    /// @notice Maximum node identifier (1-240)
    uint8 public constant MAX_NODE_ID = 240;

    /// @notice Pool of available node IDs (1-240)
    EnumerableSet.UintSet private availableNodeIds;

    /// @notice Mapping from node ID to token ID (active nodes)
    mapping(uint8 => uint256) public activeNodes; // node_id => token_id

    /// @notice Mapping from token ID to node ID (active nodes)
    mapping(uint256 => uint8) public activeNodeIdentifiers; // token_id => node_id

    /// @notice Set of inactive node token IDs
    EnumerableSet.UintSet private inactiveNodes;

    /// @notice Set of node token IDs queued for deactivation
    EnumerableSet.UintSet private deactivationQueue;

    /// @notice Mapping from token ID to array of public keys
    mapping(uint256 => bytes[]) public node_keys;

    /// @notice Mapping from token ID to lock renewal timestamp
    mapping(uint256 => uint256) public lockRenewal;

    /// @notice Mapping from token ID to total slashed amount
    mapping(uint256 => uint256) public tokenSlashedAmounts;

    /// @notice Event emitted when a node joins as inactive
    event NodeJoined(uint256 indexed tokenId, bytes pubkey);

    /// @notice Event emitted when a node leaves
    event NodeLeft(uint256 indexed tokenId);

    /// @notice Event emitted when a node is activated
    event NodeActivated(uint8 indexed nodeId, uint256 indexed tokenId, bytes pubkey);

    /// @notice Event emitted when a node is deactivated
    event NodeDeactivated(uint8 indexed nodeId, uint256 indexed tokenId);

    /// @notice Event emitted when min_nodes is updated
    event MinNodesUpdated(uint8 previous, uint8 newMin);

    /// @notice Event emitted when max_nodes is updated
    event MaxNodesUpdated(uint8 previous, uint8 newMax);

    /// @notice Event emitted when min_stake is updated
    event MinStakeUpdated(uint256 previous, uint256 newMinStake);

    /// @notice Event emitted during epoch updates
    event EpochUpdate(
        uint256 consensus_mask,
        uint256 or_mask,
        uint256 and_mask,
        uint256 visible_mask0,
        uint256[] hist_visible_mask
    );

    /// @notice Event emitted when a node is selected for consensus
    event NodeSelectedForConsensus(uint8 indexed nodeId);

    /// @notice Modifier to check if a token is active
    modifier onlyActive(uint256 tokenId) {
        require(activeNodeIdentifiers[tokenId] != 0, "Token is not active");
        _;
    }

    /// @notice Modifier to check if a token is inactive
    modifier onlyInactive(uint256 tokenId) {
        require(inactiveNodes.contains(tokenId), "Token is not inactive");
        _;
    }

    /// @notice Modifier to restrict functions to ChainState only
    modifier onlyChainState() {
        require(msg.sender == address(chainState), "Caller is not ChainState");
        _;
    }

    /// @notice Constructor to initialize the contract
    /// @param _chainNode Address of the ChainNode (ERC721) contract
    /// @param _chainState Address of the ChainState contract
    /// @param _min_nodes Minimum number of active nodes required
    /// @param _max_nodes Maximum number of active nodes allowed
    /// @param _min_stake Minimum stake required to join as a node
    constructor(
        address _chainNode,
        address _chainState,
        uint8 _min_nodes,
        uint8 _max_nodes,
        uint256 _min_stake
    ) Ownable(msg.sender) {
        require(_min_nodes <= _max_nodes && _max_nodes <= MAX_NODE_ID, "Invalid node limits");

        if(_chainNode != address(0))
          chainNode = IChainNode(_chainNode);
        if(_chainState != address(0))
          chainState = IChainState(_chainState);
        min_nodes = _min_nodes;
        max_nodes = _max_nodes;
        min_stake = _min_stake;

        // Initialize availableNodeIds with 1 to 240
        for (uint8 i = 4; i > 0; i--) {
            availableNodeIds.add(i);
        }
    }

    /// @notice Allows NFT owners to join as nodes by providing their public key
    /// @param tokenId The ID of the ChainNode NFT
    /// @param pubkey The public key of the node
    function join(uint256 tokenId, bytes calldata pubkey) external nonReentrant {
        // Verify caller owns the token
        require(chainNode.ownerOf(tokenId) == msg.sender, "Caller does not own the token");

        // Verify ChainManagement is approved
        require(
            chainNode.isApprovedForAll(msg.sender, address(this)) ||
                chainNode.getApproved(tokenId) == address(this),
            "ChainManagement is not approved"
        );

        // Verify the token's stake is >= min_stake
        uint256 tokenPrice = chainNode.getTokenPrice(tokenId);
        require(tokenPrice >= min_stake, "Insufficient stake");

        // Store the pubkey
        node_keys[tokenId].push(pubkey);

        // Lock the token for 1 week (604800 seconds)
        chainNode.lock(tokenId, 604800); // 1 week

        // Add to inactiveNodes
        bool added = inactiveNodes.add(tokenId);
        require(added, "Token already inactive");

        // Update lock renewal timestamp
        lockRenewal[tokenId] = block.timestamp + 604800;

        emit NodeJoined(tokenId, pubkey);
    }

    /// @notice Allows node owners to leave the network
    /// @param tokenId The ID of the ChainNode NFT
    function leave(uint256 tokenId) external nonReentrant {
        address owner = chainNode.ownerOf(tokenId);
        require(owner == msg.sender, "Caller does not own the token");

        if (activeNodeIdentifiers[tokenId] != 0) {
            // Active node: enqueue for deactivation
            deactivationQueue.add(tokenId);
            emit NodeLeft(tokenId);
        } else if (inactiveNodes.contains(tokenId)) {
            // Inactive node: remove from inactive list and delete data
            bool removed = inactiveNodes.remove(tokenId);
            require(removed, "Failed to remove from inactive list");

            // Delete pubkeys
            delete node_keys[tokenId];

            // Delete lock renewal
            delete lockRenewal[tokenId];

            emit NodeLeft(tokenId);
        } else {
            revert("Token is neither active nor inactive");
        }
    }

    /// @notice Sets the minimum number of active nodes required
    /// @param _min_nodes The new minimum number of active nodes
    function setMinNodes(uint8 _min_nodes) external onlyOwner {
        require(_min_nodes <= max_nodes && max_nodes <= MAX_NODE_ID, "Invalid min_nodes value");
        uint8 previous = min_nodes;
        min_nodes = _min_nodes;
        emit MinNodesUpdated(previous, _min_nodes);
    }

    /// @notice Sets the maximum number of active nodes allowed
    /// @param _max_nodes The new maximum number of active nodes
    function setMaxNodes(uint8 _max_nodes) external onlyOwner {
        require(_max_nodes >= min_nodes && _max_nodes <= MAX_NODE_ID, "Invalid max_nodes value");
        uint8 previous = max_nodes;
        max_nodes = _max_nodes;
        emit MaxNodesUpdated(previous, _max_nodes);
    }

    /// @notice Sets the minimum stake required to join as a node
    /// @param _min_stake The new minimum stake
    function setMinStake(uint256 _min_stake) external onlyOwner {
        require(_min_stake > 0, "min_stake must be greater than zero");
        uint256 previous = min_stake;
        min_stake = _min_stake;
        emit MinStakeUpdated(previous, _min_stake);
    }

    /// @notice Activates an inactive node by moving it to the active list
    /// @param tokenId The ID of the ChainNode NFT to activate
    function setActivate(uint256 tokenId) public onlyOwner nonReentrant {
      require(inactiveNodes.contains(tokenId), "Token is not inactive");
      require(activeNodeIdentifiers[tokenId] == 0, "Token is already active");

      _activate(tokenId);
    }

    function _activate(uint256 tokenId) internal returns (bool) {
      // Assign a node_id from availableNodeIds
      require(availableNodeIds.length() > 0, "No available node IDs");

      uint8 nodeId = uint8(availableNodeIds.at(0));
      availableNodeIds.remove(nodeId);

      // Remove from inactiveNodes
      bool removed = inactiveNodes.remove(tokenId);
      require(removed, "Failed to remove from inactive list");

      // Lock the token again for a week
      chainNode.lock(tokenId, 604800); // 1 week
      lockRenewal[tokenId] = block.timestamp + 604800;

      // Add to activeNodes and activeNodeIdentifiers
      activeNodes[nodeId] = tokenId;
      activeNodeIdentifiers[tokenId] = nodeId;

      // Retrieve the latest pubkey
      require(node_keys[tokenId].length > 0, "No pubkey found");
      bytes memory pubkey = node_keys[tokenId][node_keys[tokenId].length - 1];

      // Call ChainState.activate
      chainState.activate(nodeId, pubkey);

      emit NodeActivated(nodeId, tokenId, pubkey);

    }

    /// @notice Deactivates an active node by moving it to the inactive list
    /// @param tokenId The ID of the ChainNode NFT to deactivate
    function setDeactivate(uint256 tokenId) external onlyOwner nonReentrant onlyActive(tokenId) {
        uint8 nodeId = activeNodeIdentifiers[tokenId];
        require(nodeId != 0, "Invalid node ID");

        // Call ChainState.deactivate
        chainState.deactivate(nodeId);

        // Remove from activeNodes and activeNodeIdentifiers
        activeNodes[nodeId] = 0;
        activeNodeIdentifiers[tokenId] = 0;

        // Add nodeId back to availableNodeIds
        availableNodeIds.add(nodeId);

        // Add to inactiveNodes
        bool added = inactiveNodes.add(tokenId);
        require(added, "Failed to add to inactive list");

        emit NodeDeactivated(nodeId, tokenId);
    }

    event DEBUG(string,uint256,uint256);
    /// @notice Processes epoch updates from ChainState to manage consensus participation
    /// @param consensus_mask Mask indicating nodes in consensus
    /// @param or_mask Mask indicating nodes seen in the current epoch
    /// @param and_mask Mask indicating nodes that participated in all blocks of the epoch
    /// @param visible_mask0 Latest visibility mask
    /// @param hist_visible_mask Array of historical visibility masks
    /// @return emergency_mask Updated emergency mask
    /// @return next_mask Updated next consensus mask
    function epoch_update(
      uint256 consensus_mask,
      uint256 or_mask,
      uint256 and_mask,
      uint256 visible_mask0,
      uint256[] calldata hist_visible_mask,
      uint8 desired_consensus_nodes,
      uint8 current_minsig
    ) external onlyChainState nonReentrant returns (uint256 emergency_mask, uint256 next_mask) {
      emit EpochUpdate(consensus_mask, or_mask, and_mask, visible_mask0, hist_visible_mask);

      // Calculate alive nodes based on consensus_mask, or_mask, and visible_mask0
      uint256 alive_mask = consensus_mask & visible_mask0;
      uint8 alive_count = uint8(popcnt(alive_mask));
      uint256 updated_consensus_mask = alive_mask;

      emit DEBUG("alive_count",alive_count,desired_consensus_nodes);
      // If alive nodes are less than desired_consensus_nodes, add new nodes
      if (alive_count < desired_consensus_nodes) {
        uint8 nodes_to_add = desired_consensus_nodes - alive_count;
        if (nodes_to_add > (max_nodes - alive_count)) {
          nodes_to_add = max_nodes - alive_count;
        }

        // Select eligible nodes to add based on visibility priority, excluding those already in consensus
        uint256 selected_nodes_mask = _selectEligibleNodes(nodes_to_add, consensus_mask, visible_mask0, hist_visible_mask);
        emit DEBUG("eligible",nodes_to_add,selected_nodes_mask);

        // Iterate through the selected_nodes_mask and update the consensus_mask
        for (uint8 nodeId = 1; nodeId <= MAX_NODE_ID; nodeId++) {
          if (((selected_nodes_mask >> (nodeId -1 )) & 1) == 1) {
            updated_consensus_mask |= (1 << (nodeId - 1));
            alive_count++;
            if (alive_count >= desired_consensus_nodes) break;
          }
        }
      }

      // Determine which mask to update based on alive_count and minsig
      if (alive_count <= current_minsig) {
        // Update emergency_mask
        emergency_mask = updated_consensus_mask;
        next_mask = 0;
      } else {
        // Update next_mask
        next_mask = updated_consensus_mask;
        emergency_mask = 0;
      }

      return (emergency_mask, next_mask);
    }

   

    /// @notice Internal function to remove a node from consensus
    /// @param nodeId The ID of the node to remove
    /// @param tokenId The token ID of the node
    function _removeFromConsensus(uint8 nodeId, uint256 tokenId) internal {
        // Deactivate the node
        chainState.deactivate(nodeId);

        // Remove from activeNodes and activeNodeIdentifiers
        activeNodes[nodeId] = 0;
        activeNodeIdentifiers[tokenId] = 0;

        // Add nodeId back to availableNodeIds
        availableNodeIds.add(nodeId);

        // Add to inactiveNodes
        inactiveNodes.add(tokenId);

        emit NodeDeactivated(nodeId, tokenId);
    }

    /// @notice Internal function to replace dead nodes with eligible nodes
    function _replaceDeadNodes() internal {
        // Calculate the current number of active nodes
        uint8 currentActive = 0;
        for (uint8 i = 1; i <= MAX_NODE_ID; i++) {
            if (activeNodes[i] != 0) {
                currentActive++;
            }
        }

        // Determine how many nodes need to be activated
        if (currentActive < min_nodes) {
            uint8 nodesToActivate = min_nodes - currentActive;
            nodesToActivate = nodesToActivate > (max_nodes - currentActive) ? (max_nodes - currentActive) : nodesToActivate;

            for (uint8 i = 0; i < nodesToActivate; i++) {
                if (inactiveNodes.length() == 0) break;

                uint256 tokenId = inactiveNodes.at(0);
                inactiveNodes.remove(tokenId);
                setActivate(tokenId);
            }
        }
    }

    /// @notice Internal function to select eligible nodes based on visibility priority
    /// @param nodes_to_add The number of nodes to add
    /// @param consensus_mask Current consensus mask to exclude nodes already in consensus
    /// @param visible_mask0 Current epoch visibility mask
    /// @param hist_visible_mask Historical visibility masks
    /// @return selected_nodes_mask Bitmask representing selected node IDs
    function _selectEligibleNodes(
      uint8 nodes_to_add,
      uint256 consensus_mask,
      uint256 visible_mask0,
      uint256[] calldata hist_visible_mask
    ) internal returns (uint256 selected_nodes_mask) {
      selected_nodes_mask = 0;
      uint8 count = 0;

      // Iterate through all active nodes
      for (uint8 nodeId = 1; nodeId <= MAX_NODE_ID; nodeId++) {
        uint256 tokenId = activeNodes[nodeId];
        if (tokenId == 0) continue; // Skip if node is not active
        emit DEBUG("sel",nodeId,tokenId);

        // Check if node is already in consensus
        if (((consensus_mask >> (nodeId - 1)) & 1) == 1) {
          continue; // Skip nodes already in consensus
        }

        // Check if node is alive based on visible_mask0 and hist_visible_mask
        bool is_visible = ((visible_mask0 >> (nodeId - 1)) & 1) == 1;
        if (!is_visible) continue; // Node is not visible in current epoch

        // Calculate visibility score based on hist_visible_mask
        uint8 visibility_score = 0;
        for (uint8 i = 0; i < hist_visible_mask.length; i++) {
          if (((hist_visible_mask[i] >> (nodeId - 1)) & 1) == 1) {
            visibility_score++;
          }
        }

        // Consider nodes with at least 2 epochs of visibility
        if (visibility_score >= 2) {
          selected_nodes_mask |= (1 << (nodeId - 1));
          count++;
          if (count >= nodes_to_add) break;
        }
      }
    }

    /// @notice Allows the owner to manually trigger lock renewal for active nodes
    /// @param tokenId The ID of the ChainNode NFT to renew lock
    function renewLock(uint256 tokenId) external onlyOwner nonReentrant onlyActive(tokenId) {
        // Check if the current lock has expired
        require(block.timestamp >= lockRenewal[tokenId], "Lock not yet expired");

        // Renew the lock for another week
        chainNode.lock(tokenId, 604800); // 1 week
        lockRenewal[tokenId] = block.timestamp + 604800;

        // No event emitted for lock renewal
    }

    /// @notice Allows the owner to set the ChainState contract address
    /// @param _chainState Address of the new ChainState contract
    function setChainState(address _chainState) external onlyOwner {
        require(_chainState != address(0), "Invalid ChainState address");
        chainState = IChainState(_chainState);
    }

    /// @notice Allows the owner to set the ChainNode contract address
    /// @param _chainNode Address of the new ChainNode contract
    function setChainNode(address _chainNode) external onlyOwner {
        require(_chainNode != address(0), "Invalid ChainNode address");
        chainNode = IChainNode(_chainNode);
    }
}

