// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OlasMech} from "../../OlasMech.sol";

interface IERC1155 {
    /// @dev Gets the amount of tokens owned by a specified account.
    /// @param account Account address.
    /// @param tokenId Token Id.
    /// @return Amount of tokens owned.
    function balanceOf(address account, uint256 tokenId) external view returns (uint256);

    /// @dev Burns a specified amount of account's tokens.
    /// @param account Account address.
    /// @param tokenId Token Id.
    /// @param amount Amount of tokens.
    function burn(address account, uint256 tokenId, uint256 amount) external;
}

/// @dev Provided zero subscription address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @title AgentMechSubscription - Smart contract for extending AgentMech with subscription
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token via a subscription.
contract MechNeverminedSubscription is OlasMech {
    event DeliveryRateFinalized(uint256 indexed requestId, uint256 deliveryRate);

    // Mapping for requestId => finalized delivery rates
    mapping(uint256 => uint256) public mapRequestIdFinalizedRates;

    /// @dev AgentMechSubscription constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _serviceRegistry Address of the token contract.
    /// @param _serviceId Service Id.
    /// @param _maxDeliveryRate The maximum delivery rate.
    constructor(
        address _mechMarketplace,
        address _serviceRegistry,
        uint256 _serviceId,
        uint256 _maxDeliveryRate
    )
        OlasMech(_mechMarketplace, _serviceRegistry, _serviceId, _maxDeliveryRate, MechType.Subscription)
    {}

    /// @dev Performs actions before the delivery of a request.
    /// @param account Request sender address.
    /// @param requestId Request Id.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestData Data for the request processing.
    function _preDeliver(
        address account,
        uint256 requestId,
        bytes memory data
    ) internal override returns (bytes memory requestData) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Extract the request deliver rate as credits to burn
        uint256 creditsToBurn;
        (creditsToBurn, requestData) = abi.decode(data, (uint256, bytes));

        mapRequestIdFinalizedRates[requestId] = creditsToBurn;

        // TODO: mocks, get subscriptionNFT and subscriptionTokenId from marketplace
        address subscriptionNFT = address(1);
        uint256 subscriptionTokenId = 1;
        // Check for the number of credits available in the subscription
        uint256 creditsBalance = IERC1155(subscriptionNFT).balanceOf(account, subscriptionTokenId);

        // Adjust the amount of credits to burn if the deliver price is bigger than the amount of credits available
        if (creditsToBurn > creditsBalance) {
            creditsToBurn = creditsBalance;
        }

        // Burn credits of the request Id sender upon delivery
        if (creditsToBurn > 0) {
            IERC1155(subscriptionNFT).burn(account, subscriptionTokenId, creditsToBurn);
        }

        emit DeliveryRateFinalized(requestId, creditsToBurn);

        _locked = 1;
    }

    /// @dev Gets finalized delivery rate for a request Id.
    /// @param requestId Request Id.
    /// @return Finalized delivery rate.
    function getFinalizedDeliveryRate(uint256 requestId) external virtual override returns (uint256) {
        return mapRequestIdFinalizedRates[requestId];
    }
}
