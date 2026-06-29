// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {DynamicERC4626CollateralManager} from "./DynamicERC4626CollateralManager.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";

/**
 * @title DynamicERC4626CollateralFacet
 * @dev ERC4626 vault-share collateral facet for a live-debt-read lending pool.
 *      Mirrors ERC4626CollateralFacet one-to-one; the only difference is the
 *      collateral-manager library (DynamicERC4626CollateralManager).
 */
contract DynamicERC4626CollateralFacet is AccessControl, ICollateralFacet {
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

    function addCollateral(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        DynamicERC4626CollateralManager.addCollateral(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault), shares);
    }

    function addCollateralFrom(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(shares > 0, "Shares must be > 0");

        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(address(_vault)).safeTransferFrom(owner, address(this), shares);

        DynamicERC4626CollateralManager.addCollateral(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault), shares);
    }

    function removeCollateral(uint256 shares) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);
        DynamicERC4626CollateralManager.removeCollateral(config, address(_vault), shares);

        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(address(_vault)).safeTransfer(owner, shares);
    }

    function removeCollateralTo(uint256 shares, address targetPortfolioFactory) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        SequencerLivenessLib.assertUp(config);

        PortfolioManager portfolioManager = _portfolioFactory.portfolioManager();
        require(portfolioManager.isRegisteredFactory(targetPortfolioFactory), "Target factory not registered");

        address owner = _portfolioFactory.ownerOf(address(this));
        PortfolioFactory targetFactory = PortfolioFactory(targetPortfolioFactory);

        address toPortfolio = targetFactory.portfolioOf(owner);
        if (toPortfolio == address(0)) {
            toPortfolio = targetFactory.createAccount(owner);
        }

        DynamicERC4626CollateralManager.removeCollateral(config, address(_vault), shares);
        IERC20(address(_vault)).safeTransfer(toPortfolio, shares);
    }

    // ============ View Functions ============

    function getTotalLockedCollateral() external view override returns (uint256) {
        return DynamicERC4626CollateralManager.getTotalCollateralValue(address(_vault));
    }

    function getTotalDebt() external view override returns (uint256) {
        return DynamicERC4626CollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return DynamicERC4626CollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()), address(_vault));
    }

    function enforceCollateralRequirements() external view override returns (bool success) {
        return DynamicERC4626CollateralManager.enforceCollateralRequirements(
            address(_portfolioFactory.portfolioFactoryConfig()),
            address(_vault)
        );
    }

    function getCollateral() external view returns (
        address vault,
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        vault = address(_vault);
        (shares, depositedAssetValue, currentAssetValue) = DynamicERC4626CollateralManager.getCollateral(address(_vault));
    }

    function getCollateralVault() external view returns (address) {
        return address(_vault);
    }

    function getCollateralShares() external view returns (uint256) {
        return DynamicERC4626CollateralManager.getCollateralShares();
    }

    function getLoanUtilization() external view override returns (uint256) {
        return DynamicERC4626CollateralManager.getLoanUtilization(
            address(_portfolioFactory.portfolioFactoryConfig()),
            address(_vault)
        );
    }

    function getCollateralToken() external view override returns (address) {
        return address(_vault);
    }
}
