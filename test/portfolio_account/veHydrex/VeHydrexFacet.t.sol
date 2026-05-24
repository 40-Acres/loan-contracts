// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {VeHydrexFacet} from "../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

/// @dev VeHydrexFacet tests.
///
///      Mocks define the Hydrex Voter behaviour; these tests verify the
///      facet's wiring around vote / batchVote / defaultVote, plus the
///      account-keyed eligibility logic. They do NOT prove anything about
///      Hydrex's on-chain voting semantics beyond what the mock implements.
contract VeHydrexFacetTest is VeHydrexDiamond {
    address internal pool1 = address(0xAAA1);
    address internal pool2 = address(0xAAA2);
    address internal poolBad = address(0xBADD);

    function setUp() public {
        // Warp into the future so epochStart arithmetic doesn't underflow.
        vm.warp(100 weeks);
        _bootstrap();
        vm.startPrank(owner_);
        address[] memory pools = new address[](2);
        pools[0] = pool1;
        pools[1] = pool2;
        votingConfig.setApprovedPools(pools, true);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // vote(tokenId, pools, weights)
    // ----------------------------------------------------------------

    function test_vote_callsVoterOnce_andTracksCollateral_andSetsManualMode() public {
        uint256 tokenId = _seedRollingLock(5e18);

        address[] memory pools = new address[](2);
        pools[0] = pool1;
        pools[1] = pool2;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 60;
        weights[1] = 40;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.vote.selector, tokenId, pools, weights)
        );
        portfolioManager.multicall(cd, fac);

        assertEq(voter.voteCallCount(), 1, "voter.vote called once");
        (address[] memory lp, uint256[] memory lw) = voter.lastVoteCall();
        assertEq(lp.length, 2, "pools passed thru");
        assertEq(lp[0], pool1);
        assertEq(lw[1], 40);
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId),
            5e18,
            "collateral tracked"
        );
        // Voter recorded lastVoted to the account-key; isManualVoting now true.
        assertTrue(VeHydrexFacet(portfolioAccount).isManualVoting(tokenId), "manual voting set");
    }

    function test_vote_revertsWhenPoolNotApproved() public {
        uint256 tokenId = _seedRollingLock(5e18);
        address[] memory pools = new address[](1);
        pools[0] = poolBad;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.vote.selector, tokenId, pools, weights)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexFacet.PoolNotApproved.selector, poolBad));
        portfolioManager.multicall(cd, fac);
    }

    function test_vote_revertsForNonManagerCaller() public {
        uint256 tokenId = _seedRollingLock(5e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        vm.prank(user);
        vm.expectRevert(); // onlyPortfolioManagerMulticall
        VeHydrexFacet(portfolioAccount).vote(tokenId, pools, weights);
    }

    // ----------------------------------------------------------------
    // batchVote
    // ----------------------------------------------------------------

    function test_batchVote_callsVoterExactlyOnce_acrossManyTokens() public {
        uint256 t1 = _seedRollingLock(2e18);
        uint256 t2 = _seedRollingLock(3e18);
        uint256 t3 = _seedRollingLock(4e18);

        uint256 callsBefore = voter.voteCallCount();
        address[] memory pools = new address[](2);
        pools[0] = pool1;
        pools[1] = pool2;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 50;
        weights[1] = 50;
        uint256[] memory ids = new uint256[](3);
        ids[0] = t1; ids[1] = t2; ids[2] = t3;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.batchVote.selector, ids, pools, weights)
        );
        portfolioManager.multicall(cd, fac);

        // Exactly ONE on-chain ballot covers every listed tokenId; Hydrex votes
        // are account-wide, so the tokenIds array is only an audit trail.
        assertEq(voter.voteCallCount(), callsBefore + 1, "voter.vote called exactly once");
    }

    function test_batchVote_revertsOnEmptyPools() public {
        uint256 t1 = _seedRollingLock(2e18);
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = t1;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.batchVote.selector, ids, pools, weights)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexFacet.PoolsCannotBeEmpty.selector));
        portfolioManager.multicall(cd, fac);
    }

    function test_batchVote_revertsOnUnapprovedPool() public {
        uint256 t1 = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = poolBad;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        uint256[] memory ids = new uint256[](1);
        ids[0] = t1;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.batchVote.selector, ids, pools, weights)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexFacet.PoolNotApproved.selector, poolBad));
        portfolioManager.multicall(cd, fac);
    }

    // ----------------------------------------------------------------
    // defaultVote / isElligibleForManualVoting / setVotingMode (per-epoch + account-wide)
    // ----------------------------------------------------------------

    /// @dev Votes don't carry over in Hydrex, so eligibility is unconditional.
    ///      Replaces three pre-pivot tests that asserted false under stale conditions.
    function test_isElligibleForManualVoting_alwaysTrue() public {
        uint256 tokenId = _seedRollingLock(2e18);
        assertTrue(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
        // Even when nothing has voted yet
        voter.setLastVoted(portfolioAccount, 0);
        assertTrue(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
        // Even after the last vote is many epochs stale
        voter.setLastVoted(portfolioAccount, block.timestamp);
        vm.warp(block.timestamp + 10 weeks);
        assertTrue(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    /// @dev With no manual-mode preference set, operator can default-vote freely.
    function test_defaultVote_succeedsWhenUserHasNotOptedIntoManualMode() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        uint256 callsBefore = voter.voteCallCount();
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
        assertEq(voter.voteCallCount(), callsBefore + 1, "operator default-vote landed");
    }

    /// @dev Once user has opted into manual mode, the per-epoch gate kicks in.
    ///      If the account has already voted this epoch (e.g. via vote() or a prior
    ///      defaultVote), the next defaultVote in the same epoch is blocked.
    function test_defaultVote_blockedAfterAccountAlreadyVotedThisEpoch() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        // User manual-votes -> sets manual-mode flag AND bumps voter.lastVoted to now.
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.vote.selector, tokenId, pools, weights)
        );
        portfolioManager.multicall(cd, fac);

        // Operator's defaultVote in the same epoch should revert.
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Account already voted this epoch"));
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
    }

    /// @dev New epoch resets the gate; operator can default-vote again.
    function test_defaultVote_succeedsAgainInNextEpoch() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        // User manual-votes in epoch N
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.vote.selector, tokenId, pools, weights)
        );
        portfolioManager.multicall(cd, fac);

        // Advance into epoch N+1
        vm.warp(block.timestamp + 1 weeks);

        // Operator default-vote succeeds because lastVoted is now stale relative
        // to the current epoch.
        uint256 callsBefore = voter.voteCallCount();
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
        assertEq(voter.voteCallCount(), callsBefore + 1, "default-vote allowed in next epoch");

        // But a second defaultVote in the SAME epoch is now blocked
        // (operator's own vote bumped lastVoted to current epoch).
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Account already voted this epoch"));
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
    }

    /// @dev Operator can only default-vote once per epoch even if user never
    ///      opted into manual mode -- second call lands on the
    ///      isManualVoting=true / lastVoted-current branch via vote()'s side-effect.
    ///      Without manual opt-in, the gate returns true unconditionally; the
    ///      Hydrex Voter itself prevents same-pool double-vote within an epoch.
    function test_defaultVote_repeatedInSameEpoch_allowedWhenNoManualOptIn() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);

        // No user opt-in -> the facet-side gate returns true and lets through.
        // (Real Hydrex Voter would reject same-pool re-vote without reset; mock allows.)
        uint256 callsBefore = voter.voteCallCount();
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
        assertEq(voter.voteCallCount(), callsBefore + 1, "second default-vote landed via mock");
    }

    /// @dev setVotingMode and isManualVoting are ACCOUNT-WIDE; tokenId argument
    ///      is ignored and storage is keyed at slot 0.
    function test_setVotingMode_isAccountWide_ignoresTokenIdArg() public {
        uint256 t1 = _seedRollingLock(2e18);
        uint256 t2 = _seedRollingLock(3e18);

        // Flip via t1
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.setVotingMode.selector, t1, true)
        );
        portfolioManager.multicall(cd, fac);

        // Querying with ANY tokenId returns the account-wide flag.
        assertTrue(VeHydrexFacet(portfolioAccount).isManualVoting(t1));
        assertTrue(VeHydrexFacet(portfolioAccount).isManualVoting(t2));
        assertTrue(VeHydrexFacet(portfolioAccount).isManualVoting(0));

        // Flip off via t2; same observation
        vm.prank(user);
        (cd, fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.setVotingMode.selector, t2, false)
        );
        portfolioManager.multicall(cd, fac);
        assertFalse(VeHydrexFacet(portfolioAccount).isManualVoting(t1));
        assertFalse(VeHydrexFacet(portfolioAccount).isManualVoting(t2));
        assertFalse(VeHydrexFacet(portfolioAccount).isManualVoting(0));
    }

    /// @dev Hydrex's _vote uses getPastVotes(account, epochStart). A veNFT that
    ///      arrives in the account AFTER the operator's defaultVote in the same
    ///      epoch contributes ZERO additional voting weight to the cast ballot,
    ///      and our facet rejects a re-attempt (would be a wasted call anyway).
    ///      The new weight is picked up automatically in the next epoch.
    function test_midEpochTokenArrival_doesNotReopenDefaultVote() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        // Opt into manual mode so the per-epoch gate is active
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.setVotingMode.selector, uint256(0), true)
        );
        portfolioManager.multicall(cd, fac);

        // Operator default-votes early in the epoch
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);

        // Mid-epoch: a brand-new ROLLING lock lands in the account (could equally
        // be a safeTransferFrom from an external holder; both look like "new
        // weight after voter.lastVoted is current").
        _seedRollingLock(7e18);

        // Operator cannot re-invoke defaultVote to fold in the new weight --
        // the per-epoch gate blocks it. (Even if it didn't, Hydrex's getPastVotes
        // would still read the epoch-start snapshot and ignore the new arrival.)
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Account already voted this epoch"));
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);

        // Next epoch resets the gate; the new weight will be included in the
        // next ballot via getPastVotes(account, next epochStart).
        vm.warp(block.timestamp + 1 weeks);
        uint256 callsBefore = voter.voteCallCount();
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
        assertEq(voter.voteCallCount(), callsBefore + 1, "next-epoch default-vote picks up new weight");
    }

    /// @dev If the user opts into manual mode but never actually votes this
    ///      epoch, the operator's defaultVote is still allowed (lastVoted has
    ///      not yet been bumped to the current epoch).
    function test_defaultVote_allowedWhenManualOptedInButNotYetVotedThisEpoch() public {
        uint256 tokenId = _seedRollingLock(2e18);
        address[] memory pools = new address[](1);
        pools[0] = pool1;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        // Opt into manual mode (account-wide) without voting yet
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexFacet.setVotingMode.selector, uint256(0), true)
        );
        portfolioManager.multicall(cd, fac);

        // Operator default-vote allowed because lastVoted == 0
        uint256 callsBefore = voter.voteCallCount();
        vm.prank(authorizedCaller);
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
        assertEq(voter.voteCallCount(), callsBefore + 1, "default-vote allowed pre-first-vote");

        // Now lastVoted is current; next default-vote in same epoch is blocked
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Account already voted this epoch"));
        VeHydrexFacet(portfolioAccount).defaultVote(tokenId, pools, weights);
    }

    // ----------------------------------------------------------------
    // Dropped methods: ABI surface
    // ----------------------------------------------------------------

    function test_droppedMethods_haveNoRegisteredFacet() public view {
        // Hydrex variant intentionally drops Aerodrome-only methods.
        // Without a registered facet, the diamond's fallback rejects the call.
        bytes4[6] memory droppedSelectors = [
            bytes4(keccak256("delegateVote(uint256,address,uint256[])")),
            bytes4(keccak256("setDelegatedVoter(uint256,address)")),
            bytes4(keccak256("getDelegatedVoter(uint256)")),
            bytes4(keccak256("voteForLaunchpadToken(uint256,address,uint256[])")),
            bytes4(keccak256("batchVoteForLaunchpadToken(uint256[],address,uint256[])")),
            // sanity: a definitely-present selector to prove the search semantics
            VeHydrexFacet.vote.selector
        ];
        // First five must not be registered.
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                facetRegistry.getFacetForSelector(droppedSelectors[i]),
                address(0),
                "dropped selector must not be wired"
            );
        }
        // sixth IS registered as a sanity check
        assertTrue(facetRegistry.getFacetForSelector(droppedSelectors[5]) != address(0));
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _seedRollingLock(uint256 amount) internal returns (uint256 tokenId) {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.createLock.selector,
                amount,
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        bytes[] memory results = portfolioManager.multicall(cd, fac);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }
}
