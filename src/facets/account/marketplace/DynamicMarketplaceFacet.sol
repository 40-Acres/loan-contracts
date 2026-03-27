// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {BaseMarketplaceFacet} from "./BaseMarketplaceFacet.sol";

interface IDynamicFeesVaultSettlement {
    function settleRewards(address user) external;
}

/**
 * @title DynamicMarketplaceFacet
 * @dev Marketplace facet for diamonds using DynamicCollateralManager (DynamicFeesVault).
 */
contract DynamicMarketplaceFacet is BaseMarketplaceFacet {
    constructor(address portfolioFactory, address votingEscrow, address marketplace)
        BaseMarketplaceFacet(portfolioFactory, votingEscrow, marketplace) {}

    function _syncDebtState() internal override {
        address lendingPool = _portfolioFactory.portfolioFactoryConfig().getLoanContract();
        IDynamicFeesVaultSettlement(lendingPool).settleRewards(address(this));
    }

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        DynamicCollateralManager.removeLockedCollateral(tokenId, config, ve);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return DynamicCollateralManager.decreaseTotalDebt(config, amount);
    }

    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getRequiredPaymentForCollateralRemoval(config, tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return DynamicCollateralManager.enforceCollateralRequirements();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return DynamicCollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getLockedCollateral(tokenId);
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getOriginTimestamp(tokenId);
    }
}
