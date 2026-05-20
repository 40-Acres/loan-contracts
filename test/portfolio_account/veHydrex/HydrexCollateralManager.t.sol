// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {HydrexCollateralManager} from "../../../src/facets/account/veHydrex/HydrexCollateralManager.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

/// @dev HydrexCollateralManager tests. Mocks define VE.lockDetails returns,
///      so these tests verify the library's wiring + storage discipline, not
///      Hydrex's actual lock-value computation.
contract HydrexCollateralManagerTest is VeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
    }

    // ----------------------------------------------------------------
    // No auto-perma conversion: addLockedCollateral never calls lockPermanent
    // ----------------------------------------------------------------

    function test_addLockedCollateral_doesNotCallLockPermanent() public {
        // The mock VE tracks lockPermanentCalls and never moves it; the
        // HydrexCollateralManager library does not invoke any lockPermanent
        // selector on the VE.
        uint256 before_ = ve.lockPermanentCalls();
        _seedRollingLock(5e18);
        assertEq(ve.lockPermanentCalls(), before_, "no auto-perma conversion attempted");
    }

    function test_addLockedCollateral_readsLockDetailsAmount_uint256() public {
        // Mock VE returns lockDetails.amount = 5e18; collateral tracks that exact value.
        uint256 tokenId = _seedRollingLock(5e18);
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId),
            5e18,
            "tracks lockDetails.amount as uint256"
        );
    }

    // ----------------------------------------------------------------
    // Minimum-collateral gate
    // ----------------------------------------------------------------

    function test_addLockedCollateral_rejectsBelowMinimumCollateral() public {
        // MIN_COLLATERAL is 1e18 in the harness; lock of 0.5e18 must revert.
        underlying.mint(user, 0.5e18);
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
                uint256(0.5e18),
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        vm.expectRevert(bytes("Amount below minimum collateral"));
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Sum invariant across multiple veNFTs
    // ----------------------------------------------------------------

    function test_totalLockedCollateral_sumsAcrossMultipleVeNFTs() public {
        // createLock() does NOT route through the receiver hook -- the bucket
        // pattern only kicks in for incoming transfers. Two ROLLING + one
        // PERMANENT seeded directly are tracked as three independent entries.
        uint256 a = _seedRollingLock(2e18);
        uint256 b = _seedRollingLock(3e18);
        uint256 c = _seedPermanentLock(4e18);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 9e18, "sum invariant");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(a), 2e18, "a tracked");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(b), 3e18, "b tracked");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(c), 4e18, "c tracked");
    }

    function test_totalLockedCollateral_bucketMergeKeepsSumInvariant() public {
        // Now exercise the bucket path explicitly via the receiver hook: two
        // PERMANENT incoming tokens merge into one bucket; the sum tracks
        // bucket amount only.
        uint256 rolling = _seedRollingLock(2e18);

        // Mint two PERMANENT tokens externally and route them through the
        // receiver hook to trigger bucket creation + absorption.
        uint256 first = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);
        uint256 second = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, second);

        // Sum = rolling 2 + bucket 7 = 9
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 9e18, "sum invariant");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(rolling), 2e18, "rolling untouched");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(first), 7e18, "first is bucket");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(second), 0, "second absorbed");
    }

    // ----------------------------------------------------------------
    // Distinct storage slot from Velo CollateralManager
    // ----------------------------------------------------------------

    function test_hydrexSlot_isDistinct_fromVeloCollateralManagerSlot() public pure {
        // Different keccak256 namespaces -> different slots.
        bytes32 hydrex = keccak256("storage.HydrexCollateralManager");
        bytes32 velo = keccak256("storage.CollateralManager");
        bytes32 dynamic_ = keccak256("storage.DynamicCollateralManager");
        bytes32 dynHydrex = keccak256("storage.DynamicHydrexCollateralManager");
        assertTrue(hydrex != velo, "hydrex vs velo");
        assertTrue(hydrex != dynamic_, "hydrex vs dynamic");
        assertTrue(hydrex != dynHydrex, "hydrex vs dyn-hydrex");
        assertTrue(velo != dynamic_, "velo vs dynamic");
        assertTrue(velo != dynHydrex, "velo vs dyn-hydrex");
        assertTrue(dynamic_ != dynHydrex, "dynamic vs dyn-hydrex");
    }

    function test_hydrexSlot_writesDontTouchVeloSlot() public {
        // Write into the Hydrex slot via a normal seed, then read the slot
        // value at the Velo slot location and confirm it is untouched.
        _seedRollingLock(5e18);

        // The HydrexCollateralManager stores totalLockedCollateral at offset 2
        // of the slot struct. We read the raw slot for the Velo namespace:
        bytes32 veloSlot = keccak256("storage.CollateralManager");
        // totalLockedCollateral is field index 2 (after two mappings which
        // themselves don't occupy data at the base slot). The base slot stores
        // the first non-mapping uint (totalLockedCollateral) IF the layout uses
        // sequential slots. Reading the base slot and the next two confirms zero.
        for (uint256 i = 0; i < 6; i++) {
            bytes32 raw = vm.load(portfolioAccount, bytes32(uint256(veloSlot) + i));
            assertEq(uint256(raw), 0, "velo slot scalar untouched");
        }
    }

    // ----------------------------------------------------------------
    // Invariant: sub-minimum tracking only via bucket pointer
    // ----------------------------------------------------------------

    /// @dev For any tokenId T where lockedCollaterals[T] != 0, either
    ///      T == rebaseTokenIds[account] (bucket bypass via
    ///      addLockedCollateralUnchecked) OR T's amount is at or above
    ///      getMinimumCollateral() (regular addLockedCollateral path).
    function test_invariant_subMinTracking_onlyViaBucket() public {
        // Lay down a non-bucket user-created lock at the minimum (passes the gate).
        uint256 userLock = _seedRollingLock(MIN_COLLATERAL);
        // Spawn a sub-minimum bucket via the receiver hook: a PERMANENT veNFT of
        // dust value enters and becomes the bucket.
        uint256 dustBucket = ve.mintTo(address(this), MIN_COLLATERAL / 1000, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, dustBucket);

        // dustBucket is below MIN but tracked because it's the bucket pointer.
        assertLt(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(dustBucket),
            MIN_COLLATERAL,
            "dust bucket below min"
        );
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            dustBucket,
            "dust token is the bucket"
        );

        // Invariant assertion: every tracked tokenId either is the bucket OR is >= min.
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        uint256[2] memory tracked = [userLock, dustBucket];
        for (uint256 i = 0; i < tracked.length; i++) {
            uint256 tid = tracked[i];
            uint256 amt = HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tid);
            if (amt == 0) continue;
            bool isBucket = tid == bucket;
            bool atOrAboveMin = amt >= MIN_COLLATERAL;
            assertTrue(isBucket || atOrAboveMin, "tracked sub-min token is not the bucket");
        }
    }

    /// @dev Negative-side check: a non-bucket sub-minimum lock cannot be tracked
    ///      via the regular addLockedCollateral entry point. Confirms the bypass
    ///      is restricted to the bucket.
    function test_invariant_subMinTracking_regularPathRejectsBelowMin() public {
        // The createLock helper goes through the regular path and the manager
        // require triggers. Already covered by
        // test_addLockedCollateral_rejectsBelowMinimumCollateral; this just makes
        // the invariant pairing explicit.
        IHydrexVotingEscrow.LockType lt = IHydrexVotingEscrow.LockType.ROLLING;
        uint256 below = MIN_COLLATERAL / 2;
        underlying.mint(user, below);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.createLock.selector, below, lt)
        );
        vm.expectRevert(bytes("Amount below minimum collateral"));
        portfolioManager.multicall(cd, fac);
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _seedRollingLock(uint256 amount) internal returns (uint256 tokenId) {
        return _seedLock(amount, IHydrexVotingEscrow.LockType.ROLLING);
    }

    function _seedPermanentLock(uint256 amount) internal returns (uint256 tokenId) {
        return _seedLock(amount, IHydrexVotingEscrow.LockType.PERMANENT);
    }

    function _seedLock(uint256 amount, IHydrexVotingEscrow.LockType lt) internal returns (uint256 tokenId) {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.createLock.selector, amount, lt)
        );
        bytes[] memory results = portfolioManager.multicall(cd, fac);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }
}
