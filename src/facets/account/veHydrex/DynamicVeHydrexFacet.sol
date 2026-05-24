// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {VeHydrexFacet} from "./VeHydrexFacet.sol";

/**
 * @title DynamicVeHydrexFacet
 * @dev VeHydrexFacet variant paired with DynamicFeesVault-backed debt.
 */
contract DynamicVeHydrexFacet is VeHydrexFacet {
    constructor(address portfolioFactory, address votingConfigStorage, address votingEscrow, address voter)
        VeHydrexFacet(portfolioFactory, votingConfigStorage, votingEscrow, voter)
    {}

    function _addLockedCollateral(uint256 tokenId) internal override {
        DynamicHydrexCollateralManager.addLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }
}
