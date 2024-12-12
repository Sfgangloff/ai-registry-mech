// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GenericManager} from "../lib/autonolas-registries/contracts/GenericManager.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";

interface IAgentRegistry {
    /// @dev Creates a agent.
    /// @param agentOwner Owner of the agent.
    /// @param agentHash IPFS CID hash of the agent metadata.
    /// @return agentId The id of a minted agent.
    function create(address agentOwner, bytes32 agentHash) external returns (uint256 agentId);
}

/// @title Agent Factory - Periphery smart contract for managing agent and mech creation
contract AgentFactory is GenericManager {


    // Agent factory version number
    string public constant VERSION = "1.1.0";

    // Service registry address
    address public immutable serviceRegistry;

    constructor(address _serviceRegistry) {
        serviceRegistry = _serviceRegistry;
        owner = msg.sender;
    }
}
