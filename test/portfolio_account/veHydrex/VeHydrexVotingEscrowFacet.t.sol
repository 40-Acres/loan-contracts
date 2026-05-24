// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";

/// @dev VeHydrexVotingEscrowFacet tests.
///
///      Mocks define the Hydrex VE behaviour wholesale; these tests verify the
///      facet's WIRING (which selectors are called, which collateral state
///      mutations land, which paths revert) -- they do NOT prove anything
///      about real Hydrex semantics. Where the mock fully defines a behaviour
///      the assertion is explicitly noted in the test docstring.
contract VeHydrexVotingEscrowFacetTest is VeHydrexDiamond {
    function setUp() public {
        // Warp into the future so epochStart arithmetic in dependent paths stays safe.
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
            "collateral tracked"
        );
        assertEq(underlying.balanceOf(address(ve)), 7e18, "underlying moved to VE");
    }

    function test_createLock_ROLLING_succeeds_collateralTracked() public {
        _createLock(3e18, IHydrexVotingEscrow.LockType.ROLLING);
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            3e18,
            "collateral tracked"
        );
    }

    // ----------------------------------------------------------------
    // onERC721Received: caller / ownership / reentrancy
    // ----------------------------------------------------------------

    function test_onERC721Received_revertsWhenCallerIsNotVE() public {
        // Anyone other than the real VE address must be rejected.
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.UnexpectedSender.selector, address(0xBEEF))
        );
        IERC721Receiver(portfolioAccount).onERC721Received(address(0), address(0), 1, "");
    }

    function test_onERC721Received_revertsWhenVEReportsOtherOwner() public {
        // Mint a token whose owner is NOT the portfolio account; faked transfer
        // simulates a buggy/malicious VE where ownership isn't actually moved.
        uint256 tokenId = ve.mintTo(address(0xCAFE), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        vm.prank(address(ve));
        vm.expectRevert(bytes("Token not in portfolio account"));
        IERC721Receiver(portfolioAccount).onERC721Received(address(ve), address(0xCAFE), tokenId, "");
    }

    function test_onERC721Received_reentryGuard_rejectsReentrantHook() public {
        // Receiver-hook reentrancy guard: arm the VE so the inner
        // `increaseUnlockTime` call -- made by the facet while still inside the
        // first onERC721Received -- attempts to re-enter onERC721Received with a
        // second tokenId. The nonReentrant TSTORE guard must reject.
        uint256 a = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        // A second token whose owner appears to be the account (so the inner
        // ownership check would have passed if not for the guard).
        uint256 b = ve.mintTo(portfolioAccount, 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.armReentry(portfolioAccount, b);

        vm.expectRevert(); // ReentrancyGuard reverts on the synchronous re-entry
        ve.safeTransferFrom(address(this), portfolioAccount, a);
    }

    // ----------------------------------------------------------------
    // onERC721Received: NON_PERMANENT -> ROLLING auto-conversion
    // ----------------------------------------------------------------

    function test_onERC721Received_nonPermanent_convertsToRolling() public {
        // Pre-fund and create a NON_PERMANENT token directly (sidestepping the
        // createLock policy check), then transfer it in. Facet must call
        // increaseUnlockTime(tokenId, 0, true) on the VE to convert.
        uint256 tokenId = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        uint256 callsBefore = ve.increaseUnlockTimeCalls();

        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);

        assertEq(ve.increaseUnlockTimeCalls(), callsBefore + 1, "increaseUnlockTime called once");
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 4e18, "collateral tracked");
    }

    function test_onERC721Received_nonPermanent_conversionRevertsBubble() public {
        // If increaseUnlockTime reverts, the whole receiver hook reverts and so
        // does the transfer. No try/catch in facet.
        uint256 tokenId = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.NON_PERMANENT);
        ve.setIncreaseUnlockTimeReverts(true);

        vm.expectRevert(bytes("increaseUnlockTime failed"));
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);
        // No collateral should be tracked.
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

        // Bucket pointer stays on the first token; the second arrival is tracked
        // as standalone collateral (no auto-merge, because Hydrex's merge() does
        // NOT burn the from-token and would leave zombie zero-amount NFTs in the
        // account -- this is the live-on-Base bug that drove the refactor).
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            first,
            "bucket unchanged"
        );
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        // Both still owned by the account.
        assertEq(ve.ownerOf(first), portfolioAccount, "first owned by account");
        assertEq(ve.ownerOf(second), portfolioAccount, "second owned by account");
        // Each token is tracked individually at its original amount.
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(first), 5e18, "first tracked standalone");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(second), 2e18, "second tracked standalone");
        // Total = 5 + 2 = 7 (same total as the old absorbed-merge world, different mechanism).
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "tracked");
    }

    /// @dev Post-refactor: when two PERMANENT tokens land in the account, the
    ///      receiver hook tracks them standalone. Users (or operators) can
    ///      still consolidate them via the explicit mergeInternal operator
    ///      path. After the merge: bucket pointer unchanged, first absorbs
    ///      second's amount, second is removed from tracked collateral.
    function test_onERC721Received_permanent_secondArrival_userCanCallMergeInternal_consolidates() public {
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);
        uint256 second = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, second);

        uint256 bucketBefore = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig))
            .getRebaseTokenId(portfolioAccount);

        // Operator-driven merge: second into first (the bucket).
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, second, first)
        );
        portfolioManager.multicall(cd, fac);

        // Bucket pointer unchanged.
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucketBefore,
            "bucket pointer unchanged"
        );
        // First grew by second's amount.
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(first), 7e18, "first absorbed second");
        // Second removed from tracking.
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(second), 0, "second removed from tracking");
        // Total invariant preserved at 7e18.
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 7e18, "sum invariant");
    }

    /// @dev Below-minimum PERMANENT transfer-in must revert via the CHECKED
    ///      add path (no unchecked bypass for receiver-hook arrivals anymore).
    function test_onERC721Received_permanent_belowMinimum_reverts() public {
        uint256 dust = MIN_COLLATERAL / 2;
        uint256 tokenId = ve.mintTo(address(this), dust, IHydrexVotingEscrow.LockType.PERMANENT);

        vm.expectRevert(bytes("Amount below minimum collateral"));
        ve.safeTransferFrom(address(this), portfolioAccount, tokenId);
    }

    function test_onERC721Received_permanent_staleBucket_resetsToIncoming() public {
        // First permanent arrival sets the bucket
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);

        // Move bucket out of the account (simulate token transferred out)
        ve.setOwner(first, address(0xDEAD));

        // A new permanent arrival should detect the stale pointer and re-bucket on itself.
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
        // toToken is NOT in the account
        uint256 from = ve.mintTo(address(0xABCD), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        uint256 to = ve.mintTo(address(0xCAFE), 2e18, IHydrexVotingEscrow.LockType.PERMANENT);
        vm.expectRevert();
        VeHydrexVotingEscrowFacet(portfolioAccount).merge(from, to);
    }

    function test_merge_externalToInternal_updatesTrackedCollateral() public {
        // Set up an internal token in the account
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, to);
        // External token owned by another address
        uint256 from = ve.mintTo(address(0xABCD), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);

        // Anyone can call merge as long as the ownership preconditions hold.
        VeHydrexVotingEscrowFacet(portfolioAccount).merge(from, to);

        // 3 + 4 = 7 tracked
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

        vm.prank(user); // not the PortfolioManager
        vm.expectRevert();
        VeHydrexVotingEscrowFacet(portfolioAccount).mergeInternal(from, to);
    }

    function test_mergeInternal_rollingTokens_consolidates() public {
        uint256 from = ve.mintTo(address(this), 2e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, from);
        uint256 to = ve.mintTo(address(this), 3e18, IHydrexVotingEscrow.LockType.ROLLING);
        ve.safeTransferFrom(address(this), portfolioAccount, to);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 5e18, "two rolling tracked");

        // Operator path: invoke via the multicall to satisfy onlyPortfolioManagerMulticall.
        vm.prank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.mergeInternal.selector, from, to)
        );
        portfolioManager.multicall(cd, fac);

        // After merge: from is removed, to grew to 5e18 -> total stays 5e18.
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 5e18, "post-merge total");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(from), 0, "from removed");
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(to), 5e18, "to grown");
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
        // from token not in the account
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
        // Hydrex auto-resets via the next vote; the facet must NOT call voter.reset().
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

        // Write a sale auth directly into the account's UserMarketplaceModule slot via a helper.
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

        // Original shrank to weights[0]/sum * 10 = 6e18.
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId), 6e18, "original shrunk");

        // New piece (id = idBefore + 1) tracked at 4e18.
        uint256 newId = idBefore + 1;
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(newId), 4e18, "new piece tracked");

        // Total invariant: 6 + 4 == 10.
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

        // Each piece should be 3e18 (last one absorbs rounding remainder).
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(tokenId), 3e18);
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(idBefore + 1), 3e18);
        assertEq(HydrexCollateralFacet(portfolioAccount).getLockedCollateral(idBefore + 2), 3e18);
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 9e18, "sum invariant");
    }

    function test_split_revertsWhenOriginalPieceBelowMinimum() public {
        // Lock at 1.5 * MIN; split 1:1 would leave each piece at 0.75 * MIN, below threshold.
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
        // Split 99:1 of a 2*MIN lock; original = ~1.98*MIN (ok), new piece = 0.02*MIN (below).
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

    /// @dev Writes a sale-authorization entry into the portfolio account's
    ///      UserMarketplaceModule storage via delegatecall to a helper facet.
    ///      We use the actual library's createSaleAuthorization entry point
    ///      (registered on the diamond as a one-off here) to keep semantics honest.
    function _setListingPrice(uint256 tokenId, uint256 price) internal {
        // Register a tiny helper that delegate-calls into UserMarketplaceModule.
        MarketplaceHelper helper = new MarketplaceHelper();
        vm.startPrank(owner_);
        bytes4[] memory s = new bytes4[](1);
        s[0] = MarketplaceHelper.setListing.selector;
        facetRegistry.registerFacet(address(helper), s, "MarketplaceHelper");
        vm.stopPrank();
        MarketplaceHelper(portfolioAccount).setListing(tokenId, price);
    }
}

contract MarketplaceHelper {
    function setListing(uint256 tokenId, uint256 price) external {
        // delegatecall context: writes into the portfolio account's storage
        UserMarketplaceModule.createSaleAuthorization(tokenId, price, address(0));
    }
}
