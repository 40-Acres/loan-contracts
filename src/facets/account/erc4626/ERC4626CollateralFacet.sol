// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {ERC4626CollateralManager} from "./ERC4626CollateralManager.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";

/**
 * @title ERC4626CollateralFacet
 * @dev Facet for managing ERC4626 vault shares as collateral
 * Wraps the ERC4626CollateralManager library
 */
contract ERC4626CollateralFacet is AccessControl, ICollateralFacet {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IERC4626 public immutable _vault;

    error InvalidShares();
    error InsufficientShares();

    constructor(address portfolioFactory, address vault) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(vault != address(0), "Invalid vault");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _vault = IERC4626(vault);
    }

    /**
     * @dev Add ERC4626 vault shares as collateral
     * Shares must already be in the portfolio account wallet
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        ERC4626CollateralManager.addCollateral(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault), shares);
    }

    /**
     * @dev Add ERC4626 vault shares as collateral by transferring from owner
     * @param shares The amount of shares to transfer and add as collateral
     */
    function addCollateralFrom(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(shares > 0, "Shares must be > 0");

        address owner = _portfolioFactory.ownerOf(address(this));

        // Transfer shares from owner to this contract
        IERC20(address(_vault)).safeTransferFrom(owner, address(this), shares);

        // Add to collateral tracking
        ERC4626CollateralManager.addCollateral(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault), shares);
    }

    /**
     * @dev Remove ERC4626 vault shares from collateral to the owner's wallet
     * @param shares The amount of shares to remove
     */
    function removeCollateral(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);
        ERC4626CollateralManager.removeCollateral(config, address(_vault), shares);


        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(address(_vault)).safeTransfer(owner, shares);
    }

    /**
     * @dev Remove ERC4626 vault shares from collateral and transfer to the owner's account in another factory
     * @param shares The amount of shares to remove and transfer
     * @param targetPortfolioFactory The destination factory; shares go to the owner's account within it
     */
    function removeCollateralTo(uint256 shares, address targetPortfolioFactory) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);

        // Validate target factory is registered in the same PortfolioManager
        PortfolioManager portfolioManager = _portfolioFactory.portfolioManager();
        require(portfolioManager.isRegisteredFactory(targetPortfolioFactory), "Target factory not registered");

        address owner = _portfolioFactory.ownerOf(address(this));
        PortfolioFactory targetFactory = PortfolioFactory(targetPortfolioFactory);

        // Resolve the owner's account in the target factory, creating it if needed
        address toPortfolio = targetFactory.portfolioOf(owner);
        if (toPortfolio == address(0)) {
            toPortfolio = targetFactory.createAccount(owner);
        }

        ERC4626CollateralManager.removeCollateral(config, address(_vault), shares);
        IERC20(address(_vault)).safeTransfer(toPortfolio, shares);
    }

    // ============ View Functions ============

    /**
     * @dev Get total collateral value in underlying assets
     */
    function getTotalLockedCollateral() external view override returns (uint256) {
        return ERC4626CollateralManager.getTotalCollateralValue(address(_vault));
    }

    /**
     * @dev Get total debt
     */
    function getTotalDebt() external view override returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }

    /**
     * @dev Get maximum loan amount
     */
    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return ERC4626CollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault));
    }

    /**
     * @dev Enforce collateral requirements using live shortfall comparison.
     * Reverts if the position's shortfall increased during this block's operations.
     */
    function enforceCollateralRequirements() external view override returns (bool success) {
        return ERC4626CollateralManager.enforceCollateralRequirements(
            address(_portfolioFactory.portfolioFactoryConfig()),
            address(_vault)
        );
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
        vault = address(_vault);
        (shares, depositedAssetValue, currentAssetValue) = ERC4626CollateralManager.getCollateral(address(_vault));
    }

    /**
     * @dev Get the collateral vault address
     */
    function getCollateralVault() external view returns (address) {
        return address(_vault);
    }

    /**
     * @dev Get collateral shares
     */
    function getCollateralShares() external view returns (uint256) {
        return ERC4626CollateralManager.getCollateralShares();
    }

    function getLoanUtilization() external view override returns (uint256) {
        return ERC4626CollateralManager.getLoanUtilization(
            address(_portfolioFactory.portfolioFactoryConfig()),
            address(_vault)
        );
    }

    function getCollateralToken() external view override returns (address) {
        return address(_vault);
    }
}
