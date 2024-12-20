// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMech} from "./interfaces/IMech.sol";

interface IMechMarketplace {
    function fee() external returns(uint256);
}

interface IToken {
    /// @dev Transfers the token amount.
    /// @param to Address to transfer to.
    /// @param amount The amount to transfer.
    /// @return True if the function execution is successful.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @dev Transfers the token amount that was previously approved up until the maximum allowance.
    /// @param from Account address to transfer from.
    /// @param to Account address to transfer to.
    /// @param amount Amount to transfer to.
    /// @return True if the function execution is successful.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
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

/// @dev No incoming msg.value is allowed.
/// @param amount Value amount.
error NoDepositAllowed(uint256 amount);

/// @dev Payload length is incorrect.
/// @param provided Provided payload length.
/// @param expected Expected payload length.
error InvalidPayloadLength(uint256 provided, uint256 expected);

/// @dev Failure of a transfer.
/// @param token Address of a token.
/// @param from Address `from`.
/// @param to Address `to`.
/// @param amount Amount value.
error TransferFailed(address token, address from, address to, uint256 amount);

contract BalanceTrackerFixedPriceToken {
    event MechPaymentCalculated(address indexed mech, uint256 indexed requestId, uint256 deliveryRate, uint256 rateDiff);
    event Deposit(address indexed account, address indexed token, uint256 amount);
    event Withdraw(address indexed account, address indexed token, uint256 amount);
    event Drained(address indexed token, uint256 collectedFees);

    // Mech marketplace address
    address public immutable mechMarketplace;
    // OLAS token address
    address public immutable olas;
    // Buy back burner address
    address public immutable buyBackBurner;
    // Collected fees
    uint256 public collectedFees;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Map of requester => current debit balance
    mapping(address => uint256) public mapRequesterBalances;
    // Map of mech => => current debit balance
    mapping(address => uint256) public mapMechBalances;

    /// @dev BalanceTrackerFixedPrice constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _olas OLAS token address.
    /// @param _buyBackBurner Buy back burner address.
    constructor(address _mechMarketplace, address _olas, address _buyBackBurner) {
        // Check for zero address
        if (_mechMarketplace == address(0) || _olas == address(0) || _buyBackBurner == address(0)) {
            revert ZeroAddress();
        }

        mechMarketplace = _mechMarketplace;
        olas = _olas;
        buyBackBurner = _buyBackBurner;
    }

    // Check and record delivery rate
    function checkAndRecordDeliveryRate(
        address mech,
        address requester,
        uint256
    ) external payable {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Check for msg.value
        if (msg.value > 0) {
            revert NoDepositAllowed(msg.value);
        }

        // Get mech max delivery rate
        uint256 maxDeliveryRate = IMech(mech).maxDeliveryRate();

        // Get account balance
        uint256 balance = mapRequesterBalances[requester];

        // Check the request delivery rate for a fixed price
        if (balance < maxDeliveryRate) {
            // Get balance difference
            uint256 balanceDiff = maxDeliveryRate - balance;
            // Get required funds
            IToken(olas).transferFrom(requester, address(this), balanceDiff);
        }

        // Adjust account balance
        balance -= maxDeliveryRate;
        mapRequesterBalances[requester] = balance;
    }

    /// @dev Finalizes mech delivery rate based on requested and actual ones.
    /// @param mech Delivery mech address.
    /// @param requester Requester address.
    /// @param requestId Request Id.
    /// @param maxDeliveryRate Requested max delivery rate.
    function finalizeDeliveryRate(address mech, address requester, uint256 requestId, uint256 maxDeliveryRate) external {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Get actual delivery rate
        uint256 actualDeliveryRate = IMech(mech).getFinalizedDeliveryRate(requestId);

        // Check for zero value
        if (actualDeliveryRate == 0) {
            revert ZeroValue();
        }

        uint256 rateDiff;
        if (maxDeliveryRate > actualDeliveryRate) {
            // Return back requester overpayment debit
            rateDiff = maxDeliveryRate - actualDeliveryRate;
            mapRequesterBalances[requester] += rateDiff;
        } else {
            actualDeliveryRate = maxDeliveryRate;
        }

        // Record payment into mech balance
        mapMechBalances[mech] += actualDeliveryRate;

        emit MechPaymentCalculated(mech, requestId, actualDeliveryRate, rateDiff);
    }

    /// @dev Drains collected fees by sending them to a Buy back burner contract.
    function drain() external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        uint256 localCollectedFees = collectedFees;

        // TODO Limits
        // Check for zero value
        if (localCollectedFees == 0) {
            revert ZeroValue();
        }

        collectedFees = 0;

        // Transfer to Buy back burner
        IToken(olas).transfer(buyBackBurner, localCollectedFees);

        emit Drained(olas, localCollectedFees);

        _locked = 1;
    }

    function _withdraw(uint256 balance) internal {
        bool success = IToken(olas).transfer(msg.sender, balance);

        // Check transfer
        if (!success) {
            revert TransferFailed(olas, address(this), msg.sender, balance);
        }
    }

    /// @dev Processes mech payment by withdrawing funds.
    function processPayment() external returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get mech balance
        uint256 balance = mapMechBalances[msg.sender];
        // TODO limits?
        if (balance == 0) {
            revert ZeroValue();
        }

        // Calculate mech payment and marketplace fee
        uint256 fee = IMechMarketplace(mechMarketplace).fee();
        marketplaceFee = (balance * fee) / 10_000;
        mechPayment = balance - marketplaceFee;

        // Check for zero value, although this must never happen
        if (mechPayment == 0) {
            revert ZeroValue();
        }

        // Adjust marketplace fee
        collectedFees += marketplaceFee;

        // Clear balances
        mapMechBalances[msg.sender] = 0;

        // Process withdraw
        _withdraw(balance);

        emit Withdraw(msg.sender, olas, balance);

        _locked = 1;
    }

    /// @dev Withdraws funds for a specific requester account.
    function withdraw() external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get account balance
        uint256 balance = mapRequesterBalances[msg.sender];
        // TODO limits?
        if (balance == 0) {
            revert ZeroValue();
        }

        // Clear balances
        mapRequesterBalances[msg.sender] = 0;

        // Process withdraw
        _withdraw(balance);

        emit Withdraw(msg.sender, olas, balance);

        _locked = 1;
    }

    // Deposits token funds for requester.
    function deposit(uint256 amount) external {
        IToken(olas).transferFrom(msg.sender, address(this), amount);

        // Update account balances
        mapRequesterBalances[msg.sender] += amount;

        emit Deposit(msg.sender, olas, amount);
    }
}