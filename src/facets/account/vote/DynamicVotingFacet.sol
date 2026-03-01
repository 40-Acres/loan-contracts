// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {VotingFacet} from "./VotingFacet.sol";

/**
 * @title DynamicVotingFacet
 * @dev VotingFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicVotingFacet is VotingFacet {
    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address votingConfigStorage,
        address votingEscrow,
        address voter
    ) VotingFacet(portfolioFactory, portfolioAccountConfig, votingConfigStorage, votingEscrow, voter) {}

    function _addLockedCollateral(uint256 tokenId) internal override {
        DynamicCollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }

    function _getOriginTimestamp(uint256 tokenId) internal override view returns (uint256) {
        return DynamicCollateralManager.getOriginTimestamp(tokenId);
    }
}
