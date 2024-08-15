// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AgentMech} from "./AgentMech.sol";
import {GenericManager} from "../lib/autonolas-registries/contracts/GenericManager.sol";

interface IAgentRegistry {
    /// @dev Creates a agent.
    /// @param agentOwner Owner of the agent.
    /// @param agentHash IPFS CID hash of the agent metadata.
    /// @return agentId The id of a minted agent.
    function create(address agentOwner, bytes32 agentHash) external returns (uint256 agentId);
}

interface ImechMarketplace {
    function setRegisterMechStatus(address mech, bool status) external;
}

/// @title Agent Factory - Periphery smart contract for managing agent and mech creation
contract AgentFactory is GenericManager {
    event CreateMech(address indexed mech, uint256 indexed agentId, uint256 indexed price);

    // Agent factory version number
    string public constant VERSION = "1.1.0";

    // Agent registry address
    address public immutable agentRegistry;

    constructor(address _agentRegistry) {
        agentRegistry = _agentRegistry;
        owner = msg.sender;
    }

    /// @dev Creates agent.
    /// @param mechMarketplace Mech marketplace address.
    /// @param agentOwner Owner of the agent.
    /// @param agentHash IPFS CID hash of the agent metadata.
    /// @param price Minimum required payment the agent accepts.
    /// @return agentId The id of a created agent.
    /// @return mech The created mech instance address.
    function create(
        address mechMarketplace,
        address agentOwner,
        bytes32 agentHash,
        uint256 price
    ) external returns (uint256 agentId, address mech)
    {
        // Check if the creation is paused
        if (paused) {
            revert Paused();
        }

        agentId = IAgentRegistry(agentRegistry).create(agentOwner, agentHash);
        bytes32 salt = keccak256(abi.encode(agentOwner, agentId));
        // agentOwner is isOperator() for the mech
        mech = _createMech(salt, mechMarketplace, agentRegistry, mechMarketplace, agentId, price);
        // Register mech in a specified marketplace
        ImechMarketplace(mechMarketplace).setRegisterMechStatus(mech, true);
        emit CreateMech(mech, agentId, price);
    }

    /// @dev Creates the mech instance.
    /// @param salt The generated salt.
    /// @param mechMarketplace Mech marketplace address.
    /// @param _agentRegistry The agent registry address.
    /// @param agentId The id of a created agent.
    /// @param price Minimum required payment the agent accepts.
    /// @return mech The created mech instance address.
    function _createMech(
        bytes32 salt,
        address mechMarketplace,
        address agentRegistry,
        uint256 agentId,
        uint256 price
    ) internal virtual returns (address mech) {
        mech = address((new AgentMech){salt: salt}(mechMarketplace, agentRegistry, agentId, price));
    }
}
