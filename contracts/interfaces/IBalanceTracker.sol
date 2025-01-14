// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Escrow interface
interface IBalanceTracker {
    /// @dev Checks and records delivery rate.
    /// @param requester Requester address.
    /// @param maxDeliveryRate Request max delivery rate.
    /// @param paymentData Additional payment-related request data, if applicable.
    function checkAndRecordDeliveryRate(address requester, uint256 maxDeliveryRate, bytes memory paymentData) external payable;

    /// @dev Finalizes mech delivery rate based on requested and actual ones.
    /// @param mech Delivery mech address.
    /// @param requester Requester address.
    /// @param requestId Request Id.
    /// @param deliveryRate Requested delivery rate.
    function finalizeDeliveryRate(address mech, address requester, uint256 requestId, uint256 deliveryRate) external;

    /// @dev Adjusts requester and mech balances for direct batch request processing.
    /// @param mech Mech address.
    /// @param requester Requester address.
    /// @param totalDeliveryRate Total batch delivery rate.
    /// @param paymentData Additional payment-related request data, if applicable.
    function adjustRequesterMechBalances(address mech, address requester, uint256 totalDeliveryRate,
        bytes memory paymentData) external payable;
}