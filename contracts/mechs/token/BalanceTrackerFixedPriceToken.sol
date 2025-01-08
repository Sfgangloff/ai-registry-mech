// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BalanceTrackerFixedPriceBase, ZeroAddress} from "../../BalanceTrackerFixedPriceBase.sol";
import {IMech} from "../../interfaces/IMech.sol";

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

/// @dev No incoming msg.value is allowed.
/// @param amount Value amount.
error NoDepositAllowed(uint256 amount);

contract BalanceTrackerFixedPriceToken is BalanceTrackerFixedPriceBase {
    // Token address
    address public immutable token;

    /// @dev BalanceTrackerFixedPrice constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _buyBackBurner Buy back burner address.
    /// @param _token Token address.
    constructor(address _mechMarketplace, address _buyBackBurner, address _token)
        BalanceTrackerFixedPriceBase(_mechMarketplace, _buyBackBurner)
    {
        // Check for zero address
        if (_token == address(0)) {
            revert ZeroAddress();
        }

        token = _token;
    }

    /// @dev Drains specified amount.
    /// @param amount Token amount.
    function _drain(uint256 amount) internal virtual override {
        // Transfer to Buy back burner
        IToken(token).transfer(buyBackBurner, amount);

        emit Drained(token, amount);
    }

    /// @dev Gets native token value or restricts receiving one.
    /// @return Received value.
    function _getOrRestrictNativeValue() internal virtual override returns (uint256) {
        // Check for msg.value
        if (msg.value > 0) {
            revert NoDepositAllowed(msg.value);
        }

        return 0;
    }

    /// @dev Gets required token funds.
    /// @param requester Requester address.
    /// @param amount Token amount.
    /// @return Received amount.
    function _getRequiredFunds(address requester, uint256 amount) internal virtual override returns (uint256) {
        // Get tokens from requester
        IToken(token).transferFrom(requester, address(this), amount);

        emit Deposit(msg.sender, token, amount);

        return amount;
    }

    /// @dev Withdraws funds.
    /// @param account Account address.
    /// @param amount Token amount.
    function _withdraw(address account, uint256 amount) internal virtual override {
        // Transfer tokens
        IToken(token).transfer(account, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /// @dev Deposits token funds for requester.
    /// @param amount Token amount.
    function deposit(uint256 amount) external virtual {
        // Update account balances
        mapRequesterBalances[msg.sender] += amount;

        // Get tokens
        IToken(token).transferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount);
    }
}