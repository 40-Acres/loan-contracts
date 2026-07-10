// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

/**
 * @title DynamicYieldBasisStakeCollateralNeutralityTest
 * @dev Dynamic-variant mirror of YieldBasisStakeCollateralNeutralityTest.
 *
 *  FIX UNDER TEST (Cantina / PR #261, mirrored to the Dynamic facet)
 *  -----------------------------------------------------------------
 *  DynamicYieldBasisLpFacet._stake now rejects any lossy gauge deposit:
 *    require(_gauge.convertToAssets(sharesMinted) >= lpSent, "Lossy stake");
 *  The guard is unconditional and debt-agnostic: it fires before any
 *  shortfall/enforcement logic, so a lossy stake ALWAYS reverts regardless
 *  of debt or borrow buffer. The stake branch of setStakedMode() also
 *  snapshots -> stakes -> reconciles -> enforces, but the _stake guard fires
 *  first on any loss.
 *
 *  The tunable gauge's setDepositFeeBps(N) makes deposit(assets) mint
 *  assets*(10000-N)/10000 shares while leaving convertRatioBps at 1:1, so
 *  convertToAssets(sharesMinted) = sharesMinted < lpSent -- a lossy stake.
 *  With fee 0 the gauge is 1:1 (lossless), demonstrating the guard is
 *  triggered by the loss, not by staking itself.
 */
contract DynamicYieldBasisStakeCollateralNeutralityTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal portfolioAccount;

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        underlying.mint(address(lp), 1_000_000e18);
        lp.mint(user, DEPOSIT * 10);
    }

    // ============ Helpers ============

    /// @dev Deposit LP collateral (held unstaked while flag is off).
    function _depositLP(uint256 amount) internal {
        _depositVia(portfolioAccount, MockERC20(address(lp)), amount);
    }

    /// @dev Borrow via PortfolioManager multicall (onlyPortfolioManagerMulticall).
    function _borrow(uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /// @dev Set protocol-wide directive then sweep this account into it.
    function _syncAndSetStake(bool mode) internal {
        _setStakedMode(mode); // helper sets factory config flag only
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 1: lossy stake at the LTV limit -> reverts
    // ============================================================

    /// @notice At the LTV limit, the _stake neutrality guard rejects the lossy
    ///         deposit outright with "Lossy stake" before any state is committed.
    function test_setStakedMode_lossyStake_atLtvLimit_reverts() public {
        _depositLP(DEPOSIT);

        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        _borrow(maxLoan);

        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");
        assertGt(debt, 0, "Sanity: there must be debt");

        // Lossy gauge: deposit mints 99% of LP as recoverable shares.
        vm.prank(owner_);
        gauge.setDepositFeeBps(100); // 1% loss

        // Flip the flag; expectRevert sits immediately before the sweep.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);

        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 2: lossy stake with borrow buffer -> still reverts
    // ============================================================

    /// @notice The guard is unconditional: a lossy stake reverts even well below
    ///         the LTV limit where a borrow buffer would absorb the loss.
    function test_setStakedMode_lossyStake_withBuffer_reverts() public {
        _depositLP(DEPOSIT);

        // Borrow well below max (max is 70e18; borrow 30e18).
        _borrow(30e18);

        vm.prank(owner_);
        gauge.setDepositFeeBps(100); // 1% loss

        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);

        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 3: lossy stake with zero debt -> still reverts
    // ============================================================

    /// @notice The guard is debt-agnostic: a lossy stake reverts even with no
    ///         debt, since it is enforced in _stake before any shortfall math.
    function test_setStakedMode_lossyStake_zeroDebt_reverts() public {
        _depositLP(DEPOSIT);

        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "Precondition: no debt");

        vm.prank(owner_);
        gauge.setDepositFeeBps(100); // 1% loss

        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);

        vm.expectRevert(bytes("Lossy stake"));
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 4: lossless stake at the LTV limit -> succeeds
    // ============================================================

    /// @notice An honest 1:1 gauge at the LTV limit must NOT revert. Recoverable
    ///         collateral is unchanged by the stake, so there is no new shortfall.
    ///         Guards against the fix being over-strict on honest gauges.
    function test_setStakedMode_losslessStake_atLtvLimit_succeeds() public {
        _depositLP(DEPOSIT);

        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // depositFeeBps stays 0 (default) -> 1:1, lossless stake.
        _syncAndSetStake(true);

        (uint256 staked, ) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "LP should be staked after stake");

        // Neutral: tracked collateral unchanged by an honest stake.
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Lossless stake must not change tracked collateral");

        // Debt unchanged.
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), debt, "Debt must be unchanged by stake");
    }

    // ============================================================
    // Test 5: unstake while underwater -> stays lenient
    // ============================================================

    /// @notice De-risking (unstake) must stay lenient to PRE-EXISTING
    ///         undercollateralization. The unstake branch now ALSO enforces
    ///         collateral-neutrality, but with a fresh per-block baseline an
    ///         underwater-but-honest unstake is neutral (end == start), so it must
    ///         NOT revert -- it only rejects an unstake that REALIZES NEW loss
    ///         (covered by test_setStakedMode_lossyUnstake_atLtvLimit_reverts).
    ///         Passes on CURRENT code (unstake never reverts) and after the fix.
    function test_setStakedMode_unstake_underwater_staysLenient() public {
        _depositLP(DEPOSIT);

        // Stake (lossless) so there are gauge shares to unstake.
        _syncAndSetStake(true);
        (uint256 stakedAfterStake, ) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(stakedAfterStake, 0, "Precondition: LP staked");

        // Borrow max while staked.
        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        assertGt(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "Precondition: debt exists");

        // Drop pps to push the position underwater (0.8x).
        lp.setPricePerShare(8e17);

        // Fresh block so the unstake snapshots the (already-underwater) shortfall
        // as its baseline; an honest redeem realizes no new loss (end == start).
        vm.roll(block.number + 1);

        // Unstake must SUCCEED despite being underwater (pre-existing shortfall
        // is tolerated; only newly-realized loss is rejected).
        _syncAndSetStake(false);

        (uint256 stakedAfterUnstake, uint256 unstakedAfterUnstake) =
            DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedAfterUnstake, 0, "Should have 0 staked after unstake");
        assertGt(unstakedAfterUnstake, 0, "LP should be back on the account after unstake");
    }

    // ============================================================
    // Test 6: lossy-redeem unstake at the LTV limit -> must revert (GAP)
    // ============================================================

    /// @notice At the LTV limit, an unstake whose gauge.redeem() delivers fewer LP
    ///         than convertToAssets(shares) implied REALIZES new loss: reconcile
    ///         ratchets tracked collateral down, dropping maxLoan below the debt.
    ///         The unstake branch must snapshot a per-block baseline and enforce
    ///         collateral-neutrality, reverting UndercollateralizedDebt(700000).
    ///
    ///         GAP (current code): the unstake branch takes NO shortfall baseline
    ///         and runs NO enforce, so it silently writes down collateral without
    ///         reverting. This test therefore FAILS on current code with "call did
    ///         not revert as expected" -- that failure IS the bug. The src fix
    ///         (snapshot -> redeem -> reconcile -> enforce on the unstake branch)
    ///         flips it to passing.
    function test_setStakedMode_lossyUnstake_atLtvLimit_reverts() public {
        _depositLP(DEPOSIT);

        // Stake lossless (honest 1:1) so there are gauge shares to unstake.
        _syncAndSetStake(true);
        (uint256 staked, ) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Precondition: LP staked lossless");

        // Borrow exactly max: position sits precisely at the LTV limit.
        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan (exactly at the limit)");
        assertGt(debt, 0, "Sanity: there must be debt");

        // Make redeem lossy: delivers convertToAssets(shares) - 1e6 LP. reconcile
        // ratchets tracked collateral down by 1e6 -> maxLoan drops by
        // 0.7 * 1e6 = 700000 -> shortfall becomes 700000 (nonzero).
        vm.prank(owner_);
        gauge.setRedeemShortfallWei(1e6);

        // Flip the protocol directive to unstaked.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(false);

        // Fresh block so the unstake snapshots its own (healthy) baseline, then
        // realizes the redeem loss within the same block -> end > start.
        vm.roll(block.number + 1);

        // Exact delta computes to 700000 (verified: debt 70e18 vs maxLoan 70e18 - 700000).
        vm.expectRevert(
            abi.encodeWithSelector(DynamicYieldBasisCollateralManager.UndercollateralizedDebt.selector, 700000)
        );
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    // ============================================================
    // Test 7: lossless-redeem unstake at the limit across a fresh block -> succeeds
    // ============================================================

    /// @notice An honest 1:1 unstake at the LTV limit must NOT revert. With a fresh
    ///         per-block baseline the unstake realizes no new loss (end == start),
    ///         so collateral-neutrality holds. Guards the upcoming unstake-branch
    ///         enforce against over-strictness; passes on current code too.
    function test_setStakedMode_losslessUnstake_atLtvLimit_succeeds() public {
        _depositLP(DEPOSIT);

        _syncAndSetStake(true);
        (uint256 stakedBefore, ) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(stakedBefore, 0, "Precondition: LP staked lossless");

        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        _borrow(maxLoan);
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), maxLoan, "Debt at the limit");

        // redeemShortfallWei stays 0 -> honest 1:1 redeem.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(false);

        // Fresh block: honest unstake is neutral (end == start).
        vm.roll(block.number + 1);

        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();

        (uint256 stakedAfter, uint256 unstakedAfter) =
            DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedAfter, 0, "Should have 0 staked after honest unstake");
        assertGt(unstakedAfter, 0, "LP should be back on the account after unstake");
    }
}
