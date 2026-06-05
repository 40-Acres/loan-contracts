// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicVeHydrexDiamond, DynamicHydrexCollateralViewFacet} from "./helpers/DynamicVeHydrexDiamond.sol";

import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {DynamicVeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/DynamicVeHydrexClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {MockReentrantHydrexDistributor} from "./mocks/MockReentrantHydrexDistributor.sol";
import {MockOptionToken} from "./mocks/MockOptionToken.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev DynamicVeHydrexClaimingFacet tests. Mirrors VeHydrexClaimingFacet.t.sol
///      but routes the claim path against DynamicHydrexCollateralManager. The
///      claim flow (voter + rewards distributor mocks) is identical between
///      simple and dynamic variants; what we're hardening here is that the
///      Dynamic-variant override of _updateLockedCollateral lands writes in the
///      correct slot.
contract DynamicVeHydrexClaimingFacetTest is DynamicVeHydrexDiamond {
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
    // claimFees
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
        ve.setLockAmount(tokenId, 8e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId),
            8e18,
            "collateral refreshed"
        );
    }

    function test_claimRebase_permanentInPlace_growsSameTokenAndTracks() public {
        uint256 tokenId = _seedPermanentLock(5e18);
        rewardsDistributor.setMintMode(false);
        rewardsDistributor.setClaimable(tokenId, 3e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId),
            8e18,
            "permanent in-place grew"
        );
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            0,
            "no bucket assigned for createLock-PERMANENT"
        );
    }

    function test_claimRebase_nonPermanent_mintsBucket_andTracksBoth() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(tokenId, 2e18);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        assertGt(bucket, 0, "bucket assigned by receiver hook");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId), 5e18, "original unchanged");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket), 2e18, "bucket tracked");
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

        rewardsDistributor.setClaimable(tokenId, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucket,
            "bucket pointer stable"
        );
        assertEq(ve.balanceOf(portfolioAccount), balanceBefore, "no new mint");
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket), 3e18, "bucket grew via claimInto");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 8e18, "sum invariant");
    }

    function test_claimRebase_firstRebaseBelowMinimum_stillTracksBucket() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        uint256 dust = MIN_COLLATERAL / 1000;
        rewardsDistributor.setClaimable(tokenId, dust);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        assertGt(bucket, 0, "bucket assigned despite sub-minimum mint");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket), dust, "dust bucket tracked");
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            5e18 + dust,
            "original + dust bucket counted"
        );
    }

    function test_claimRebase_zeroClaimableWithStaleBucket_isNoOp() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);

        ve.setOwner(bucket, address(0xDEAD));
        uint256 trackedBefore = DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket);

        ve.setLockAmount(bucket, 99e18);

        rewardsDistributor.setClaimable(tokenId, 0);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket),
            trackedBefore,
            "stale bucket tracking unchanged"
        );
    }

    // ----------------------------------------------------------------
    // New regressions: claimInto, mint-sanity, fresh-seed pointer overwrite,
    // bucket-equals-source guard, reentrancy guard (Dynamic variant)
    // ----------------------------------------------------------------

    function test_claimRebase_nonPermanent_emitsActualDepositedAmount_fromClaimInto() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);

        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 X = 7e18;
        rewardsDistributor.setClaimable(tokenId, X);

        vm.expectEmit(true, false, false, true, portfolioAccount);
        emit RebaseClaimed(tokenId, X);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
    }

    function test_claimRebase_permanentSource_revertsIfMintOccurs() public {
        uint256 tokenId = _seedPermanentLock(5e18);
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

    function test_claimRebase_staleBucket_fallsThroughToFreshSeed_overwritesPointer() public {
        uint256 rolling = _seedRollingLock(5e18);

        uint256 staleId = ve.mintTo(address(0xDEAD), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);
        vm.prank(portfolioAccount);
        HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).setRebaseTokenId(staleId);
        assertTrue(ve.ownerOf(staleId) != portfolioAccount, "stale bucket not in account");

        rewardsDistributor.setMintMode(true);
        rewardsDistributor.setClaimable(rolling, 2e18);

        uint256 mergesBefore = ve.mergeCalls();
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(rolling);

        uint256 newBucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);
        assertTrue(newBucket != staleId, "pointer overwritten away from stale id");
        assertEq(ve.ownerOf(newBucket), portfolioAccount, "new bucket owned by account");
        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(newBucket),
            2e18,
            "new bucket tracked"
        );
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
    }

    function test_claimRebase_bucketEqualsSource_treatedAsInvalid_fallsThroughToFreshSeed() public {
        uint256 rolling = _seedRollingLock(5e18);

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
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(newBucket),
            2e18,
            "new bucket tracked"
        );
    }

    function test_claimRebase_reentrantDistributor_revertsViaNonReentrantGuard() public {
        uint256 tokenId = _seedRollingLock(5e18);

        MockReentrantHydrexDistributor reentrant = new MockReentrantHydrexDistributor(address(ve));
        DynamicVeHydrexClaimingFacet reentrantFacet = new DynamicVeHydrexClaimingFacet(
            address(portfolioFactory), address(ve), address(voter), address(reentrant)
        );
        vm.startPrank(owner_);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("claimFees(address[],address[][],uint256)"));
        selectors[1] = bytes4(keccak256("claimRebase(uint256)"));
        facetRegistry.replaceFacet(address(claimFacet), address(reentrantFacet), selectors, "ReentrantDynamicClaimingFacet");
        vm.stopPrank();

        reentrant.setClaimable(tokenId, 1e18);
        reentrant.setTarget(portfolioAccount, tokenId);

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
