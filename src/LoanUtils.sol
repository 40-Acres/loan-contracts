// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";

library LoanUtils {
    function getMaxLoanByRewardsRate(
        uint256 veBalance,
        uint256 rewardsRate,
        uint256 multiplier,
        uint256 vaultBalance,
        uint256 outstandingCapital,
        uint256 currentLoanBalance
    ) public pure returns (uint256, uint256) {
        // Calculate the maximum loan ignoring vault supply constraints
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) *
            multiplier) / 1e12; // rewardsRate * veNFT balance of token

        // Calculate the maximum utilization ratio (80% of the vault supply)
        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        // If the vault is over-utilized, no loans can be made
        if (outstandingCapital >= maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        // If the current loan balance exceeds the maximum capacity, no additional loans can be made
        if (currentLoanBalance >= maxLoanIgnoreSupply) {
            return (0, maxLoanIgnoreSupply);
        }

        // Calculate remaining headroom under LTV
        uint256 maxLoan = maxLoanIgnoreSupply - currentLoanBalance;

        // Ensure the loan amount does not exceed the available vault supply
        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        // Ensure the loan amount does not exceed the vault's current balance
        if (maxLoan > vaultBalance) {
            maxLoan = vaultBalance;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }

    function getMaxLoanByLtv(
        uint256 veBalance,
        uint256 ltv,
        uint256 vaultBalance,
        uint256 outstandingCapital,
        uint256 currentLoanBalance
    ) public pure returns (uint256, uint256) {
        // Calculate the maximum loan ignoring vault supply constraints
        uint256 maxLoanIgnoreSupply = (veBalance * ltv) / 10000; // ltv * veNFT balance of token

        // Calculate the maximum utilization ratio (80% of the vault supply)
        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        // If the vault is over-utilized, no loans can be made
        if (outstandingCapital >= maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        // If the current loan balance exceeds the maximum capacity, no additional loans can be made
        if (currentLoanBalance >= maxLoanIgnoreSupply) {
            return (0, maxLoanIgnoreSupply);
        }

        // Calculate remaining headroom under LTV
        uint256 maxLoan = maxLoanIgnoreSupply - currentLoanBalance;

        // Ensure the loan amount does not exceed the available vault supply
        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        // Ensure the loan amount does not exceed the vault's current balance
        if (maxLoan > vaultBalance) {
            maxLoan = vaultBalance;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }
}
