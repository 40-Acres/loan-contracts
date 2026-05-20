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
    // defaultVote / isElligibleForManualVoting
    // ----------------------------------------------------------------

    function test_isElligibleForManualVoting_returnsFalseWhenLastVotedBeforeOrigin() public {
        // No vote has occurred -> lastVoted == 0 -> originTimestamp gate triggers false.
        uint256 tokenId = _seedRollingLock(2e18);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    function test_isElligibleForManualVoting_trueAfterRecentAccountVote() public {
        uint256 tokenId = _seedRollingLock(2e18);
        // Drive lastVoted(account) forward via the voter mock so eligibility flips true.
        voter.setLastVoted(portfolioAccount, block.timestamp + 1);
        assertTrue(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    function test_isElligibleForManualVoting_falseWhenLastVoteIsTooStale() public {
        // Origin at t0. Move forward many weeks. Hydrex does not carry votes across
        // epochs, so any lastVoted older than the current epoch makes the account
        // ineligible for manual mode.
        uint256 tokenId = _seedRollingLock(2e18);
        uint256 originLastVoted = block.timestamp + 1;
        voter.setLastVoted(portfolioAccount, originLastVoted);
        vm.warp(block.timestamp + 4 weeks);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    /// @dev Hydrex-specific: votes do NOT carry across epochs (weightsPerEpoch is
    ///      keyed on the current epoch and zero-initialized each flip), so a
    ///      vote cast in the previous epoch is NOT sufficient to keep manual mode
    ///      this epoch. Distinguishes Hydrex from carry-over forks.
    function test_isElligibleForManualVoting_falseWhenLastVoteWasPreviousEpoch() public {
        uint256 tokenId = _seedRollingLock(2e18);
        voter.setLastVoted(portfolioAccount, block.timestamp + 1);
        // Advance one epoch boundary; the saved vote is now last-epoch.
        vm.warp(block.timestamp + 1 weeks);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
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
