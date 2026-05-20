// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {VeHydrexClaimingFacet} from "./VeHydrexClaimingFacet.sol";

/**
 * @title DynamicVeHydrexClaimingFacet
 * @dev VeHydrexClaimingFacet variant paired with DynamicFeesVault-backed debt.
 */
contract DynamicVeHydrexClaimingFacet is VeHydrexClaimingFacet {
    constructor(address portfolioFactory, address votingEscrow, address voter, address rewardsDistributor)
        VeHydrexClaimingFacet(portfolioFactory, votingEscrow, voter, rewardsDistributor)
    {}

    function _updateLockedCollateral(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.updateLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _addLockedCollateralUnchecked(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.addLockedCollateralUnchecked(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _decreaseTotalDebt(uint256 amount) internal override returns (uint256 excess) {
        return DynamicHydrexCollateralManager.decreaseTotalDebt(
            address(_portfolioFactory.portfolioFactoryConfig()), amount
        );
    }
}
