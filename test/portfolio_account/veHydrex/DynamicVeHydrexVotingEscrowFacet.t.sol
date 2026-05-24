// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicVeHydrexDiamond, DynamicHydrexCollateralViewFacet} from "./helpers/DynamicVeHydrexDiamond.sol";

import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";

/// @dev DynamicVeHydrexVotingEscrowFacet tests.
///
///      Mirrors VeHydrexVotingEscrowFacet.t.sol but mounts the Dynamic-variant
///      facet (which routes all collateral writes to
///      DynamicHydrexCollateralManager's distinct storage slot) on top of a real
///      DynamicFeesVault-backed loan pool. The lock-management semantics are
///      inherited unchanged from the simple facet, so the assertions are
///      identical. Both suites must stay green in the same test binary -- this
///      is the load-bearing proof that the dual collateral slots don't collide.
contract DynamicVeHydrexVotingEscrowFacetTest is DynamicVeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
    }

    // ----------------------------------------------------------------
    // createLock: lock-type policy enforcement
    // ----------------------------------------------------------------

    function test_createLock_NON_PERMANENT_reverts_LockTypeNotAllowed() public {
        uint256 amount = 5e18;
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
                IHydrexVotingEscrow.LockType.NON_PERMANENT
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.LockTypeNotAllowed.selector,
                IHydrexVotingEscrow.LockType.NON_PERMANENT
            )
        );
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    function test_createLock_PERMANENT_succeeds_collateralTracked() public {
        _createLock(7e18, IHydrexVotingEscrow.LockType.PERMANENT);
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            7e18,
            "collateral tracked in dynamic slot"
        );
        assertEq(underlying.balanceOf(address(ve)), 7e18, "underlying moved to VE");
    }

    function test_createLock_ROLLING_succeeds_collateralTracked() public {
        _createLock(3e18, IHydrexVotingEscrow.LockType.ROLLING);
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            3e18,
            "collateral tracked in dynamic slot"
        );
    }

    // ----------------------------------------------------------------
    // onERC721Received
    // ----------------------------------------------------------------

    function test_onERC721Received_revertsWhenCallerIsNotVE() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.UnexpectedSender.selector, address(0xBEEF))
        );
        IERC721Receiver(portfolioAccount).onERC721Received(address(0), address(0), 1, "");
    }

    function test_onERC721Received_revertsWhenVEReportsOtherOwner() public {
        uint256 tokenId = ve.mintTo(address(0xCAFE), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        vm.prank(address(ve));
        vm.expectRevert(bytes("Token not in portfolio account"));
        IERC721Receiver(portfolioAccount).onERC721Received(address(ve), address(0xCAFE), tokenId, "");
    }

    function test_onERC721Received_reentryGuard_rejectsReentrantHook() public {
        uint256 a = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        uint256 b = ve.mintTo(portfolioAccount, 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.armReentry(portfolioAccount, b);

        vm.expectRevert();
        ve.safeTransferFrom(address(this), portfolioAccount, a);
    }

    // ----------------------------------------------------------------
    // NON_PERMANENT -> ROLLING auto-conversion
    // ----------------------------------------------------------------

    function test_onERC721Received_nonPermanent_convertsToRolling() public {
        uint256 tokenId = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        uint256 callsBefore = ve.increaseUnlockTimeCalls();

        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);

        assertEq(ve.increaseUnlockTimeCalls(), callsBefore + 1, "increaseUnlockTime called once");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 4e18, "collateral tracked");
    }

    function test_onERC721Received_nonPermanent_conversionRevertsBubble() public {
        uint256 tokenId = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        ve.setIncreaseUnlockTimeReverts(true);

        vm.expectRevert(bytes("increaseUnlockTime failed"));
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "no collateral on revert");
    }

    function test_onERC721Received_rolling_isTrackedWithoutConversion() public {
        uint256 tokenId = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.ROLLING);
        uint256 callsBefore = ve.increaseUnlockTimeCalls();
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);
        assertEq(ve.increaseUnlockTimeCalls(), callsBefore, "no conversion call");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 4e18, "tracked");
    }

    // ----------------------------------------------------------------
    // PERMANENT bucket lifecycle
    // ----------------------------------------------------------------

    function test_onERC721Received_permanent_firstArrivalSetsBucket() public {
        uint256 tokenId = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            tokenId,
            "bucket assigned"
        );
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 5e18, "tracked");
    }

    function test_onERC721Received_permanent_secondArrivalTracksStandalone_bucketUnchanged() public {
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);

        uint256 mergesBefore = ve.mergeCalls();
        uint256 second = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, second);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            first,
            "bucket unchanged"
        );
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        assertEq(ve.ownerOf(first), portfolioAccount, "first owned by account");
        assertEq(ve.ownerOf(second), portfolioAccount, "second owned by account");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(first), 5e18, "first tracked standalone");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(second), 2e18, "second tracked standalone");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "tracked");
    }

    function test_onERC721Received_permanent_secondArrival_userCanCallMergeInternal_consolidates() public {
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);
        uint256 second = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, second);

        uint256 bucketBefore = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, second, first)
        );
        portfolioManager.multicall(cd, fac);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucketBefore,
            "bucket pointer unchanged"
        );
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(first), 7e18, "first absorbed second");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(second), 0, "second removed from tracking");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "sum invariant");
    }

    function test_onERC721Received_permanent_belowMinimum_reverts() public {
        uint256 dust = MIN_COLLATERAL / 2;
        uint256 tokenId = ve.mintTo(address(this), dust, IHydrexVotingEscrow.LockType.PERMANENT);

        vm.expectRevert(bytes("Amount below minimum collateral"));
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);
    }

    function test_onERC721Received_permanent_staleBucket_resetsToIncoming() public {
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);

        ve.setOwner(first, address(0xDEAD));

        uint256 fresh = ve.mintTo(address(this), 9e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, fresh);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            fresh,
            "bucket reassigned to fresh token"
        );
    }

    // ----------------------------------------------------------------
    // merge (external -> internal)
    // ----------------------------------------------------------------

    function test_merge_requires_toToken_isInAccount() public {
        uint256 from = ve.mintTo(address(0xABCD), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        uint256 to = ve.mintTo(address(0xCAFE), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        vm.expectRevert();
        VeHydrexVotingEscrowFacet(portfolioAccount).merge(from, to);
    }

    function test_merge_externalToInternal_updatesTrackedCollateral() public {
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, to);
        uint256 from = ve.mintTo(address(0xABCD), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);

        VeHydrexVotingEscrowFacet(portfolioAccount).merge(from, to);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "merged amount tracked");
    }

    // ----------------------------------------------------------------
    // mergeInternal (operator-only)
    // ----------------------------------------------------------------

    function test_mergeInternal_revertsForNonManagerCaller() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        vm.prank(user);
        vm.expectRevert();
        VeHydrexVotingEscrowFacet(portfolioAccount).mergeInternal(from, to);
    }

    function test_mergeInternal_rollingTokens_consolidates() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 5e18, "two rolling tracked");

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        portfolioManager.multicall(cd, fac);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 5e18, "post-merge total");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(from), 0, "from removed");
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(to), 5e18, "to grown");
    }

    function test_mergeInternal_revertsOnSameToken() public {
        uint256 tokenId = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, tokenId, tokenId)
        );
        vm.expectRevert(bytes("SameNFT"));
        portfolioManager.multicall(cd, fac);
    }

    function test_mergeInternal_revertsOnExternalFromToken() public {
        uint256 from = ve.mintTo(address(0xABCD), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        vm.expectRevert(bytes("from not in account"));
        portfolioManager.multicall(cd, fac);
    }

    function test_mergeInternal_doesNotCallVoterReset() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        uint256 resetsBefore = voter.resetCalls();
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        portfolioManager.multicall(cd, fac);
        assertEq(voter.resetCalls(), resetsBefore, "voter.reset NOT called on merge");
    }

    // ----------------------------------------------------------------
    // ListingActive guard
    // ----------------------------------------------------------------

    function test_mergeInternal_revertsWhenFromHasSaleAuthorization() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        _setListingPrice(from, 1 ether);

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexVotingEscrowFacet.ListingActive.selector, from));
        portfolioManager.multicall(cd, fac);
    }

    function test_mergeInternal_revertsWhenToHasSaleAuthorization() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);
        _setListingPrice(to, 1 ether);

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexVotingEscrowFacet.ListingActive.selector, to));
        portfolioManager.multicall(cd, fac);
    }

    // ----------------------------------------------------------------
    // split
    // ----------------------------------------------------------------

    function test_split_revertsForNonManagerCaller() public {
        uint256 tokenId = _createLock(10e18, IHydrexVotingEscrow.LockType.ROLLING);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6;
        weights[1] = 4;
        vm.expectRevert();
        VeHydrexVotingEscrowFacet(portfolioAccount).split(tokenId, weights);
    }

    function test_split_twoWay_shrinksOriginalAndTracksNewPiece() public {
        uint256 tokenId = _createLock(10e18, IHydrexVotingEscrow.LockType.ROLLING);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6;
        weights[1] = 4;

        uint256 idBefore = ve.totalNftsMinted();

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.split.selector, tokenId, weights)
        );
        portfolioManager.multicall(cd, fac);

        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId), 6e18, "original shrunk");

        uint256 newId = idBefore + 1;
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(newId), 4e18, "new piece tracked");

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 10e18, "sum invariant");
    }

    function test_split_threeWay_tracksAllNewPieces() public {
        uint256 tokenId = _createLock(9e18, IHydrexVotingEscrow.LockType.PERMANENT);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 1;
        weights[1] = 1;
        weights[2] = 1;

        uint256 idBefore = ve.totalNftsMinted();

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.split.selector, tokenId, weights)
        );
        portfolioManager.multicall(cd, fac);

        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(tokenId), 3e18);
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(idBefore + 1), 3e18);
        assertEq(DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(idBefore + 2), 3e18);
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 9e18, "sum invariant");
    }

    function test_split_revertsWhenOriginalPieceBelowMinimum() public {
        uint256 tokenId = _createLock(MIN_COLLATERAL * 3 / 2, IHydrexVotingEscrow.LockType.ROLLING);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.split.selector, tokenId, weights)
        );
        vm.expectRevert();
        portfolioManager.multicall(cd, fac);
    }

    function test_split_revertsWhenNewPieceBelowMinimum() public {
        uint256 tokenId = _createLock(MIN_COLLATERAL * 2, IHydrexVotingEscrow.LockType.ROLLING);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 99;
        weights[1] = 1;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.split.selector, tokenId, weights)
        );
        vm.expectRevert();
        portfolioManager.multicall(cd, fac);
    }

    function test_split_revertsWhenTokenHasSaleAuthorization() public {
        uint256 tokenId = _createLock(10e18, IHydrexVotingEscrow.LockType.ROLLING);
        _setListingPrice(tokenId, 1 ether);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.split.selector, tokenId, weights)
        );
        vm.expectRevert(abi.encodeWithSelector(VeHydrexVotingEscrowFacet.ListingActive.selector, tokenId));
        portfolioManager.multicall(cd, fac);
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    function _createLock(uint256 amount, IHydrexVotingEscrow.LockType lt) internal returns (uint256 tokenId) {
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

    function _setListingPrice(uint256 tokenId, uint256 price) internal {
        DynamicMarketplaceHelper helper = new DynamicMarketplaceHelper();
        vm.startPrank(owner_);
        bytes4[] memory s = new bytes4[](1);
        s[0] = DynamicMarketplaceHelper.setListing.selector;
        facetRegistry.registerFacet(address(helper), s, "DynamicMarketplaceHelper");
        vm.stopPrank();
        DynamicMarketplaceHelper(portfolioAccount).setListing(tokenId, price);
    }
}

contract DynamicMarketplaceHelper {
    function setListing(uint256 tokenId, uint256 price) external {
        UserMarketplaceModule.createSaleAuthorization(tokenId, price, address(0));
    }
}
