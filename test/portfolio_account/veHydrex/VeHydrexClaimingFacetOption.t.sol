// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {VeHydrexClaimingFacet} from "../../../src/facets/account/veHydrex/VeHydrexClaimingFacet.sol";
import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {HydrexPortfolioFactoryConfig} from "../../../src/facets/account/veHydrex/HydrexPortfolioFactoryConfig.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {MockOptionToken} from "./mocks/MockOptionToken.sol";
import {MockHydrexVotingEscrow} from "./mocks/MockHydrexVotingEscrow.sol";

/// @dev VeHydrexClaimingFacet._doExecuteOption() coverage.
///
///      _doExecuteOption() redeems the account's oHYDX option-token balance into a
///      fresh veNFT and is supposed to consolidate that veNFT into the account's
///      rebase bucket lock. The oHYDX address is a hardcoded constant in the facet,
///      so we etch a MockOptionToken's runtime code onto that exact address.
///
///      These tests assert the end-state (claimFees succeeds, the bucket's
///      tracked collateral grows by the redeemed amount, no stray veNFT is left
///      owned by the account). _doExecuteOption() exercises the option into a
///      fresh veNFT, merges it into the bucket, and -- because live Hydrex
///      merge(from, to) does NOT burn `from` (proven via fork test) -- transfers
///      the leftover zero-value husk to BURN_ADDRESS so no untracked veNFT lingers
///      on the account.
contract VeHydrexClaimingFacetOptionTest is VeHydrexDiamond {
    // The constant oHYDX address baked into VeHydrexClaimingFacet.
    address internal constant OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;

    // Burn sink the facet disposes the zero-value merge husk to. Mirrors the
    // BURN_ADDRESS constant in VeHydrexClaimingFacet (the dead address).
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(100 weeks);
        _bootstrap();

        // Place the option-token mock at the facet's hardcoded oHYDX address.
        MockOptionToken impl = new MockOptionToken();
        vm.etch(OHYDX, address(impl).code);
        MockOptionToken(OHYDX).setVe(address(ve));
    }

    // ----------------------------------------------------------------
    // _doExecuteOption via claimFees
    // ----------------------------------------------------------------

    /// @dev With a valid rebase bucket and a nonzero oHYDX balance, calling
    ///      claimFees must redeem the option balance into a veNFT and merge that
    ///      veNFT INTO the bucket, growing the bucket's tracked collateral by the
    ///      redeemed amount.
    ///
    ///      PROVEN REAL BEHAVIOUR (via fork test): live Hydrex merge(from, to)
    ///      does NOT burn `from` -- it zeroes the amount but leaves `from` owned
    ///      by the caller. So _doExecuteOption disposes of the zero-value husk by
    ///      transferring it to BURN_ADDRESS. The account's veNFT count therefore
    ///      returns to its pre-execution value because the husk leaves the
    ///      account, NOT because merge burned it.
    function test_claimFees_executesOption_mergesIntoBucket_growsCollateral() public {
        uint256 rolling = _seedRollingLock(5e18);

        // Seed a valid PERMANENT rebase bucket via the receiver-hook transfer path.
        uint256 bucket = _seedBucketViaHook(3e18);
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            bucket,
            "bucket set"
        );

        // Snapshots before the option redemption.
        uint256 veCountBefore = ve.balanceOf(portfolioAccount); // rolling + bucket
        uint256 bucketBefore = HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket);
        uint256 totalBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        uint256 burnCountBefore = MockHydrexVotingEscrow(address(ve)).balanceOf(BURN_ADDRESS);
        // The husk is the next veNFT exerciseVe mints (the only mint during this
        // claimFees), so it equals totalNftsMinted() + 1.
        uint256 huskId = MockHydrexVotingEscrow(address(ve)).totalNftsMinted() + 1;

        // Account holds a nonzero oHYDX balance to redeem.
        uint256 optionAmount = 2e18;
        MockOptionToken(OHYDX).setBalance(portfolioAccount, optionAmount);

        // Empty fee arrays -- we only exercise the option path here.
        address[] memory addrs = new address[](0);
        address[][] memory tokens = new address[][](0);

        VeHydrexClaimingFacet(portfolioAccount).claimFees(addrs, tokens, rolling);

        // Option was redeemed exactly once into the account.
        assertEq(MockOptionToken(OHYDX).exerciseCalls(), 1, "option exercised once");
        assertEq(MockOptionToken(OHYDX).lastExercisedAmount(), optionAmount, "full balance redeemed");

        // The redeemed veNFT was merged into the bucket and the zero-value husk
        // disposed to the burn address: net account veNFT count unchanged, and no
        // stray NFT owned by the account.
        assertEq(ve.balanceOf(portfolioAccount), veCountBefore, "no stray veNFT left in account");
        assertEq(
            ve.balanceOf(portfolioAccount),
            veCountBefore,
            "account veNFT balance returned to pre-execution count"
        );

        // The husk is now owned by the burn address, not the account.
        assertEq(ve.ownerOf(huskId), BURN_ADDRESS, "husk veNFT disposed to burn address");
        assertEq(
            MockHydrexVotingEscrow(address(ve)).balanceOf(BURN_ADDRESS),
            burnCountBefore + 1,
            "burn address received exactly one husk"
        );
        // Husk carries zero value: all value folded into the bucket on merge.
        assertEq(ve.lockDetails(huskId).amount, 0, "husk has zero amount");

        // Bucket's tracked collateral grew by the redeemed amount.
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket),
            bucketBefore + optionAmount,
            "bucket collateral grew by redeemed amount"
        );

        // Total tracked collateral grew by the redeemed amount.
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            totalBefore + optionAmount,
            "total collateral grew by redeemed amount"
        );

        // oHYDX balance consumed.
        assertEq(MockOptionToken(OHYDX).balanceOf(portfolioAccount), 0, "oHYDX balance consumed");
    }

    /// @dev No oHYDX balance: claimFees must not exercise the option path, and the
    ///      bucket's tracked collateral is unchanged by the option logic. This
    ///      passes on current code (the broken merge branch is never entered) and
    ///      guards the fix against accidentally exercising on a zero balance.
    function test_claimFees_zeroOptionBalance_doesNotExercise() public {
        uint256 rolling = _seedRollingLock(5e18);
        uint256 bucket = _seedBucketViaHook(3e18);

        uint256 bucketBefore = HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket);
        uint256 veCountBefore = ve.balanceOf(portfolioAccount);

        // No oHYDX balance set (defaults to 0).
        address[] memory addrs = new address[](0);
        address[][] memory tokens = new address[][](0);

        VeHydrexClaimingFacet(portfolioAccount).claimFees(addrs, tokens, rolling);

        assertEq(MockOptionToken(OHYDX).exerciseCalls(), 0, "option not exercised");
        assertEq(
            HydrexCollateralFacet(portfolioAccount).getLockedCollateral(bucket),
            bucketBefore,
            "bucket unchanged"
        );
        assertEq(ve.balanceOf(portfolioAccount), veCountBefore, "veNFT count unchanged");
    }

    /// @dev oHYDX balance present but NO valid bucket: the `bucketValid` guard is
    ///      false, so the option path is skipped. Passes on current code; guards the
    ///      fix against exercising without a destination bucket.
    function test_claimFees_optionBalanceButNoBucket_doesNotExercise() public {
        uint256 rolling = _seedRollingLock(5e18);
        // No bucket seeded -> getRebaseTokenId == 0 -> bucketValid == false.
        assertEq(
            HydrexPortfolioFactoryConfig(address(portfolioFactoryConfig)).getRebaseTokenId(portfolioAccount),
            0,
            "no bucket"
        );

        MockOptionToken(OHYDX).setBalance(portfolioAccount, 2e18);

        address[] memory addrs = new address[](0);
        address[][] memory tokens = new address[][](0);

        VeHydrexClaimingFacet(portfolioAccount).claimFees(addrs, tokens, rolling);

        assertEq(MockOptionToken(OHYDX).exerciseCalls(), 0, "option not exercised without bucket");
        assertEq(MockOptionToken(OHYDX).balanceOf(portfolioAccount), 2e18, "oHYDX balance untouched");
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    /// @notice Seed a valid PERMANENT rebase bucket by transferring an externally
    ///         minted veNFT into the account via the receiver hook (which sets the
    ///         bucket pointer and tracks the collateral).
    function _seedBucketViaHook(uint256 amount) internal returns (uint256 bucket) {
        bucket = ve.mintTo(address(this), amount, IHydrexVotingEscrow.LockType.PERMANENT);
        ve.safeTransferFrom(address(this), portfolioAccount, bucket);
    }

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
            abi.encodeWithSelector(VeHydrexVotingEscrowFacet.createLock.selector, amount, IHydrexVotingEscrow.LockType.ROLLING)
        );
        bytes[] memory results = portfolioManager.multicall(cd, fac);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }
}
