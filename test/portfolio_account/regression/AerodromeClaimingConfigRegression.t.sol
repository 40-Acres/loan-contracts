// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "./BaseDeploymentSetup.sol";

/**
 * @title AerodromeClaimingConfigRegression
 * @dev Verifies ClaimingFacet config wiring and authorized caller setup.
 *      Extracted from fork/AerodromeClaimingRegression — these tests only
 *      read constructor args and manager state, no on-chain interaction needed.
 */
contract AerodromeClaimingConfigRegression is BaseDeploymentSetup {
    // ─── ClaimingFacet config wiring ────────────────────────────────

    function testClaimingFacetPortfolioFactory() public view {
        assertEq(address(claimingFacet._portfolioFactory()), address(portfolioFactory));
    }

    function testClaimingFacetPortfolioAccountConfig() public view {
        assertEq(address(claimingFacet._portfolioAccountConfig()), address(portfolioAccountConfig));
    }

    function testClaimingFacetVotingEscrow() public view {
        assertEq(address(claimingFacet._votingEscrow()), VOTING_ESCROW);
    }

    function testClaimingFacetVoter() public view {
        assertEq(address(claimingFacet._voter()), VOTER);
    }

    function testClaimingFacetRewardsDistributor() public view {
        assertEq(address(claimingFacet._rewardsDistributor()), REWARDS_DISTRIBUTOR);
    }

    function testClaimingFacetLoanConfig() public view {
        assertEq(address(claimingFacet._loanConfig()), address(loanConfig));
    }

    function testClaimingFacetSwapConfig() public view {
        assertEq(address(claimingFacet._swapConfig()), address(swapConfig));
    }

    function testClaimingFacetVault() public view {
        assertEq(address(claimingFacet._vault()), address(vault));
    }

    // ─── Authorized caller ──────────────────────────────────────────

    function testAuthorizedCallerIsSet() public view {
        assertTrue(portfolioManager.isAuthorizedCaller(authorizedCaller));
    }

    function testNonAuthorizedCallerIsNotSet() public view {
        assertFalse(portfolioManager.isAuthorizedCaller(address(0xdead)));
    }
}
