// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AgentMech} from "../../contracts/AgentMech.sol";

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
error ZeroSubscriptionAddress();

/// @dev Provided zero token Id.
error ZeroTokenId();

/// @dev No incoming msg.value is allowed.
/// @param amount Value amount.
error NoDepositAllowed(uint256 amount);

/// @dev Not enough credits to perform a request.
/// @param creditsBalance Credits balance of a sender.
/// @param creditsPerRequest Credits per request needed.
error NotEnoughCredits(uint256 creditsBalance, uint256 creditsPerRequest);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @title AgentMechSubscription - Smart contract for extending AgentMech with subscription
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token via a subscription.
contract AgentMechSubscription is AgentMech {
    event SubscriptionUpdated(address subscriptionNFT, uint256 subscriptionTokenId);

    // Subscription NFT
    address public subscriptionNFT;
    // Subscription token Id
    uint256 public subscriptionTokenId;
    // Reentrancy lock
    uint256 internal _locked = 1;

    /// @dev AgentMechSubscription constructor.
    /// @param _token Address of the token registry contract.
    /// @param _tokenId The token ID.
    /// @param _creditsPerRequest Number of credits to pay for request via subscription.
    /// @param _subscriptionNFT Subscription address.
    /// @param _subscriptionTokenId Subscription token Id.
    constructor(
        address _token,
        uint256 _tokenId,
        uint256 _creditsPerRequest,
        address _subscriptionNFT,
        uint256 _subscriptionTokenId
    )
        AgentMech(_token, _tokenId, _creditsPerRequest)
    {
        // Check for the subscription address
        if (_subscriptionNFT == address(0)) {
            revert ZeroSubscriptionAddress();
        }

        // Check for the subscription token Id
        if (_subscriptionTokenId == 0) {
            revert ZeroTokenId();
        }

        subscriptionNFT = _subscriptionNFT;
        subscriptionTokenId = _subscriptionTokenId;
    }

    /// @dev Performs actions before the request is posted.
    /// @param amount Amount of payment in wei.
    function _preRequest(uint256 amount, uint256, bytes memory) internal override {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check that there is no incoming deposit
        if (amount > 0) {
            revert NoDepositAllowed(amount);
        }

        // Check for the number of credits available in the subscription
        uint256 creditsBalance = IERC1155(subscriptionNFT).balanceOf(msg.sender, subscrptionTokenId);
        uint256 creditsPerRequest = price;
        if (creditsBalance < creditsPerRequest) {
            revert NotEnoughCredits(creditsBalance, creditsPerRequest);
        }

        _locked = 1;
    }

    /// @dev Performs actions before the delivery of a request.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestData Data for the request processing.
    function _preDeliver(uint256, bytes memory data) internal virtual returns (bytes memory requestData) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Burn credits of the request Id sender upon delivery
        IERC1155(subscriptionNFT).burn(mapRequestAddresses[requestId], subscrptionTokenId, price);

        // Return the request data
        requestData = data;

        _locked = 1;
    }

    /// @dev Sets the new subscription.
    /// @param subscriptionNFTAddress Address of the nft subscription.
    function setSubscription(address _subscriptionNFT, uint256 _subscriptionTokenId) external onlyOperator {
        // Check for the subscription address
        if (_subscriptionNFT == address(0)) {
            revert ZeroSubscriptionAddress();
        }

        // Check for the subscription token Id
        if (_subscriptionTokenId == 0) {
            revert ZeroTokenId();
        }

        subscriptionNFT = _subscriptionNFT;
        subscriptionTokenId = _subscriptionTokenId;

        emit SubscriptionUpdated(subscriptionNFT, subscriptionTokenId);
    }
}
