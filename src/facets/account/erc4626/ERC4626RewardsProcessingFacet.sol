// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RewardsProcessingFacet} from "../rewards_processing/RewardsProcessingFacet.sol";
import {ERC4626CollateralManager} from "./ERC4626CollateralManager.sol";
import {UserRewardsConfig} from "../rewards_processing/UserRewardsConfig.sol";
import {SwapMod} from "../swap/SwapMod.sol";

/**
 * @title ERC4626RewardsProcessingFacet
 * @dev RewardsProcessingFacet variant for ERC4626 vault-share collateral.
 *      Rebinds the debt/utilization hooks to ERC4626CollateralManager so rewards
 *      processing reads the same storage slot the ERC4626 lending/collateral
 *      facets write. The base facet reads the veNFT CollateralManager slot and
 *      would see zero debt on an ERC4626 account.
 *
 *      `_vault` (base) is the lending/reinvest vault: getRewardsToken() returns
 *      its asset and excess rewards reinvest into it, matching the other
 *      variants. `_collateralVault` is the ERC4626 vault whose shares are the
 *      collateral, used for the debt and utilization reads. Deployments MUST set
 *      `_collateralVault` to the same vault the ERC4626LendingFacet uses.
 */
contract ERC4626RewardsProcessingFacet is RewardsProcessingFacet {
    address public immutable _collateralVault;

    constructor(
        address portfolioFactory,
        address swapConfig,
        address collateralVault,
        address lendingVault,
        address defaultToken
    ) RewardsProcessingFacet(
        portfolioFactory,
        swapConfig,
        collateralVault,
        lendingVault,
        defaultToken
    ) {
        require(collateralVault != address(0), "Invalid collateral vault");
        _collateralVault = collateralVault;
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }

    function _getLoanUtilization() internal view override returns (uint256) {
        return ERC4626CollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()), _collateralVault);
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return ERC4626CollateralManager.decreaseTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()), _collateralVault, amount);
    }

    /// @dev Block swapping the vault share token (collateral); underlying asset stays swappable.
    function _isSwapAllowed(address inputToken) internal view override returns (bool) {
        return inputToken != _collateralVault;
    }

    /// @dev IncreaseCollateral is unsupported for ERC4626 collateral; use InvestToVault.
    function _increaseCollateral(uint256, address, uint256, SwapMod.RouteParams memory) internal pure override returns (uint256 amountUsed) {
        return 0;
    }

    /// @dev Match the no-op above: never produce a swap route for IncreaseCollateral.
    function _routeForDistributionEntry(
        UserRewardsConfig.DistributionEntry memory entry, uint256 amount,
        address asset, address lockedAsset, uint256 tokenId
    ) internal view override returns (SwapRoute memory route) {
        if (entry.option == UserRewardsConfig.RewardsOption.IncreaseCollateral) {
            return SwapRoute(address(0), address(0), 0);
        }
        return super._routeForDistributionEntry(entry, amount, asset, lockedAsset, tokenId);
    }
}
