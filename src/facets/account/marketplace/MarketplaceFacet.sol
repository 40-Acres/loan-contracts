// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CollateralManager} from "../collateral/CollateralManager.sol";
import {BaseMarketplaceFacet} from "./BaseMarketplaceFacet.sol";

/**
 * @title MarketplaceFacet
 * @dev Marketplace facet for diamonds using CollateralManager (simple vaults).
 */
contract MarketplaceFacet is BaseMarketplaceFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace)
        BaseMarketplaceFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, marketplace) {}

    function _removeLockedCollateral(uint256 tokenId, address config) internal override {
        CollateralManager.removeLockedCollateral(tokenId, config);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return CollateralManager.decreaseTotalDebt(config, amount);
    }

    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view override returns (uint256) {
        return CollateralManager.getRequiredPaymentForCollateralRemoval(config, tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return CollateralManager.enforceCollateralRequirements();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return CollateralManager.getLockedCollateral(tokenId);
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return CollateralManager.getOriginTimestamp(tokenId);
    }
}
