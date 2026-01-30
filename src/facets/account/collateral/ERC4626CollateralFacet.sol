// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {ERC4626CollateralManager} from "./ERC4626CollateralManager.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "./ICollateralFacet.sol";

/**
 * @title ERC4626CollateralFacet
 * @dev Facet for managing ERC4626 vault shares as collateral
 * Wraps the ERC4626CollateralManager library
 */
contract ERC4626CollateralFacet is AccessControl, ICollateralFacet {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;

    error InvalidVault();
    error InvalidShares();
    error InsufficientShares();

    constructor(address portfolioFactory, address portfolioAccountConfig) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(portfolioAccountConfig != address(0), "Invalid portfolio account config");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    /**
     * @dev Add ERC4626 vault shares as collateral
     * Shares must already be in the portfolio account wallet
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(address vault, uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        ERC4626CollateralManager.addCollateral(address(_portfolioAccountConfig), vault, shares);
    }

    /**
     * @dev Add ERC4626 vault shares as collateral by transferring from owner
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to transfer and add as collateral
     */
    function addCollateralFrom(address vault, uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(vault != address(0), "Invalid vault");
        require(shares > 0, "Shares must be > 0");

        address owner = _portfolioFactory.ownerOf(address(this));

        // Transfer shares from owner to this contract
        IERC20(vault).safeTransferFrom(owner, address(this), shares);

        // Add to collateral tracking
        ERC4626CollateralManager.addCollateral(address(_portfolioAccountConfig), vault, shares);
    }

    /**
     * @dev Remove ERC4626 vault shares from collateral
     * @param shares The amount of shares to remove
     */
    function removeCollateral(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        ERC4626CollateralManager.removeCollateral(address(_portfolioAccountConfig), shares);
    }

    /**
     * @dev Remove ERC4626 vault shares from collateral and transfer to owner
     * @param shares The amount of shares to remove and transfer
     */
    function removeCollateralTo(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address vault = ERC4626CollateralManager.getCollateralVault();
        require(vault != address(0), "No collateral vault set");

        // Remove from collateral tracking
        ERC4626CollateralManager.removeCollateral(address(_portfolioAccountConfig), shares);

        // Transfer shares to owner
        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(vault).safeTransfer(owner, shares);
    }

    // ============ View Functions ============

    /**
     * @dev Get total collateral value in underlying assets
     */
    function getTotalLockedCollateral() external view override returns (uint256) {
        return ERC4626CollateralManager.getTotalCollateralValue();
    }

    /**
     * @dev Get total debt
     */
    function getTotalDebt() external view override returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }

    /**
     * @dev Get unpaid fees
     */
    function getUnpaidFees() external view override returns (uint256) {
        return ERC4626CollateralManager.getUnpaidFees();
    }

    /**
     * @dev Get maximum loan amount
     */
    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return ERC4626CollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }

    /**
     * @dev Enforce collateral requirements
     */
    function enforceCollateralRequirements() external view override returns (bool success) {
        return ERC4626CollateralManager.enforceCollateralRequirements();
    }

    /**
     * @dev Get collateral info
     */
    function getCollateral() external view returns (
        address vault,
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        return ERC4626CollateralManager.getCollateral();
    }

    /**
     * @dev Get the collateral vault address
     */
    function getCollateralVault() external view returns (address) {
        return ERC4626CollateralManager.getCollateralVault();
    }

    /**
     * @dev Get collateral shares
     */
    function getCollateralShares() external view returns (uint256) {
        return ERC4626CollateralManager.getCollateralShares();
    }
}
