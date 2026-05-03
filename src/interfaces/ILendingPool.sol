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
    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external returns (uint256 actualPaid);

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

    /**
     * @notice Deposit rewards into the vault with epoch-based vesting
     * @param amount The amount of reward tokens to deposit
     */
    function depositRewards(uint256 amount) external;

    /**
     * @notice Per-borrower outstanding principal denominated in `lendingAsset()`.
     * @dev Canonical input to collateral-manager debt sync. Implementations MUST aggregate
     *      across all loan positions the borrower holds. MUST NOT revert; return 0 if the
     *      borrower has no positions.
     * @param borrower The portfolio account address
     * @return The borrower's outstanding debt
     */
    function getDebtBalance(address borrower) external view returns (uint256);

    /**
     * @notice Effective per-borrower debt after accounting for any vault-side reward vesting
     *         that has not yet been settled to the underlying debt balance.
     * @dev For implementations without a separate "effective" notion, this MUST return the
     *      same value as `getDebtBalance(borrower)`. MUST NOT revert.
     * @param borrower The portfolio account address
     * @return The borrower's effective debt
     */
    function getEffectiveDebtBalance(address borrower) external view returns (uint256);
}
