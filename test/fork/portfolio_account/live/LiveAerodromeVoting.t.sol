// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LiveDeploymentSetup} from "./LiveDeploymentSetup.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolTimeLibrary} from "../../../../src/libraries/ProtocolTimeLibrary.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";

/**
 * @title LiveAerodromeVoting
 * @dev Tests Aerodrome voting functionality against the live Base deployment.
 *      Covers manual voting via multicall, automatic default voting by authorized callers,
 *      and multi-pool voting with weight distribution.
 *
 *      Run: FOUNDRY_PROFILE=fork forge test --match-path test/fork/portfolio_account/live/LiveAerodromeVoting.t.sol --no-match-path 'NONE' -vvv
 */
contract LiveAerodromeVoting is LiveDeploymentSetup {

    // Known Aerodrome pools on Base with active gauges (fallback if approved list is empty)
    address constant USDC_AERO_POOL = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address constant WETH_USDC_POOL = 0xcDAC0d6c6C59727a65F871236188350531885C43;

    // ─── Helpers ─────────────────────────────────────────────────────

    /**
     * @dev Returns up to `count` approved pools from VotingConfig that have alive gauges.
     *      If not enough pools are available, approves known fallback pools via owner prank.
     */
    function _getVotableApprovedPools(uint256 count) internal returns (address[] memory pools) {
        VotingConfig votingConfig = VotingConfig(votingConfigAddr);
        address[] memory approvedPools = votingConfig.getApprovedPoolsList();

        // Filter for pools with alive gauges
        // Size array for max possible: approved pools + 2 fallback pools
        address[] memory alive = new address[](approvedPools.length + 2);
        uint256 aliveCount = 0;
        for (uint256 i = 0; i < approvedPools.length; i++) {
            address gauge = IVoter(VOTER).gauges(approvedPools[i]);
            if (gauge != address(0) && IVoter(VOTER).isAlive(gauge)) {
                alive[aliveCount] = approvedPools[i];
                aliveCount++;
                if (aliveCount >= count) break;
            }
        }

        // If we have enough, return them
        if (aliveCount >= count) {
            pools = new address[](count);
            for (uint256 i = 0; i < count; i++) {
                pools[i] = alive[i];
            }
            return pools;
        }

        // Otherwise, approve known fallback pools with alive gauges
        address[] memory fallbacks = new address[](2);
        fallbacks[0] = USDC_AERO_POOL;
        fallbacks[1] = WETH_USDC_POOL;

        address votingConfigOwner = votingConfig.owner();
        for (uint256 i = 0; i < fallbacks.length && aliveCount < count; i++) {
            // Skip if already in our alive list
            bool alreadyIncluded = false;
            for (uint256 j = 0; j < aliveCount; j++) {
                if (alive[j] == fallbacks[i]) {
                    alreadyIncluded = true;
                    break;
                }
            }
            if (alreadyIncluded) continue;

            address gauge = IVoter(VOTER).gauges(fallbacks[i]);
            if (gauge != address(0) && IVoter(VOTER).isAlive(gauge)) {
                // Approve this pool in VotingConfig
                if (!votingConfig.isApprovedPool(fallbacks[i])) {
                    vm.prank(votingConfigOwner);
                    votingConfig.setApprovedPool(fallbacks[i], true);
                }
                alive[aliveCount] = fallbacks[i];
                aliveCount++;
            }
        }

        require(aliveCount >= count, "Not enough votable pools with alive gauges found");

        pools = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            pools[i] = alive[i];
        }
    }

    /**
     * @dev Warps to a safe voting time: mid-epoch, avoiding Aerodrome's
     *      DistributeWindow (first hour) and SpecialVotingWindow (last hour).
     */
    function _warpToSafeVotingTime() internal {
        uint256 currentTs = block.timestamp;
        // Always warp FORWARD — warping backward breaks veNFT checkpoint iteration
        uint256 nextEpoch = currentTs - (currentTs % 1 weeks) + 1 weeks;
        // Warp to 3 days into the next epoch — safely mid-week, avoids
        // DistributeWindow (first hour) and SpecialVotingWindow (last hour)
        vm.warp(nextEpoch + 3 days);
    }

    // ─── Test 1: vote via multicall ─────────────────────────────────

    /**
     * @dev User votes on a single approved pool via PortfolioManager.multicall.
     *      Verifies vote registration on Aerodrome voter, manual voting mode activation,
     *      and collateral locking.
     */
    function testLive_Voting_VoteViaMulticall() public {
        // Warp to safe voting window: mid-epoch (avoids DistributeWindow and SpecialVotingWindow)
        _warpToSafeVotingTime();

        // Arrange: get one votable approved pool
        address[] memory pools = _getVotableApprovedPools(1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000; // 100% weight to single pool

        // Capture state before voting
        uint256 lastVotedBefore = IVoter(VOTER).lastVoted(tokenId);
        uint256 votesBefore = IVoter(VOTER).votes(tokenId, pools[0]);

        // Act: vote via multicall
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );

        // Assert: lastVoted updated on Aerodrome voter
        uint256 lastVotedAfter = IVoter(VOTER).lastVoted(tokenId);
        assertGt(lastVotedAfter, lastVotedBefore, "lastVoted should be updated after voting");
        assertGe(lastVotedAfter, block.timestamp, "lastVoted should be >= current block.timestamp");

        // Assert: votes registered for the pool
        uint256 votesAfter = IVoter(VOTER).votes(tokenId, pools[0]);
        assertGt(votesAfter, 0, "votes for pool should be > 0 after voting");
        assertGt(votesAfter, votesBefore, "votes should increase after voting");

        // Assert: usedWeights updated
        uint256 usedWeights = IVoter(VOTER).usedWeights(tokenId);
        assertGt(usedWeights, 0, "usedWeights should be > 0 after voting");

        // Assert: user is now in manual voting mode
        bool isManual = VotingFacet(portfolioAccount).isManualVoting(tokenId);
        assertTrue(isManual, "User should be in manual voting mode after vote()");

        // Assert: collateral is locked (addLockedCollateral was called)
        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Collateral should be locked after voting");

        // Assert: locked collateral for this specific tokenId
        uint256 tokenCollateral = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenId);
        assertGt(tokenCollateral, 0, "Token-specific collateral should be locked after voting");
    }

    // ─── Test 2: defaultVote by authorized caller ───────────────────

    /**
     * @dev Authorized caller votes on behalf of an automatic-mode user during the
     *      last hour before epoch end. Creates a second user who has not voted manually.
     */
    function testLive_Voting_DefaultVoteByAuthorizedCaller() public {
        // Arrange: create a second user with a veNFT who stays in automatic mode
        address user2 = address(uint160(uint256(keccak256("live-voting-test-user2"))));
        deal(AERO, user2, 50_000e18);
        address user2Portfolio = portfolioFactory.createAccount(user2);

        vm.startPrank(user2);
        IERC20(AERO).approve(user2Portfolio, 50_000e18);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, 50_000e18);
        bytes[] memory results = portfolioManager.multicall(calls, factories);
        uint256 user2TokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();

        // Verify user2 is in automatic mode (not manual)
        bool isManualBefore = VotingFacet(user2Portfolio).isManualVoting(user2TokenId);
        assertFalse(isManualBefore, "Fresh user should be in automatic voting mode");

        // Arrange: get votable pools
        address[] memory pools = _getVotableApprovedPools(1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        // Arrange: set up an authorized caller
        address authorizedCaller = address(uint160(uint256(keccak256("live-voting-authorized-caller"))));
        vm.prank(portfolioManager.owner());
        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        assertTrue(portfolioManager.isAuthorizedCaller(authorizedCaller), "Caller should be authorized");

        // Arrange: warp to the defaultVote window [epochNext - 2h, epochNext - 1h)
        // Must be AFTER epochVoteEnd - 1 hour (VotingFacet requirement)
        // Must be BEFORE epochNext - 1 hour (Aerodrome SpecialVotingWindow restriction)
        uint256 currentTs = block.timestamp;
        uint256 epochEnd = currentTs - (currentTs % 1 weeks) + 1 weeks; // epochNext
        uint256 safeTarget = epochEnd - 90 minutes; // 90 min before flip: inside defaultVote window, outside SpecialVotingWindow
        vm.warp(safeTarget);

        // Act: authorized caller calls defaultVote directly on the portfolio account
        vm.prank(authorizedCaller);
        VotingFacet(user2Portfolio).defaultVote(user2TokenId, pools, weights);

        // Assert: vote registered on Aerodrome voter
        uint256 lastVoted = IVoter(VOTER).lastVoted(user2TokenId);
        assertGt(lastVoted, 0, "lastVoted should be set after defaultVote");
        assertGe(lastVoted, safeTarget, "lastVoted should be >= warp target timestamp");

        uint256 votesForPool = IVoter(VOTER).votes(user2TokenId, pools[0]);
        assertGt(votesForPool, 0, "votes for pool should be > 0 after defaultVote");

        // Assert: user2 should still NOT be in manual mode (defaultVote does not set manual mode)
        // Note: After defaultVote, isElligibleForManualVoting returns true (lastVoted >= originTimestamp
        // and within this epoch). But the manual flag was never set, so isManualVoting returns false.
        // However, isElligibleForManualVoting IS now true, so the user COULD set manual mode.
        // The key point: defaultVote itself does NOT call setVotingMode(true).
        bool isManualAfter = VotingFacet(user2Portfolio).isManualVoting(user2TokenId);
        assertFalse(isManualAfter, "defaultVote should NOT set manual voting mode");

        // Assert: collateral is locked for user2
        uint256 user2Collateral = ICollateralFacet(user2Portfolio).getTotalLockedCollateral();
        assertGt(user2Collateral, 0, "User2 collateral should be locked after defaultVote");
    }

    // ─── Test 3: vote on multiple pools ─────────────────────────────

    /**
     * @dev User votes on 2+ pools with different weights via multicall.
     *      Verifies votes are distributed across multiple pools.
     */
    function testLive_Voting_VoteMultiplePools() public {
        // Warp to safe voting window: mid-epoch
        _warpToSafeVotingTime();

        // Arrange: get 2 votable approved pools
        address[] memory pools = _getVotableApprovedPools(2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 7000; // 70% to first pool
        weights[1] = 3000; // 30% to second pool

        // Act: vote via multicall
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );

        // Assert: lastVoted updated
        uint256 lastVoted = IVoter(VOTER).lastVoted(tokenId);
        assertGe(lastVoted, block.timestamp, "lastVoted should be >= current timestamp");

        // Assert: both pools have votes registered
        uint256 votesPool1 = IVoter(VOTER).votes(tokenId, pools[0]);
        uint256 votesPool2 = IVoter(VOTER).votes(tokenId, pools[1]);
        assertGt(votesPool1, 0, "votes for pool 1 should be > 0");
        assertGt(votesPool2, 0, "votes for pool 2 should be > 0");

        // Assert: weight distribution reflects the 70/30 split (proportional)
        // Aerodrome normalizes weights, so the ratio should be approximately 7:3
        // Allow 1% tolerance for rounding: votesPool1 / votesPool2 ~ 7/3 = 2.333
        // Equivalent check: votesPool1 * 3 ~ votesPool2 * 7 (within tolerance)
        uint256 lhs = votesPool1 * 3000;
        uint256 rhs = votesPool2 * 7000;
        // Allow 1% tolerance on the larger value
        uint256 tolerance = (lhs > rhs ? lhs : rhs) / 100;
        assertApproxEqAbs(lhs, rhs, tolerance, "Vote weight distribution should reflect 70/30 split");

        // Assert: usedWeights equals the sum of votes
        uint256 usedWeights = IVoter(VOTER).usedWeights(tokenId);
        assertEq(usedWeights, votesPool1 + votesPool2, "usedWeights should equal sum of all votes");

        // Assert: user is in manual voting mode after vote()
        bool isManual = VotingFacet(portfolioAccount).isManualVoting(tokenId);
        assertTrue(isManual, "User should be in manual voting mode after multi-pool vote");

        // Assert: collateral is locked
        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Collateral should be locked after multi-pool voting");
    }
}
