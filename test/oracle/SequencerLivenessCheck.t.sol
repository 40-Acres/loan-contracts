// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SequencerLivenessCheck} from "../../src/oracle/SequencerLivenessCheck.sol";
import {ISequencerLivenessCheck} from "../../src/oracle/ISequencerLivenessCheck.sol";
import {MockChainlinkSequencerUptimeFeed} from "../mocks/MockChainlinkSequencerUptimeFeed.sol";

/**
 * @title SequencerLivenessCheckTest
 * @dev Unit tests for the L2 sequencer-uptime predicate.
 *      Covers constructor bounds, isUp() truth-table (including the strict-greater
 *      grace-boundary mitigation), fail-closed branches (zero startedAt, feed revert,
 *      mistuned address), opt-out path (feed == address(0)), owner setters and
 *      Ownable2Step semantics.
 */
contract SequencerLivenessCheckTest is Test {
    SequencerLivenessCheck internal guard;
    MockChainlinkSequencerUptimeFeed internal feed;

    address internal constant OWNER = address(0xA110CE);
    address internal constant NEW_OWNER = address(0xB0B);
    address internal constant ATTACKER = address(0xBADBAD);

    uint256 internal constant GRACE = 1 hours;
    uint256 internal constant LTV = 150;

    // Fixed setUp warp; per project memory, do not rely on block.timestamp arithmetic
    // crossing vm.warp boundaries within a single test.
    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        feed = new MockChainlinkSequencerUptimeFeed();
        // Default: sequencer up, started long enough ago to pass grace.
        feed.setStatus(0, T0 - GRACE - 1);
        guard = new SequencerLivenessCheck(OWNER, address(feed), GRACE, LTV);
    }

    // ─────────────────────────────────────────────────────────
    // Constructor bounds
    // ─────────────────────────────────────────────────────────

    function test_constructor_revertsIfGracePeriodTooLow() public {
        vm.expectRevert(SequencerLivenessCheck.GracePeriodOutOfRange.selector);
        new SequencerLivenessCheck(OWNER, address(feed), 599, LTV);
    }

    function test_constructor_revertsIfGracePeriodTooHigh() public {
        vm.expectRevert(SequencerLivenessCheck.GracePeriodOutOfRange.selector);
        new SequencerLivenessCheck(OWNER, address(feed), 24 hours + 1, LTV);
    }

    function test_constructor_acceptsGracePeriodLowerBound() public {
        SequencerLivenessCheck g = new SequencerLivenessCheck(OWNER, address(feed), 600, LTV);
        assertEq(g.getGracePeriod(), 600);
    }

    function test_constructor_acceptsGracePeriodUpperBound() public {
        SequencerLivenessCheck g = new SequencerLivenessCheck(OWNER, address(feed), 24 hours, LTV);
        assertEq(g.getGracePeriod(), 24 hours);
    }

    function test_constructor_revertsIfLiquidationOverrideTooLow() public {
        vm.expectRevert(SequencerLivenessCheck.LiquidationOverrideOutOfRange.selector);
        new SequencerLivenessCheck(OWNER, address(feed), GRACE, 99);
    }

    function test_constructor_revertsIfLiquidationOverrideTooHigh() public {
        vm.expectRevert(SequencerLivenessCheck.LiquidationOverrideOutOfRange.selector);
        new SequencerLivenessCheck(OWNER, address(feed), GRACE, 201);
    }

    function test_constructor_acceptsLtvLowerBound() public {
        SequencerLivenessCheck g = new SequencerLivenessCheck(OWNER, address(feed), GRACE, 100);
        assertEq(g.getLiquidationOverrideLtv(), 100);
    }

    function test_constructor_acceptsLtvUpperBound() public {
        SequencerLivenessCheck g = new SequencerLivenessCheck(OWNER, address(feed), GRACE, 200);
        assertEq(g.getLiquidationOverrideLtv(), 200);
    }

    function test_constructor_emitsConfigEvents() public {
        vm.expectEmit(true, false, false, true);
        emit ISequencerLivenessCheck.FeedSet(address(feed));
        vm.expectEmit(false, false, false, true);
        emit ISequencerLivenessCheck.GracePeriodSet(GRACE);
        vm.expectEmit(false, false, false, true);
        emit ISequencerLivenessCheck.LiquidationOverrideLtvSet(LTV);
        new SequencerLivenessCheck(OWNER, address(feed), GRACE, LTV);
    }

    function test_constructor_setsOwner() public {
        assertEq(guard.owner(), OWNER);
    }

    // ─────────────────────────────────────────────────────────
    // isUp / isBorrowAllowed truth table
    // ─────────────────────────────────────────────────────────

    function test_isUp_trueWhenAnswerZeroAndGracePassed() public {
        feed.setStatus(0, T0 - GRACE - 1);
        assertTrue(guard.isUp());
    }

    function test_isUp_falseWhenAnswerOne_sequencerDown() public {
        // Sequencer reporting down: even if grace would otherwise be satisfied, must be false.
        feed.setStatus(1, T0 - GRACE - 1);
        assertFalse(guard.isUp());
    }

    /// @notice The strict-greater grace-boundary mitigation: at the EXACT boundary
    ///         the gate is still closed. lending-review mitigation #1.
    function test_isUp_falseAtExactGraceBoundary() public {
        // block.timestamp - startedAt == GRACE  ⇒  must be false (strict-greater)
        feed.setStatus(0, T0 - GRACE);
        assertFalse(guard.isUp());
    }

    function test_isUp_trueOneSecondAfterGraceBoundary() public {
        // block.timestamp - startedAt == GRACE + 1  ⇒  must be true
        feed.setStatus(0, T0 - GRACE - 1);
        assertTrue(guard.isUp());
    }

    function test_isUp_falseDuringGraceWindow() public {
        // Sequencer up for half the grace window only.
        feed.setStatus(0, T0 - (GRACE / 2));
        assertFalse(guard.isUp());
    }

    /// @notice Misconfigured-feed fail-closed: if the feed returns startedAt == 0,
    ///         we must NOT treat that as "up since unix epoch". This is a deliberate
    ///         divergence from Aave's reference implementation. Do not "fix" by
    ///         removing the check — it's the bouncer for an uninitialized round.
    function test_isUp_falseWhenStartedAtIsZero_failClosed() public {
        feed.setStatus(0, 0);
        assertFalse(guard.isUp(), "startedAt==0 must fail closed");
    }

    /// @notice Feed reverts → guard returns false (try/catch fail-closed).
    function test_isUp_falseWhenFeedReverts_failClosed() public {
        feed.setRevert(true);
        assertFalse(guard.isUp(), "reverting feed must fail closed");
    }

    /// @notice Linea/Ink opt-out: when feed address is zero, isUp() returns true.
    function test_isUp_trueWhenFeedAddressIsZero_optOut() public {
        vm.prank(OWNER);
        guard.setFeed(address(0));
        assertTrue(guard.isUp(), "address(0) feed = opt-out, treat as up");
    }

    function test_isBorrowAllowed_matchesIsUp_whenUp() public {
        feed.setStatus(0, T0 - GRACE - 1);
        assertTrue(guard.isBorrowAllowed());
        assertEq(guard.isBorrowAllowed(), guard.isUp());
    }

    function test_isBorrowAllowed_matchesIsUp_whenDown() public {
        feed.setStatus(1, T0 - GRACE - 1);
        assertFalse(guard.isBorrowAllowed());
        assertEq(guard.isBorrowAllowed(), guard.isUp());
    }

    function test_isBorrowAllowed_matchesIsUp_atGraceBoundary() public {
        feed.setStatus(0, T0 - GRACE);
        assertEq(guard.isBorrowAllowed(), guard.isUp());
        assertFalse(guard.isBorrowAllowed());
    }

    // ─────────────────────────────────────────────────────────
    // Owner setters
    // ─────────────────────────────────────────────────────────

    function test_setFeed_ownerCanUpdate_andEmits() public {
        MockChainlinkSequencerUptimeFeed feed2 = new MockChainlinkSequencerUptimeFeed();
        vm.expectEmit(true, false, false, true);
        emit ISequencerLivenessCheck.FeedSet(address(feed2));
        vm.prank(OWNER);
        guard.setFeed(address(feed2));
        assertEq(guard.getFeed(), address(feed2));
    }

    function test_setFeed_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER)
        );
        vm.prank(ATTACKER);
        guard.setFeed(address(0xdead));
    }

    function test_setGracePeriod_ownerCanUpdate_andEmits() public {
        vm.expectEmit(false, false, false, true);
        emit ISequencerLivenessCheck.GracePeriodSet(2 hours);
        vm.prank(OWNER);
        guard.setGracePeriod(2 hours);
        assertEq(guard.getGracePeriod(), 2 hours);
    }

    function test_setGracePeriod_revertsBelowMin() public {
        vm.expectRevert(SequencerLivenessCheck.GracePeriodOutOfRange.selector);
        vm.prank(OWNER);
        guard.setGracePeriod(599);
    }

    function test_setGracePeriod_revertsAboveMax() public {
        vm.expectRevert(SequencerLivenessCheck.GracePeriodOutOfRange.selector);
        vm.prank(OWNER);
        guard.setGracePeriod(24 hours + 1);
    }

    function test_setGracePeriod_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER)
        );
        vm.prank(ATTACKER);
        guard.setGracePeriod(2 hours);
    }

    function test_setLiquidationOverrideLtv_ownerCanUpdate_andEmits() public {
        vm.expectEmit(false, false, false, true);
        emit ISequencerLivenessCheck.LiquidationOverrideLtvSet(175);
        vm.prank(OWNER);
        guard.setLiquidationOverrideLtv(175);
        assertEq(guard.getLiquidationOverrideLtv(), 175);
    }

    function test_setLiquidationOverrideLtv_acceptsLowerBound() public {
        vm.prank(OWNER);
        guard.setLiquidationOverrideLtv(100);
        assertEq(guard.getLiquidationOverrideLtv(), 100);
    }

    function test_setLiquidationOverrideLtv_acceptsUpperBound() public {
        vm.prank(OWNER);
        guard.setLiquidationOverrideLtv(200);
        assertEq(guard.getLiquidationOverrideLtv(), 200);
    }

    function test_setLiquidationOverrideLtv_revertsBelowMin() public {
        vm.expectRevert(SequencerLivenessCheck.LiquidationOverrideOutOfRange.selector);
        vm.prank(OWNER);
        guard.setLiquidationOverrideLtv(99);
    }

    function test_setLiquidationOverrideLtv_revertsAboveMax() public {
        vm.expectRevert(SequencerLivenessCheck.LiquidationOverrideOutOfRange.selector);
        vm.prank(OWNER);
        guard.setLiquidationOverrideLtv(201);
    }

    function test_setLiquidationOverrideLtv_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER)
        );
        vm.prank(ATTACKER);
        guard.setLiquidationOverrideLtv(150);
    }

    // ─────────────────────────────────────────────────────────
    // Ownable2Step
    // ─────────────────────────────────────────────────────────

    function test_transferOwnership_doesNotFlipUntilAccepted() public {
        vm.prank(OWNER);
        guard.transferOwnership(NEW_OWNER);
        // Still old owner — pending only.
        assertEq(guard.owner(), OWNER, "owner must not change before accept");
        assertEq(guard.pendingOwner(), NEW_OWNER, "pendingOwner reflects pending transfer");

        // OWNER can still operate during pending state.
        vm.prank(OWNER);
        guard.setGracePeriod(2 hours);
        assertEq(guard.getGracePeriod(), 2 hours);

        // ATTACKER cannot accept.
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER)
        );
        vm.prank(ATTACKER);
        guard.acceptOwnership();

        // NEW_OWNER accepts → ownership flips.
        vm.prank(NEW_OWNER);
        guard.acceptOwnership();
        assertEq(guard.owner(), NEW_OWNER, "ownership flips after accept");

        // Old owner is now unauthorized.
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", OWNER)
        );
        vm.prank(OWNER);
        guard.setGracePeriod(3 hours);
    }
}
