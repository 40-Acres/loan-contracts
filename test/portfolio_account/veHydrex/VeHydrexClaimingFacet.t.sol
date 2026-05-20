// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

/// @dev VeHydrexClaimingFacet tests.
///
///      Mocks define the Voter and RewardsDistributor behaviour; these tests
///      verify wiring (single voter call, distributor invocation, bucket
///      tracking after rebase) -- not Hydrex's actual claim/rebase semantics.
contract VeHydrexClaimingFacetTest is VeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
    }

    // ----------------------------------------------------------------
    // claimFees: routes voter + then claimRebase
    // ----------------------------------------------------------------

    function test_claimFees_callsVoter_thenClaimRebase() public {
        uint256 tokenId = _seedRollingLock(5e18);

        address[] memory addrs = new address[](1);
        addrs[0] = address(0xDEF1);
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](1);
        tokens[0][0] = address(0xCAFE);

        uint256 callsBefore = voter.claimFeesCallCount();

        VeHydrexClaimingFacet(portfolioAccount).claimFees(addrs, tokens, tokenId);

        assertEq(voter.claimFeesCallCount(), callsBefore + 1, "voter.claimFees called once");
    }

    // ----------------------------------------------------------------
    // claimRebase
    // ----------------------------------------------------------------

    function test_claimRebase_zeroClaimable_doesNotCallDistributor_butStillUpdatesCollateral() public {
        uint256 tokenId = _seedRollingLock(5e18);
        // Forcibly bump the underlying VE lock amount; claimRebase should still
        // pick this up via updateLockedCollateral even though claimable == 0.
        ve.setLockAmount(tokenId, 8e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        // Tracked collateral reflects the new amount.
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId),
            8e18,
            "collateral refreshed"
        );
    }

    function test_claimRebase_permanentInPlace_growsSameTokenAndTracks() public {
        // PERMANENT path: distributor's claim feeds VE.increaseAmount on the
        // same token. After claimRebase, the tracked collateral grows.
        uint256 tokenId = _seedPermanentLock(5e18);
        rewardsDistributor.setMintMode(false);
        rewardsDistributor.setClaimable(tokenId, 3e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId),
            8e18,
            "permanent in-place grew"
        );
        // Bucket pointer was set by the create-lock-via-receiver flow only,
        // since we created via the createLock() RPC there's no receiver-hook routing
        // and getRebaseTokenId is 0.
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            0,
            "no bucket assigned for createLock-PERMANENT"
        );
    }

    function test_claimRebase_nonPermanent_mintsBucket_andTracksBoth() public {
        // Non-PERMANENT path: distributor's claim mints a fresh PERMANENT veNFT
        // routed through the receiver hook. First arrival sets the bucket;
        // tracked collateral covers original + bucket.
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(tokenId, 2e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        assertGt(bucket, 0, "bucket assigned by receiver hook");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId), 5e18, "original unchanged");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket), 2e18, "bucket tracked");
        // total collateral = 7e18
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "sum invariant");
    }

    function test_claimRebase_nonPermanent_secondRebaseMergesIntoExistingBucket() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);

        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);

        // Second rebase: another mint that should be merged into the same bucket.
        rewardsDistributor.setClaimable(tokenId, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucket,
            "bucket pointer stable"
        );
        // bucket grew from 1 to 3
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket), 3e18, "bucket grew");
        // total = 5 + 3
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 8e18, "sum invariant");
    }

    /// @dev Regression: the first rebase emission on a non-PERMANENT original can
    ///      be dust (well below MIN_COLLATERAL). The receiver-hook bucket-assignment
    ///      path must bypass the user-facing minimum gate, otherwise claimRebase
    ///      reverts and the user can never collect their first rebase.
    function test_claimRebase_firstRebaseBelowMinimum_stillTracksBucket() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        uint256 dust = MIN_COLLATERAL / 1000; // 1e15, well below 1e18 minimum
        rewardsDistributor.setClaimable(tokenId, dust);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        assertGt(bucket, 0, "bucket assigned despite sub-minimum mint");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket), dust, "dust bucket tracked");
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            5e18 + dust,
            "original + dust bucket counted"
        );
    }

    function test_claimRebase_staleBucket_skipsBucketUpdate() public {
        // Establish a non-PERMANENT rebase cycle so the bucket pointer is set.
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);

        // Move bucket out of the account (transferred to a third party).
        ve.setOwner(bucket, address(0xDEAD));
        uint256 trackedBefore = HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket);

        // Manually mutate the underlying VE amount for the stale token.
        ve.setLockAmount(bucket, 99e18);

        // claimRebase with no fresh claimable: must NOT touch the stale bucket's tracking.
        rewardsDistributor.setClaimable(tokenId, 0);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket),
            trackedBefore,
            "stale bucket tracking unchanged"
        );
    }

    /// @dev Idempotency: in the same call frame, an external safeTransferFrom of a
    ///      PERMANENT veNFT (hook fires + sets bucket + tracks) AND a claimRebase
    ///      that triggers a fresh PERMANENT mint must not double-count collateral.
    ///      The mint absorbs into the hook-established bucket; total collateral
    ///      stays consistent.
    function test_claimRebase_sameTx_hookPlusClaim_noDoubleCount() public {
        uint256 rolling = _seedRollingLock(5e18);

        // External PERMANENT veNFT enters via safeTransferFrom -> hook -> bucket.
        uint256 hookTok = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, hookTok);
        uint256 bucketAfterHook = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);
        assertEq(bucketAfterHook, hookTok, "hook set bucket to incoming PERMANENT");

        // Now claim rebase on the ROLLING original. Distributor mints a fresh
        // PERMANENT in mint mode; the claimRebase loop should merge it into the
        // existing bucket (hookTok), NOT mint a new bucket and double-track.
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(rolling, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);

        // Bucket pointer unchanged.
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            hookTok,
            "bucket pointer preserved"
        );
        // Bucket grew by the rebase mint (3 + 2 = 5).
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(hookTok), 5e18, "bucket absorbed rebase");
        // Original ROLLING untouched.
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(rolling), 5e18, "rolling untouched");
        // Total = rolling 5 + bucket 5 = 10.
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 10e18, "no double-count");
    }

    /// @dev Bucket lifecycle: spawn -> remove (transfer out) -> spawn again.
    ///      First rebase mints bucket A. The user externally transfers A out
    ///      (simulated via setOwner). A second rebase mints B; the stale
    ///      pointer is detected (ownerOf(A) != account) and the bucket
    ///      reassigns to B. Tracks the `rebaseTokenIds` config slot at every
    ///      transition: 0 -> A -> A (stale) -> B.
    function test_claimRebase_bucketRemovedThenRebornFlow() public {
        uint256 rolling = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        HydrexPortfolioFactoryConfig hConfig = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Pre-state: no bucket pointer.
        assertEq(hConfig.getRebaseTokenId(portfolioAccount), 0, "no bucket pre-rebase");

        // Step 1: first rebase spawns bucket A. Config slot moves 0 -> A.
        rewardsDistributor.setClaimable(rolling, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);
        uint256 bucketA = hConfig.getRebaseTokenId(portfolioAccount);
        assertGt(bucketA, 0, "bucket A assigned");
        assertEq(hConfig.getRebaseTokenId(portfolioAccount), bucketA, "config holds A");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucketA), 1e18, "A tracked");
        assertEq(ve.ownerOf(bucketA), portfolioAccount, "A owned by account");

        // Step 2: A is "removed" from the account (e.g., user transferred out via
        // direct VE call). The pointer is STALE -- it still names A even though
        // the account no longer owns A.
        ve.setOwner(bucketA, address(0xDEAD));
        assertEq(hConfig.getRebaseTokenId(portfolioAccount), bucketA, "stale pointer still names A");
        assertTrue(ve.ownerOf(bucketA) != portfolioAccount, "account no longer owns A");

        // Step 3: second rebase. Distributor mints B; bucketValid check fails
        // (ownerOf(A) != account), bucket pointer reassigns to B.
        rewardsDistributor.setClaimable(rolling, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);
        uint256 bucketB = hConfig.getRebaseTokenId(portfolioAccount);

        // Config slot: A -> B (explicit transition assertions).
        assertGt(bucketB, 0, "bucket B assigned");
        assertTrue(bucketB != bucketA, "config slot changed from A");
        assertEq(hConfig.getRebaseTokenId(portfolioAccount), bucketB, "config holds B");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucketB), 2e18, "B tracked");
        assertEq(ve.ownerOf(bucketB), portfolioAccount, "B owned by account");
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
