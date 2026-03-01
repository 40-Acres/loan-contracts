// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {ClaimingFacet} from "./ClaimingFacet.sol";

/**
 * @title DynamicClaimingFacet
 * @dev ClaimingFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicClaimingFacet is ClaimingFacet {
    constructor(
        address portfolioFactory,
        address portfolioAccountConfig,
        address votingEscrow,
        address voter,
        address rewardsDistributor,
        address loanConfig,
        address swapConfig,
        address vault
    ) ClaimingFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig, vault) {}

    function _updateLockedCollateral(uint256 tokenId) internal override {
        DynamicCollateralManager.updateLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }

    function _getTotalDebt() internal override view returns (uint256) {
        return DynamicCollateralManager.getTotalDebt(address(_portfolioAccountConfig));
    }
}
