// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMech} from "./interfaces/IMech.sol";

interface IMechMarketplace {
    function fee() external view returns(uint256);
}

/// @dev Only `marketplace` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param marketplace Required marketplace address.
error MarketplaceOnly(address sender, address marketplace);

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @dev Not enough balance to cover costs.
/// @param current Current balance.
/// @param required Required balance.
error InsufficientBalance(uint256 current, uint256 required);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev Failure of a transfer.
/// @param token Address of a token.
/// @param from Address `from`.
/// @param to Address `to`.
/// @param amount Amount value.
error TransferFailed(address token, address from, address to, uint256 amount);

abstract contract BalanceTrackerBase {
    event RequesterBalanceAdjusted(address indexed requester, uint256 deliveryRate, uint256 balance);
    event MechBalanceAdjusted(address indexed mech, uint256 deliveryRate, uint256 balance, uint256 rateDiff);
    event Deposit(address indexed account, address indexed token, uint256 amount);
    event Withdraw(address indexed account, address indexed token, uint256 amount);
    event Drained(address indexed token, uint256 collectedFees);

    // Max marketplace fee factor (100%)
    uint256 public constant MAX_FEE_FACTOR = 10_000;

    // Mech marketplace address
    address public immutable mechMarketplace;
    // Buy back burner address
    address public immutable buyBackBurner;
    // Collected fees
    uint256 public collectedFees;
    // Reentrancy lock
    bool internal locked;
// TODO
//bool transient locked;

    // Map of requester => current balance
    mapping(address => uint256) public mapRequesterBalances;
    // Map of mech => => current balance
    mapping(address => uint256) public mapMechBalances;

    /// @dev BalanceTrackerFixedPrice constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _buyBackBurner Buy back burner address.
    constructor(address _mechMarketplace, address _buyBackBurner) {
        // Check for zero address
        if (_mechMarketplace == address(0) || _buyBackBurner == address(0)) {
            revert ZeroAddress();
        }

        mechMarketplace = _mechMarketplace;
        buyBackBurner = _buyBackBurner;
    }

    /// @dev Adjusts initial requester balance accounting for delivery rate (debit).
    /// @param balance Initial requester balance.
    /// @param deliveryRate Delivery rate.
    function _adjustInitialBalance(
        address requester,
        uint256 balance,
        uint256 deliveryRate,
        bytes memory
    ) internal virtual returns (uint256) {
        // Check the request delivery rate for a fixed price
        if (balance < deliveryRate) {
            // Get balance difference
            uint256 balanceDiff = deliveryRate - balance;
            // Adjust balance
            balance += _getRequiredFunds(requester, balanceDiff);
        }

        if (balance < deliveryRate) {
            revert InsufficientBalance(balance, deliveryRate);
        }

        // Adjust account balance
        return (balance - deliveryRate);
    }

    /// @dev Adjusts final requester balance accounting for possible delivery rate difference (debit).
    /// @param requester Requester address.
    /// @param rateDiff Delivery rate difference.
    /// @return Adjusted balance.
    function _adjustFinalBalance(address requester, uint256 rateDiff) internal virtual returns (uint256) {
        return mapRequesterBalances[requester] + rateDiff;
    }

    /// @dev Drains specified amount.
    /// @param amount Amount value.
    function _drain(uint256 amount) internal virtual;

    /// @dev Gets fee composed of marketplace fee and another one, if applicable.
    function _getFee() internal view virtual returns (uint256) {
        return IMechMarketplace(mechMarketplace).fee();
    }

    /// @dev Gets native token value or restricts receiving one.
    /// @return Received value.
    function _getOrRestrictNativeValue() internal virtual returns (uint256);

    /// @dev Gets required token funds.
    /// @param requester Requester address.
    /// @param amount Token amount.
    /// @return Received amount.
    function _getRequiredFunds(address requester, uint256 amount) internal virtual returns (uint256);

    /// @dev Process mech payment.
    /// @param mech Mech address.
    /// @return mechPayment Mech payment.
    /// @return marketplaceFee Marketplace fee.
    function _processPayment(address mech) internal virtual returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Get mech balance
        uint256 balance = mapMechBalances[mech];
        // If balance is 1, the marketplace fee is still 1, and thus mech payment will be zero
        if (balance < 2) {
            revert ZeroValue();
        }

        // Calculate mech payment and marketplace fee
        uint256 fee = _getFee();

        // If requested balance is too small, charge the minimal fee
        // ceil(a, b) = (a + b - 1) / b
        // This formula will always get at least a fee of 1
        marketplaceFee = (balance * fee + (MAX_FEE_FACTOR - 1)) / MAX_FEE_FACTOR;

        // Calculate mech payment
        mechPayment = balance - marketplaceFee;

        // Check for zero value, although this must never happen
        if (marketplaceFee == 0 || mechPayment == 0) {
            revert ZeroValue();
        }

        // Adjust marketplace fee
        collectedFees += marketplaceFee;

        // Clear balances
        mapMechBalances[mech] = 0;

        // Process withdraw
        _withdraw(mech, mechPayment);
    }

    /// @dev Withdraws funds.
    /// @param account Account address.
    /// @param amount Token amount.
    function _withdraw(address account, uint256 amount) internal virtual;

    /// @dev Checks and records delivery rate.
    /// @param requester Requester address.
    /// @param numRequests Number of requests.
    /// @param deliveryRate Single request delivery rate.
    /// @param paymentData Additional payment-related request data, if applicable.
    function checkAndRecordDeliveryRates(
        address requester,
        uint256 numRequests,
        uint256 deliveryRate,
        bytes memory paymentData
    ) external virtual payable {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Check for native value
        uint256 initAmount = _getOrRestrictNativeValue();

        // Get account balance
        uint256 balance = mapRequesterBalances[requester] + initAmount;

        // Total requester delivery rate is number of requests coming to a selected mech
        uint256 totalDeliveryRate = deliveryRate * numRequests;

        // Adjust account balance
        balance = _adjustInitialBalance(requester, balance, totalDeliveryRate, paymentData);
        mapRequesterBalances[requester] = balance;

        emit RequesterBalanceAdjusted(requester, totalDeliveryRate, balance);
    }

    /// @dev Finalizes mech delivery rate based on requested and actual ones.
    /// @param mech Delivery mech address.
    /// @param requesters Requester addresses.
    /// @param deliveredRequests Set of mech request Id statuses: delivered / undelivered.
    /// @param mechDeliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param requesterDeliveryRates Corresponding set of requester agreed delivery rates for each request.
    function finalizeDeliveryRates(
        address mech,
        address[] memory requesters,
        bool[] memory deliveredRequests,
        uint256[] memory mechDeliveryRates,
        uint256[] memory requesterDeliveryRates
    ) external virtual {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        uint256 numRequests = deliveredRequests.length;
        uint256 balance;

        // Get total mech and requester delivery rates
        uint256 totalMechDeliveryRate;
        uint256 totalRequesterDeliveryRate;
        uint256 totalRateDiff;
        for (uint256 i = 0; i < numRequests; ++i) {
            // Check if request was delivered
            if (deliveredRequests[i]) {
                totalMechDeliveryRate += mechDeliveryRates[i];
                totalRequesterDeliveryRate += requesterDeliveryRates[i];

                // Check for delivery rate difference
                uint256 rateDiff;
                if (requesterDeliveryRates[i] > mechDeliveryRates[i]) {
                    // Return back requester overpayment debit / credit
                    rateDiff = requesterDeliveryRates[i] - mechDeliveryRates[i];
                    totalRateDiff += rateDiff;

                    // Adjust requester balance
                    balance = _adjustFinalBalance(requesters[i], rateDiff);
                    mapRequesterBalances[requesters[i]] = balance;
                }
            }
        }

        // Check for zero value
        if (totalMechDeliveryRate == 0) {
            revert ZeroValue();
        }

        // Record payment into mech balance
        balance = mapMechBalances[mech];
        balance += totalMechDeliveryRate;
        mapMechBalances[mech] = balance;

        emit MechBalanceAdjusted(mech, totalMechDeliveryRate, balance, totalRateDiff);
    }

    /// @dev Adjusts mech and requester balances for direct batch request processing.
    /// @notice This function can be called by the Mech Marketplace only.
    /// @param mech Mech address.
    /// @param requester Requester address.
    /// @param mechDeliveryRates Set of actual charged delivery rates for each request.
    function adjustMechRequesterBalances(
        address mech,
        address requester,
        uint256[] memory mechDeliveryRates,
        bytes memory
    ) external virtual {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        // Get total mech delivery rate
        uint256 totalMechDeliveryRate;
        for (uint256 i = 0; i < mechDeliveryRates.length; ++i) {
            totalMechDeliveryRate += mechDeliveryRates[i];
        }

        // Get requester balance
        uint256 requesterBalance = mapRequesterBalances[requester];
        // Check requester balance
        if (requesterBalance < totalMechDeliveryRate) {
            revert InsufficientBalance(requesterBalance, totalMechDeliveryRate);
        }
        // Adjust requester balance
        requesterBalance -= totalMechDeliveryRate;
        mapRequesterBalances[requester] = requesterBalance;

        // Record payment into mech balance
        uint256 mechBalance = mapMechBalances[mech];
        mechBalance += totalMechDeliveryRate;
        mapMechBalances[mech] = mechBalance;

        emit RequesterBalanceAdjusted(requester, totalMechDeliveryRate, requesterBalance);
        emit MechBalanceAdjusted(mech, totalMechDeliveryRate, mechBalance, 0);
    }

    /// @dev Drains collected fees by sending them to a Buy back burner contract.
    function drain() external {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        uint256 localCollectedFees = collectedFees;

        // Check for zero value
        if (localCollectedFees == 0) {
            revert ZeroValue();
        }

        collectedFees = 0;

        // Drain
        _drain(localCollectedFees);
    }

    /// @dev Processes mech payment by mech service multisig.
    /// @param mech Mech address.
    /// @return mechPayment Mech payment.
    /// @return marketplaceFee Marketplace fee.
    function processPaymentByMultisig(address mech) external returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        // Check for mech service multisig address
        if (!IMech(mech).isOperator(msg.sender)) {
            revert UnauthorizedAccount(msg.sender);
        }

        (mechPayment, marketplaceFee) = _processPayment(mech);
    }

    /// @dev Processes mech payment.
    /// @return mechPayment Mech payment.
    /// @return marketplaceFee Marketplace fee.
    function processPayment() external returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Reentrancy guard
        if (locked) {
            revert ReentrancyGuard();
        }
        locked = true;

        (mechPayment, marketplaceFee) = _processPayment(msg.sender);
    }
}