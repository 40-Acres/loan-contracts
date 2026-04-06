// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title NoOpVault
 * @notice A minimal no-op vault for relayer portfolio accounts that hold collateral
 *         but never take on debt. Satisfies ILendingPool + PortfolioFactoryConfig
 *         requirements without any actual lending logic.
 */
contract NoOpVault is ILendingPool {
    address public immutable portfolioFactory;
    address public immutable underlyingAsset;

    error Disabled();

    constructor(address portfolioFactory_, address asset_) {
        portfolioFactory = portfolioFactory_;
        underlyingAsset = asset_;
    }

    // ============ ILendingPool (all no-ops) ============

    function borrowFromPortfolio(uint256) external pure returns (uint256) {
        revert Disabled();
    }

    function payFromPortfolio(uint256, uint256) external pure returns (uint256) {
        revert Disabled();
    }

    function repayWithRewards(uint256) external pure {
        revert Disabled();
    }

    function lendingAsset() external view returns (address) {
        return underlyingAsset;
    }

    function lendingVault() external view returns (address) {
        return address(this);
    }

    function activeAssets() external pure returns (uint256) {
        return 0;
    }

    // ============ ILoan compatibility (used by PortfolioFactoryConfig) ============

    function _vault() external view returns (address) {
        return address(this);
    }

    function _asset() external view returns (address) {
        return underlyingAsset;
    }

    // ============ ERC4626-like view (used by getMaxLoan) ============

    function asset() external view returns (address) {
        return underlyingAsset;
    }

    // ============ Factory binding (used by setLoanContract validation) ============

    function getPortfolioFactory() external view returns (address) {
        return portfolioFactory;
    }
}
