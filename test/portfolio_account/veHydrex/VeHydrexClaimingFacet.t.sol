// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {MockReentrantHydrexDistributor} from "./mocks/MockReentrantHydrexDistributor.sol";
import {MockOptionToken} from "./mocks/MockOptionToken.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev VeHydrexClaimingFacet tests.
///
///      Mocks define the Voter and RewardsDistributor behaviour; these tests
///      verify wiring (single voter call, distributor invocation, bucket
///      tracking after rebase) -- not Hydrex's actual claim/rebase semantics.
contract VeHydrexClaimingFacetTest is VeHydrexDiamond {
    // Mirrors of facet events used for vm.expectEmit assertions.
    event RebaseClaimed(uint256 indexed tokenId, uint256 amount);
    event RebaseBucketAssigned(uint256 indexed tokenId, address indexed owner);

    // Hardcoded oHYDX address baked into VeHydrexClaimingFacet. On Base it always
    // has code; etch a zero-balance mock so _doExecuteOption reads 0 and skips.
    address internal constant OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;

    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();

        MockOptionToken impl = new MockOptionToken();
        vm.etch(OHYDX, address(impl).code);
        MockOptionToken(OHYDX).setVe(address(ve));
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

    function test_claimRebase_nonPermanent_secondRebase_usesClaimInto_noNewMint() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);

        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);

        // Snapshot pre-second-rebase state to prove the second emission goes
        // through claimInto, not via another fresh mint.
        uint256 balanceBefore = ve.balanceOf(portfolioAccount);
        uint256 mergesBefore = ve.mergeCalls();

        // Second rebase: with the bucket already valid, the facet must use
        // distributor.claimInto(tokenId, bucket) to deposit directly into the
        // bucket -- no fresh NFT mint, no merge call.
        rewardsDistributor.setClaimable(tokenId, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucket,
            "bucket pointer stable"
        );
        assertEq(ve.balanceOf(portfolioAccount), balanceBefore, "no new mint");
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        // bucket grew from 1 to 3 via claimInto
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket), 3e18, "bucket grew via claimInto");
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

    function test_claimRebase_zeroClaimableWithStaleBucket_isNoOp() public {
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

    /// @dev Idempotency: in the same setUp frame, an external safeTransferFrom of a
    ///      PERMANENT veNFT (hook fires + sets bucket + tracks) AND a subsequent
    ///      claimRebase on a ROLLING original must not double-count collateral.
    ///      Because a valid bucket is now set, claimRebase takes the claimInto
    ///      path: it deposits the rebase amount directly into the hook-established
    ///      bucket. No new mint, no merge call.
    function test_claimRebase_sameTx_hookPlusClaimInto_noDoubleCount() public {
        uint256 rolling = _seedRollingLock(5e18);

        // External PERMANENT veNFT enters via safeTransferFrom -> hook -> bucket.
        uint256 hookTok = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, hookTok);
        uint256 bucketAfterHook = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);
        assertEq(bucketAfterHook, hookTok, "hook set bucket to incoming PERMANENT");

        // Snapshot enumerable balance + merge counter. Account holds two veNFTs
        // (rolling + hookTok). claimInto must not change either count.
        uint256 balanceBefore = ve.balanceOf(portfolioAccount);
        assertEq(balanceBefore, 2, "rolling + hookTok present");
        uint256 mergesBefore = ve.mergeCalls();

        // Now claim rebase on the ROLLING original. mintMode is irrelevant for
        // this path -- the facet sees a valid bucket and routes through
        // distributor.claimInto, which deposits into hookTok with no new mint.
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(rolling, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);

        // Bucket pointer unchanged.
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            hookTok,
            "bucket pointer preserved"
        );
        // No new mint into the account.
        assertEq(ve.balanceOf(portfolioAccount), balanceBefore, "only rolling + hookTok, no fresh mint");
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        // Bucket grew by the rebase deposit (3 + 2 = 5).
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(hookTok), 5e18, "bucket grew via claimInto");
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
    // New regressions: claimInto, mint-sanity, fresh-seed pointer overwrite,
    // bucket-equals-source guard, reentrancy guard
    // ----------------------------------------------------------------

    /// @dev The RebaseClaimed event in the claimInto path must report the amount
    ///      that the distributor actually deposited (the return value of
    ///      claimInto), not the pre-call claimable snapshot. With the mock these
    ///      are equal, but the assertion locks in the source argument.
    function test_claimRebase_nonPermanent_emitsActualDepositedAmount_fromClaimInto() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);

        // First rebase seeds the bucket.
        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        // Second rebase uses claimInto; the emitted amount must equal the value
        // returned by claimInto (the deposited amount, here 7e18).
        uint256 X = 7e18;
        rewardsDistributor.setClaimable(tokenId, X);

        vm.expectEmit(true, false, false, true, portfolioAccount);
        emit RebaseClaimed(tokenId, X);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
    }

    /// @dev PERMANENT-source sanity: Hydrex applies the rebase in-place on
    ///      the source lock. If the distributor ever drifts and mints a fresh
    ///      NFT instead, the facet must revert (UnexpectedNewMint) rather than
    ///      silently orphan the mint.
    function test_claimRebase_permanentSource_revertsIfMintOccurs() public {
        uint256 tokenId = _seedPermanentLock(5e18);
        // Arm the distributor to mint a fresh NFT on claim() despite the source
        // being PERMANENT. The facet's balance snapshot guard must catch this.
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(tokenId, 1e18);

        uint256 balanceBefore = ve.balanceOf(portfolioAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                VeHydrexClaimingFacet.UnexpectedNewMint.selector, balanceBefore, balanceBefore + 1
            )
        );
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
    }

    /// @dev Non-PERMANENT fresh-seed sanity: the facet expects EXACTLY one
    ///      new NFT to land in the account when distributor.claim runs in
    ///      mintMode and no bucket exists yet. If the distributor ever mints
    ///      more than one, the facet must revert.
    function test_claimRebase_nonPermanent_firstTimeSeed_revertsIfMultipleMints() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setMintsPerClaim(2);
        rewardsDistributor.setClaimable(tokenId, 1e18);

        uint256 balanceBefore = ve.balanceOf(portfolioAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                VeHydrexClaimingFacet.UnexpectedNewMint.selector, balanceBefore + 1, balanceBefore + 2
            )
        );
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
    }

    /// @dev Stale-bucket fresh-seed: when the bucket pointer names a token the
    ///      account no longer owns, claimRebase must NOT use claimInto on it.
    ///      Instead the fresh-seed path runs (mint + setRebaseTokenId(newId) +
    ///      track unchecked). Bucket pointer ends pointing at the newly minted
    ///      id, not the stale id.
    function test_claimRebase_staleBucket_fallsThroughToFreshSeed_overwritesPointer() public {
        uint256 rolling = _seedRollingLock(5e18);

        // Pre-set the bucket pointer to a stale token. We mint a PERMANENT and
        // immediately move it out of the account, then write the pointer via
        // setRebaseTokenId pranked as the portfolio account.
        uint256 staleId = ve.mintTo(address(0xDEAD), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);
        vm.prank(portfolioAccount);
        HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).setRebaseTokenId(staleId);
        assertTrue(ve.ownerOf(staleId) != portfolioAccount, "stale bucket not in account");

        // Arm distributor for the fresh-seed path.
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(rolling, 2e18);

        uint256 mergesBefore = ve.mergeCalls();
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);

        uint256 newBucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);
        assertTrue(newBucket != staleId, "pointer overwritten away from stale id");
        assertEq(ve.ownerOf(newBucket), portfolioAccount, "new bucket owned by account");
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(newBucket), 2e18, "new bucket tracked"
        );
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
    }

    /// @dev Bucket-equals-source pathological case: if the bucket pointer
    ///      happens to be set to the rebase source tokenId itself, the
    ///      `bucket != tokenId` guard makes it invalid -> fresh-seed path runs.
    function test_claimRebase_bucketEqualsSource_treatedAsInvalid_fallsThroughToFreshSeed() public {
        uint256 rolling = _seedRollingLock(5e18);

        // Point the bucket at the rolling source itself.
        vm.prank(portfolioAccount);
        HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).setRebaseTokenId(rolling);

        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(rolling, 2e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);

        uint256 newBucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);
        assertTrue(newBucket != rolling, "bucket pointer reassigned away from source");
        assertGt(newBucket, 0, "new bucket assigned");
        assertEq(ve.ownerOf(newBucket), portfolioAccount, "new bucket owned by account");
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(newBucket), 2e18, "new bucket tracked"
        );
    }

    /// @dev nonReentrant guard: an adversarial distributor that tries to call
    ///      back into claimRebase synchronously while the outer call is still
    ///      on the stack must be rejected by the ReentrancyGuardTransient on
    ///      the public claimRebase entry point.
    function test_claimRebase_reentrantDistributor_revertsViaNonReentrantGuard() public {
        uint256 tokenId = _seedRollingLock(5e18);

        // We can't swap the registered facet's immutable distributor pointer,
        // so we deploy a fresh claim facet wired to a reentrant distributor and
        // hot-swap it via replaceFacet (registerFacet would reject the
        // already-mapped selectors).
        MockReentrantHydrexDistributor reentrant = new MockReentrantHydrexDistributor(address(ve));
        VeHydrexClaimingFacet reentrantFacet = new VeHydrexClaimingFacet(
            address(portfolioFactory), address(ve), address(voter), address(reentrant)
        );
        vm.startPrank(owner_);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("claimFees(address[],address[][],uint256)"));
        selectors[1] = bytes4(keccak256("claimRebase(uint256)"));
        facetRegistry.replaceFacet(address(claimFacet), address(reentrantFacet), selectors, "ReentrantClaimingFacet");
        vm.stopPrank();

        reentrant.setClaimable(tokenId, 1e18);
        reentrant.setTarget(portfolioAccount, tokenId);

        // The outer claimRebase acquires the guard, then the distributor's
        // claim() tries to re-enter claimRebase synchronously. The transient
        // guard must reject with ReentrancyGuardReentrantCall.
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
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
