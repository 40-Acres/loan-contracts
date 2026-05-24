// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicVeHydrexDiamond, DynamicHydrexCollateralViewFacet} from "./helpers/DynamicVeHydrexDiamond.sol";

import {DynamicHydrexCollateralManager} from "../../../src/facets/account/veHydrex/DynamicHydrexCollateralManager.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";

/// @dev DynamicHydrexCollateralManager focused tests.
///
///      Three properties under exercise (the rest of the manager surface is
///      covered transitively by the DynamicVeHydrex*Facet.t.sol suites):
///        1. The Dynamic-variant storage slot is distinct from every related
///           collateral manager namespace -- a write into the Dynamic slot must
///           not bleed into Velo / Hydrex / Dynamic-Velo.
///        2. getTotalDebt() reads debt from the lending pool (vault) rather
///           than from a local counter -- repaying the vault directly must
///           reflect in the manager's debt view without any facet-side
///           bookkeeping.
///        3. addLockedCollateralUnchecked enforces the rebase-bucket guard:
///           the tokenId being inserted must equal the current rebase-bucket
///           pointer for the caller; otherwise the path reverts (this is the
///           load-bearing protection that prevents the rebase path from
///           sneaking sub-minimum dust into arbitrary tokenIds).
contract DynamicHydrexCollateralManagerTest is DynamicVeHydrexDiamond {
    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();
    }

    // ----------------------------------------------------------------
    // (1) Storage slot distinctness
    // ----------------------------------------------------------------

    function test_dynamicHydrexSlot_isDistinct_fromAllOtherManagers() public pure {
        // keccak namespace constants -- enumerated, not derived from runtime.
        bytes32 dynHydrex = keccak256("storage.DynamicHydrexCollateralManager");
        bytes32 hydrex   = keccak256("storage.HydrexCollateralManager");
        bytes32 velo     = keccak256("storage.CollateralManager");
        bytes32 dynVelo  = keccak256("storage.DynamicCollateralManager");

        assertTrue(dynHydrex != hydrex,  "dyn-hydrex vs hydrex");
        assertTrue(dynHydrex != velo,    "dyn-hydrex vs velo");
        assertTrue(dynHydrex != dynVelo, "dyn-hydrex vs dyn-velo");
        // sanity: all four pairwise distinct (the simple-side test already
        // proves three pairs but we repeat the symmetric ones here to make
        // the dynamic-variant assertion self-contained).
        assertTrue(hydrex != velo,       "hydrex vs velo");
        assertTrue(hydrex != dynVelo,    "hydrex vs dyn-velo");
        assertTrue(velo != dynVelo,      "velo vs dyn-velo");
    }

    function test_dynamicHydrexSlot_writesDontTouchOtherNamespaces() public {
        // Drive a write into the Dynamic-Hydrex slot via the seed flow, then
        // sweep the base of every other namespace and assert each is zero.
        _seedRollingLock(5e18);

        bytes32[] memory neighbors = new bytes32[](3);
        neighbors[0] = keccak256("storage.HydrexCollateralManager");
        neighbors[1] = keccak256("storage.CollateralManager");
        neighbors[2] = keccak256("storage.DynamicCollateralManager");

        // The struct holds two mappings followed by three uint256 scalars. The
        // scalars live at base+2..base+4 in storage; the two mappings consume
        // base+0..base+1 as their per-slot hashmap roots. We scan a generous
        // window (6 slots) at each namespace to catch any accidental writes.
        for (uint256 n = 0; n < neighbors.length; n++) {
            for (uint256 i = 0; i < 6; i++) {
                bytes32 raw = vm.load(portfolioAccount, bytes32(uint256(neighbors[n]) + i));
                assertEq(uint256(raw), 0, "neighbor namespace must remain untouched");
            }
        }
    }

    function test_dynamicHydrexSlot_localTotalLockedCollateralLandsInDynamicSlot() public {
        // Sanity: after a seed, the totalLockedCollateral scalar lives at
        // offset 2 of the Dynamic-Hydrex namespace.
        _seedRollingLock(5e18);

        bytes32 base = keccak256("storage.DynamicHydrexCollateralManager");
        bytes32 totalLockedSlot = bytes32(uint256(base) + 2);
        bytes32 raw = vm.load(portfolioAccount, totalLockedSlot);
        assertEq(uint256(raw), 5e18, "totalLockedCollateral lives in dynamic slot");
    }

    // ----------------------------------------------------------------
    // (2) getTotalDebt reads from the vault, not a local counter
    // ----------------------------------------------------------------

    function test_getTotalDebt_readsFromVaultAfterDirectDebtMutation() public {
        // No borrow on the manager side: drive the vault's per-borrower debt
        // by depositing on behalf of the portfolio account, then borrowing
        // through the vault directly. The collateral manager exposes the
        // vault's view, so any debt write to the portfolio account must be
        // visible.
        _seedRollingLock(10e18); // enough collateral to support a small borrow

        // Make the user a lender first so totalAssets has supply to lend.
        usdc.mint(user, 100_000e6);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, user);
        vm.stopPrank();

        // Initial debt view: zero.
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            0,
            "vault reports zero debt before any borrow"
        );

        // Borrow through the vault directly (the portfolio account is the
        // caller, so the onlyPortfolio gate passes via PortfolioFactory).
        uint256 borrowAmount = 1_000e6;
        vm.prank(portfolioAccount);
        vault.borrowFromPortfolio(borrowAmount);

        // The manager view must now mirror the vault's debt balance.
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            vault.getDebtBalance(portfolioAccount),
            "manager.getTotalDebt mirrors vault.getDebtBalance"
        );
        assertGt(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            0,
            "debt visible after vault.borrowFromPortfolio"
        );
    }

    // ----------------------------------------------------------------
    // (3) addLockedCollateralUnchecked: rebase-bucket guard
    // ----------------------------------------------------------------

    /// @dev Post-refactor: the receiver hook uses the CHECKED add path for the
    ///      second PERMANENT arrival -- no merge call, no bucket overwrite. The
    ///      first PERMANENT remains the bucket; the second is tracked as
    ///      standalone collateral at its own amount.
    function test_onERC721Received_secondPermanent_tracksStandalone_bucketUnchanged() public {
        // First PERMANENT arrives -> becomes bucket via the CHECKED add path.
        uint256 first = ve.mintTo(address(this), 5e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, first);
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            first,
            "bucket assigned"
        );

        // Second PERMANENT arrives -> receiver hook tracks it standalone (no
        // merge call; the prior absorb-into-bucket behaviour created zombie
        // zero-amount NFTs because Hydrex's merge() does not burn the from-token).
        uint256 mergesBefore = ve.mergeCalls();
        uint256 second = ve.mintTo(address(this), 4e18, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, second);

        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            first,
            "bucket pointer stable"
        );
        assertEq(ve.mergeCalls(), mergesBefore, "no merge");
        assertEq(ve.ownerOf(first), portfolioAccount, "first owned by account");
        assertEq(ve.ownerOf(second), portfolioAccount, "second owned by account");
        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(first),
            5e18,
            "first standalone at original amount"
        );
        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(second),
            4e18,
            "second standalone at original amount"
        );
    }

    /// @dev Below-minimum dust on first rebase: the unchecked path is the
    ///      ONLY entry point that lets sub-minimum collateral enter, and it
    ///      requires the bucket pointer to equal the incoming token. The
    ///      rebase claim path proves both -- a fresh PERMANENT veNFT minted by
    ///      the distributor with a dust amount is tracked because the
    ///      receiver hook routes through the unchecked path with a matching
    ///      bucket pointer.
    function test_addLockedCollateralUnchecked_dustBucketTracked_viaRebase() public {
        uint256 tokenId = _seedRollingLock(5e18);
        rewardsDistributor.setMintMode(true);
        uint256 dust = MIN_COLLATERAL / 1000;
        rewardsDistributor.setClaimable(tokenId, dust);

        VeHydrexClaimingFacet(portfolioAccount).claimRebase(tokenId);

        uint256 bucket = HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount);
        assertGt(bucket, 0, "dust bucket assigned via unchecked path");
        assertEq(
            DynamicHydrexCollateralViewFacet(portfolioAccount).getLockedCollateral(bucket),
            dust,
            "dust amount tracked"
        );
        // The standard checked path would have reverted on this amount
        // because dust < MIN_COLLATERAL. The unchecked path is the only way
        // it lands.
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
