// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ILendingPool
 * @notice Interface for lending pools that can be used by portfolio accounts
 * @dev Both LoanV2 and DynamicFeesVault implement this interface to allow
 *      the CollateralManager to interact with either lending source
 */
interface ILendingPool {
    /**
     * @notice Borrow funds from the lending pool on behalf of a portfolio account
     * @param amount The amount to borrow
     * @return originationFee The origination fee charged (deducted from amount transferred)
     */
    function borrowFromPortfolio(uint256 amount) external returns (uint256 originationFee);

    /**
     * @notice Repay funds to the lending pool from a portfolio account
     * @param totalPayment The total payment amount
     * @param feesToPay The portion of payment that goes to protocol fees
     */
    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external;

    /**
     * @notice Get the lending asset (e.g., USDC)
     * @return The address of the lending asset token
     */
    function lendingAsset() external view returns (address);

    /**
     * @notice Get the vault address where funds are stored
     * @return The vault address (may be self for DynamicFeesVault)
     */
    function lendingVault() external view returns (address);

    /**
     * @notice Get the total outstanding loaned assets
     * @return The total amount of assets currently loaned out
     */
    function activeAssets() external view returns (uint256);
}
