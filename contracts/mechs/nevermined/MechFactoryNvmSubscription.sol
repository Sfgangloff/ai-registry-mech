// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MechNvmSubscription} from "./MechNvmSubscription.sol";

/// @dev Incorrect data length.
/// @param provided Provided data length.
/// @param expected Expected data length.
error IncorrectDataLength(uint256 provided, uint256 expected);

/// @dev Only `marketplace` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param marketplace Required marketplace address.
error MarketplaceOnly(address sender, address marketplace);

/// @dev Provided zero address.
error ZeroAddress();

/// @title MechFactoryNvmSubscription - Periphery smart contract for managing Nevermined subscription mech creation
contract MechFactoryNvmSubscription {
    event CreateSubscriptionMech(address indexed mech, uint256 indexed serviceId, uint256 maxDeliveryRate);

    // Agent factory version number
    string public constant VERSION = "0.1.0";
    // Mech marketplace address
    address public immutable mechMarketplace;

    // Nonce
    uint256 internal _nonce;

    /// @dev MechFactoryFixedPriceNative constructor.
    /// @param _mechMarketplace Mech marketplace address.
    constructor(address _mechMarketplace) {
        mechMarketplace = _mechMarketplace;
    }

    /// @dev Registers service as a mech.
    /// @param serviceRegistry Service registry address.
    /// @param serviceId Service id.
    /// @param payload Mech creation payload.
    /// @return mech The created mech instance address.
    function createMech(
        address serviceRegistry,
        uint256 serviceId,
        bytes memory payload
    ) external returns (address mech) {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Check payload length
        if (payload.length != 32) {
            revert IncorrectDataLength(payload.length, 32);
        }

        // Decode subscription parameters
        uint256 maxDeliveryRate = abi.decode(payload, (uint256));

        uint256 localNonce = _nonce;
        // Get salt
        bytes32 salt = keccak256(abi.encode(block.timestamp, payload, serviceId, localNonce));
        _nonce = localNonce + 1;

        // Service multisig is isOperator() for the mech
        mech = address((new MechNvmSubscription){salt: salt}(mechMarketplace, serviceRegistry, serviceId,
            maxDeliveryRate));

        // Check for zero address
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        emit CreateSubscriptionMech(mech, serviceId, maxDeliveryRate);
    }
}
