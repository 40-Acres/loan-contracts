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
}
