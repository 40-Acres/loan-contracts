// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicYieldBasisCollateralManager.addCollateral -- drift deadlock reproducer
 * ===========================================================================
 *
 * Mirrors YieldBasisLp_AddCollateralDriftDeadlock.t.sol for the dynamic-debt
 * variant. The deadlock shape is identical: when tracked data.shares exceeds
 * actually-recoverable LP by a drift delta D > 0, addCollateral(shares)
 * reverts InsufficientShareBalance(T+shares, T-D+shares) whenever
 * shares >= D, because the in-block reconcile early-returns and the balance
 * check then trips on the leftover phantom-share gap.
 *
 * The only structural difference vs the legacy manager is that the dynamic
 * variant reads debt live (getDebtBalance / getEffectiveDebtBalance) instead
 * of caching `data.debt`. The drift bug is upstream of the debt path so the
 * same shape applies.
 * =========================================================================*/

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

/// @dev Test-only facet that surfaces `data.shares` directly so tests can
///      distinguish in-memory clamps from real storage ratchets.
contract DYBDriftDeadlockInspector {
    function getCollateralSharesRaw() external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getCollateralShares();
    }

    function getCollateralRaw(address vault, address underlying)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return DynamicYieldBasisCollateralManager.getCollateral(vault, underlying);
    }
}

contract DynamicYieldBasisLp_AddCollateralDriftDeadlockTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    DYBDriftDeadlockInspector internal inspector;
    address internal portfolioAccount;

    uint256 internal constant T_DEPOSIT = 10e18;       // initial tracked LP
    uint256 internal constant DRIFT_DELTA = 1e17;      // 1% drift
    uint256 internal constant DRIFT_RATIO_BPS = 9_900; // 99% -> 1% gauge drift
    uint256 internal constant SHARES_FRESH = 1e18;     // 1 LP fresh deposit

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        // Seed underlying liquidity in the LP so withdraws can deliver
        // (defensive -- this suite does not withdraw, but matches the
        // pattern of other dynamic YB tests).
        underlying.mint(address(lp), 1_000_000e18);

        // Mint LP to user so they can deposit twice.
        lp.mint(user, T_DEPOSIT * 10);

        // Register the inspector facet AFTER _build so we can read raw shares.
        inspector = new DYBDriftDeadlockInspector();
        vm.startPrank(owner_);
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = DYBDriftDeadlockInspector.getCollateralSharesRaw.selector;
        sel[1] = DYBDriftDeadlockInspector.getCollateralRaw.selector;
        facetRegistry.registerFacet(address(inspector), sel, "DYBDriftDeadlockInspector");
        vm.stopPrank();

        // Default to auto-stake mode so the deposit path mirrors the legacy
        // PRIMARY reproducer: T LP -> gauge -> drift via setConvertRatioBps.
        _setStakedMode(true);
    }

    // ============ helpers ============

    function _approveOnly(uint256 amount) internal {
        vm.prank(user);
        lp.approve(portfolioAccount, amount);
    }

    function _depositCallOnly(uint256 amount) internal {
        vm.prank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
    }

    function _rawShares() internal view returns (uint256) {
        return DYBDriftDeadlockInspector(portfolioAccount).getCollateralSharesRaw();
    }

    function _rawCollateral() internal view returns (uint256 shares, uint256 basis) {
        (shares, basis, ) = DYBDriftDeadlockInspector(portfolioAccount)
            .getCollateralRaw(address(lp), address(underlying));
    }

    // ============ TEST 1: PRIMARY (post-fix flip) ============

    /// @notice Post-fix expected behavior. Drift-aware snapshot subtracts the
    ///         incoming deposit from the observed LP balance before deciding
    ///         whether to ratchet, so the deposit succeeds and data.shares
    ///         lands at (T - D) + shares with proportional basis haircut.
    function test_addCollateral_driftLessThanDeposit_succeedsWithRatchet() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        assertEq(_rawShares(), T_DEPOSIT, "data.shares == T");

        (, uint256 basisBefore) = _rawCollateral();

        vm.roll(block.number + 1);
        gauge.setConvertRatioBps(DRIFT_RATIO_BPS);

        uint256 actualLpPre = lp.balanceOf(portfolioAccount)
            + gauge.convertToAssets(gauge.balanceOf(portfolioAccount));
        assertEq(actualLpPre, T_DEPOSIT - DRIFT_DELTA, "actual recoverable LP is (T - D)");

        _depositVia(portfolioAccount, MockERC20(address(lp)), SHARES_FRESH);

        uint256 expectedShares = T_DEPOSIT - DRIFT_DELTA + SHARES_FRESH;
        assertEq(_rawShares(), expectedShares, "data.shares = (T - D) + shares");

        (, uint256 basisAfter) = _rawCollateral();
        uint256 hairedPriorBasis = (basisBefore * (T_DEPOSIT - DRIFT_DELTA)) / T_DEPOSIT;
        assertEq(basisAfter, hairedPriorBasis + SHARES_FRESH, "basis = haircut(prior) + new");
    }

    // ============ TEST 2: NO-DRIFT CONTROL ============

    /// @notice Same shape as the deadlock test but with no drift. Proves the
    ///         harness is wired correctly.
    function test_addCollateral_noDrift_succeeds() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        assertEq(_rawShares(), T_DEPOSIT, "data.shares == T");

        vm.roll(block.number + 1);
        // No setConvertRatioBps call -- gauge stays 1:1.

        uint256 actualLpPre = lp.balanceOf(portfolioAccount)
            + gauge.convertToAssets(gauge.balanceOf(portfolioAccount));
        assertEq(actualLpPre, T_DEPOSIT, "no drift: actual == T");

        // Fresh deposit must succeed.
        _depositVia(portfolioAccount, MockERC20(address(lp)), SHARES_FRESH);
        assertEq(_rawShares(), T_DEPOSIT + SHARES_FRESH, "data.shares = T + shares");
    }

    // ============ TEST 3: UNSTAKED-MODE DIRECT-LP DRIFT ============

    /// @notice Post-fix: drift detection fires on direct-LP drift too.
    function test_addCollateral_unstakedDirectLpDrift_ratchets_thenSucceeds() public {
        _setStakedMode(false);
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        assertEq(_rawShares(), T_DEPOSIT, "data.shares == T after unstaked deposit");
        assertEq(lp.balanceOf(portfolioAccount), T_DEPOSIT, "LP held directly");
        assertEq(gauge.balanceOf(portfolioAccount), 0, "no gauge shares");

        vm.roll(block.number + 1);
        uint256 delta = DRIFT_DELTA;
        vm.prank(portfolioAccount);
        lp.transfer(address(0xdead), delta);
        assertEq(lp.balanceOf(portfolioAccount), T_DEPOSIT - delta, "direct LP reduced");

        _depositVia(portfolioAccount, MockERC20(address(lp)), SHARES_FRESH);
        assertEq(_rawShares(), T_DEPOSIT - delta + SHARES_FRESH, "ratchets to (T - delta) + shares");
    }

    // ============ TEST 4: shares < drift succeeds with full ratchet ============

    function test_addCollateral_sharesBelowDrift_succeedsWithFullRatchet() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        vm.roll(block.number + 1);

        gauge.setConvertRatioBps(8_000);
        uint256 expectedDrift = T_DEPOSIT - (T_DEPOSIT * 8_000 / 10_000); // 2e18
        uint256 smallShares   = 1e18;

        _depositVia(portfolioAccount, MockERC20(address(lp)), smallShares);

        assertEq(_rawShares(), (T_DEPOSIT - expectedDrift) + smallShares, "tracked = (T - drift) + shares");
    }

    // ============ TEST 5: full-drift wipe accepts a large deposit ============

    function test_addCollateral_fullDriftWipe_acceptsLargeDeposit() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        vm.roll(block.number + 1);
        gauge.setConvertRatioBps(1);

        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        uint256 residual = (T_DEPOSIT * 1) / 10_000;
        assertEq(_rawShares(), residual + T_DEPOSIT, "shares = residual + incoming after near-total wipe");
    }

    // ============ TEST 6: per-share basis invariant under ratchet ============

    function test_addCollateral_basisHaircutPreservesPerShare() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), T_DEPOSIT);
        (uint256 sharesBefore, uint256 basisBefore) = _rawCollateral();

        vm.roll(block.number + 1);
        gauge.setConvertRatioBps(DRIFT_RATIO_BPS);

        _depositVia(portfolioAccount, MockERC20(address(lp)), SHARES_FRESH);

        (uint256 sharesAfter, uint256 basisAfter) = _rawCollateral();

        uint256 perShareBefore = basisBefore * 1e18 / sharesBefore;
        uint256 perShareAfter  = basisAfter  * 1e18 / sharesAfter;
        assertEq(perShareAfter, perShareBefore, "per-share basis preserved");
    }
}
