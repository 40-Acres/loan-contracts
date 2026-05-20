// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicVeHydrexDiamond, DynamicHydrexCollateralViewFacet} from "./helpers/DynamicVeHydrexDiamond.sol";

import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

/// @dev DynamicVeHydrexClaimingFacet tests. Mirrors VeHydrexClaimingFacet.t.sol
///      but routes the claim path against DynamicHydrexCollateralManager. The
///      claim flow (voter + rewards distributor mocks) is identical between
///      simple and dynamic variants; what we're hardening here is that the
///      Dynamic-variant override of _updateLockedCollateral lands writes in the
///      correct slot.
contract DynamicVeHydrexClaimingFacetTest is DynamicVeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
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

    function test_claimRebase_nonPermanent_secondRebaseMergesIntoExistingBucket() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);

        rewardsDistributor.setClaimable(tokenId, 1e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);
        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);

        rewardsDistributor.setClaimable(tokenId, 2e18);
        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucket,
            "bucket pointer stable"
        );
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket), 3e18, "bucket grew");
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

    function test_claimRebase_staleBucket_skipsBucketUpdate() public {
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
