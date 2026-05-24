// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {VeHydrexVotingEscrowFacet} from "./VeHydrexVotingEscrowFacet.sol";

/**
 * @title DynamicVeHydrexVotingEscrowFacet
 * @dev VeHydrexVotingEscrowFacet variant paired with DynamicFeesVault-backed debt.
 *      Delegates collateral writes to DynamicHydrexCollateralManager.
 */
contract DynamicVeHydrexVotingEscrowFacet is VeHydrexVotingEscrowFacet {
    constructor(address portfolioFactory, address votingEscrow)
        VeHydrexVotingEscrowFacet(portfolioFactory, votingEscrow)
    {}

    function _addLockedCollateral(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.addLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _updateLockedCollateral(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.updateLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function _removeLockedCollateral(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.removeLockedCollateral(
            tokenId, address(_portfolioFactory.portfolioFactoryConfig()), address(_votingEscrow)
        );
    }
}
