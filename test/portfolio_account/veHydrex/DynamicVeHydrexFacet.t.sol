// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicVeHydrexDiamond, DynamicHydrexCollateralViewFacet} from "./helpers/DynamicVeHydrexDiamond.sol";

import {VeHydrexFacet} from "../../../src/facets/account/veHydrex/VeHydrexFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

/// @dev DynamicVeHydrexFacet tests. Mirrors VeHydrexFacet.t.sol but mounts the
///      Dynamic-variant facet on the DynamicVeHydrexDiamond harness, which
///      routes collateral writes to DynamicHydrexCollateralManager. Voter
///      surface is unchanged between simple and dynamic variants, so the
///      assertions are identical.
contract DynamicVeHydrexFacetTest is DynamicVeHydrexDiamond {
    address internal pool1 = address(0xAAA1);
    address internal pool2 = address(0xAAA2);
    address internal poolBad = address(0xBADD);

    function setUp() public {
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
    // vote
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
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId),
            5e18,
            "collateral tracked"
        );
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
        vm.expectRevert();
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
    // isElligibleForManualVoting
    // ----------------------------------------------------------------

    function test_isElligibleForManualVoting_returnsFalseWhenLastVotedBeforeOrigin() public {
        uint256 tokenId = _seedRollingLock(2e18);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    function test_isElligibleForManualVoting_trueAfterRecentAccountVote() public {
        uint256 tokenId = _seedRollingLock(2e18);
        voter.setLastVoted(portfolioAccount, block.timestamp + 1);
        assertTrue(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    function test_isElligibleForManualVoting_falseWhenLastVoteIsTooStale() public {
        uint256 tokenId = _seedRollingLock(2e18);
        uint256 originLastVoted = block.timestamp + 1;
        voter.setLastVoted(portfolioAccount, originLastVoted);
        vm.warp(block.timestamp + 4 weeks);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    function test_isElligibleForManualVoting_falseWhenLastVoteWasPreviousEpoch() public {
        uint256 tokenId = _seedRollingLock(2e18);
        voter.setLastVoted(portfolioAccount, block.timestamp + 1);
        vm.warp(block.timestamp + 1 weeks);
        assertFalse(VeHydrexFacet(portfolioAccount).isElligibleForManualVoting(tokenId));
    }

    // ----------------------------------------------------------------
    // Dropped methods
    // ----------------------------------------------------------------

    function test_droppedMethods_haveNoRegisteredFacet() public view {
        bytes4[6] memory droppedSelectors = [
            bytes4(keccak256("delegateVote(uint256,address,uint256[])")),
            bytes4(keccak256("setDelegatedVoter(uint256,address)")),
            bytes4(keccak256("getDelegatedVoter(uint256)")),
            bytes4(keccak256("voteForLaunchpadToken(uint256,address,uint256[])")),
            bytes4(keccak256("batchVoteForLaunchpadToken(uint256[],address,uint256[])")),
            VeHydrexFacet.vote.selector
        ];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                facetRegistry.getFacetForSelector(droppedSelectors[i]),
                address(0),
                "dropped selector must not be wired"
            );
        }
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
