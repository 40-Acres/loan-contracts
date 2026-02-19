// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {BaseMarketplaceFacet} from "./BaseMarketplaceFacet.sol";

/**
 * @title DynamicMarketplaceFacet
 * @dev Marketplace facet for diamonds using DynamicCollateralManager (DynamicFeesVault).
 */
contract DynamicMarketplaceFacet is BaseMarketplaceFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace)
        BaseMarketplaceFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, marketplace) {}

    function _removeLockedCollateral(uint256 tokenId, address config) internal override {
        DynamicCollateralManager.removeLockedCollateral(tokenId, config);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return DynamicCollateralManager.decreaseTotalDebt(config, amount);
    }

    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getRequiredPaymentForCollateralRemoval(config, tokenId);
    }
}
