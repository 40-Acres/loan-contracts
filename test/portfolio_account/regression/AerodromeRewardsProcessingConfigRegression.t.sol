// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";

/**
 * @title AerodromeRewardsProcessingConfigRegression
 * @dev Verifies VotingEscrowRewardsProcessingFacet constructor wiring.
 *      The rewardsProcessingFacet field in BaseDeploymentSetup is typed as
 *      RewardsProcessingFacet but is actually a VotingEscrowRewardsProcessingFacet.
 */
contract AerodromeRewardsProcessingConfigRegression is BaseDeploymentSetup {
    // ─── RewardsProcessingFacet config wiring ─────────────────────────

    function testRewardsProcessingFacetPortfolioFactory() public view {
        assertEq(address(rewardsProcessingFacet._portfolioFactory()), address(portfolioFactory));
    }

    function testRewardsProcessingFacetSwapConfig() public view {
        assertEq(address(rewardsProcessingFacet._swapConfig()), address(swapConfig));
    }

    function testRewardsProcessingFacetUnderlyingLockedAsset() public view {
        assertEq(rewardsProcessingFacet._underlyingLockedAsset(), AERO);
    }

    function testRewardsProcessingFacetVault() public view {
        assertEq(address(rewardsProcessingFacet._vault()), address(vault));
    }

    function testRewardsProcessingFacetVotingEscrow() public view {
        VotingEscrowRewardsProcessingFacet veRewardsFacet = VotingEscrowRewardsProcessingFacet(address(rewardsProcessingFacet));
        assertEq(address(veRewardsFacet._votingEscrow()), VOTING_ESCROW);
    }
}
