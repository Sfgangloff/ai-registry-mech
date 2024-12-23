// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BalanceTrackerFixedPriceBase, ZeroAddress, NoDepositAllowed, TransferFailed} from "./BalanceTrackerFixedPriceBase.sol";
import {IMech} from "./interfaces/IMech.sol";

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

    /// @dev Gets the amount of tokens owned by a specified account.
    /// @param account Account address.
    /// @return Amount of tokens owned.
    function balanceOf(address account) external view returns (uint256);
}

contract BalanceTrackerFixedPriceNative is BalanceTrackerFixedPriceBase {
    // OLAS token address
    address public immutable olas;

    /// @dev BalanceTrackerFixedPrice constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _buyBackBurner Buy back burner address.
    /// @param _olas OLAS token address.
    constructor(address _mechMarketplace, address _buyBackBurner, address _olas)
        BalanceTrackerFixedPriceBase(_mechMarketplace, _buyBackBurner)
    {
        // Check for zero address
        if (_olas == address(0)) {
            revert ZeroAddress();
        }

        olas = _olas;
    }

    function _getOrRestrictNativeValue() internal virtual override returns (uint256) {
        // Check for msg.value
        if (msg.value > 0) {
            revert NoDepositAllowed(msg.value);
        }

        return 0;
    }

    function _getRequiredFunds(address requester, uint256 balanceDiff) internal virtual override returns (uint256) {
        uint256 balanceBefore = IToken(olas).balanceOf(address(this));
        // Get tokens from requester
        IToken(olas).transferFrom(requester, address(this), balanceDiff);
        uint256 balanceAfter = IToken(olas).balanceOf(address(this));

        // Check the balance
        uint256 diff = balanceAfter - balanceBefore;
        if (diff != balanceDiff) {
            revert TransferFailed(olas, requester, address(this), balanceDiff);
        }

        emit Deposit(msg.sender, olas, balanceDiff);

        return balanceDiff;
    }

    function _drain(uint256 amount) internal virtual override {
        // Transfer to Buy back burner
        IToken(olas).transfer(buyBackBurner, amount);

        emit Drained(olas, amount);
    }

    function _withdraw(uint256 balance) internal virtual override {
        bool success = IToken(olas).transfer(msg.sender, balance);

        // Check transfer
        if (!success) {
            revert TransferFailed(olas, address(this), msg.sender, balance);
        }

        emit Withdraw(msg.sender, olas, balance);
    }

    // Deposits token funds for requester.
    function deposit(uint256 amount) external {
        IToken(olas).transferFrom(msg.sender, address(this), amount);

        // Update account balances
        mapRequesterBalances[msg.sender] += amount;

        emit Deposit(msg.sender, olas, amount);
    }
}