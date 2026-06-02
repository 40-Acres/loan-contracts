// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {BaseMarketplaceFacet} from "../marketplace/BaseMarketplaceFacet.sol";

/**
 * @title HydrexMarketplaceFacet
 * @dev MarketplaceFacet variant for veHydrex diamonds. Routes collateral and
 *      debt calls through HydrexCollateralManager so reads and writes land on
 *      the storage.HydrexCollateralManager slot.
 */
contract HydrexMarketplaceFacet is BaseMarketplaceFacet {
    constructor(address portfolioFactory, address votingEscrow, address marketplace)
        BaseMarketplaceFacet(portfolioFactory, votingEscrow, marketplace) {}

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        HydrexCollateralManager.removeLockedCollateral(tokenId, config, ve);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return HydrexCollateralManager.decreaseTotalDebt(config, amount);
    }

    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view override returns (uint256) {
        return HydrexCollateralManager.getRequiredPaymentForCollateralRemoval(config, tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return HydrexCollateralManager.enforceCollateralRequirements();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return HydrexCollateralManager.getTotalDebt();
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return HydrexCollateralManager.getLockedCollateral(tokenId);
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return HydrexCollateralManager.getOriginTimestamp(tokenId);
    }
}
