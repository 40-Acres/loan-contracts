// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/**
 * @title IFeeCalculator
 * @notice Interface for fee curve calculators used by DebtToken
 * @dev Implement this interface to create custom fee curves
 */
interface IFeeCalculator {
    /**
     * @notice Calculates the vault ratio (fee percentage) based on utilization
     * @param utilizationBps The utilization rate in basis points (0-10000)
     * @return rate The vault ratio in basis points (fee that goes to lenders)
     */
    function getVaultRatioBps(uint256 utilizationBps) external view returns (uint256 rate);
}
