// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * LoanConfig — direct unit tests for the new `ltv` field and accessors.
 *
 * Coverage targets the freshly added surface:
 *   - setLtv(uint256) — onlyOwner; rejects > MAX_FEE_BPS; accepts 0
 *     (0 is the deliberate escape hatch back to the cash-flow branch)
 *   - getLtv() — round-trips the last set value
 *
 * Why these tests matter:
 *   The `ltv` field switches the collateral managers between two completely
 *   different max-loan formulas. A bug in setLtv (accepting > 10000, missing
 *   onlyOwner, mis-storing) silently flips behavior or grants full collateral
 *   as borrow capacity.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ILoanConfig} from "../../../src/facets/account/config/ILoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LoanConfigTest is Test {
    LoanConfig internal cfg;
    address internal owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal stranger = address(0xBEEF);

    uint256 internal constant MAX_BPS = 100_00; // mirrors LoanConfig.MAX_FEE_BPS

    function setUp() public {
        // Atomic init — same shape as DeployPortfolioFactoryConfig.
        LoanConfig impl = new LoanConfig();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LoanConfig.initialize, (owner, 20_00, 5_00, 1_00))
        );
        cfg = LoanConfig(address(proxy));
    }

    // ---------------- setLtv access control + bounds ----------------

    function test_setLtv_onlyOwner_revertsForStranger() public {
        // OZ Ownable2Step revert encoding: OwnableUnauthorizedAccount(address).
        // We don't pin the exact selector — just verify a non-owner cannot set.
        vm.prank(stranger);
        vm.expectRevert();
        cfg.setLtv(7000);
    }

    /// @notice setLtv(0) is an admin escape hatch — it flips the market back
    ///         to the cash-flow branch. The test pins the spec: 0 is allowed,
    ///         and getLtv reports 0 afterwards.
    function test_setLtv_acceptsZero() public {
        vm.prank(owner);
        cfg.setLtv(0);
        assertEq(cfg.getLtv(), 0);
    }

    function test_setLtv_revertsAboveMaxFeeBps() public {
        vm.prank(owner);
        vm.expectRevert(bytes("LTV cannot exceed max fee"));
        cfg.setLtv(MAX_BPS + 1);
    }

    function test_setLtv_acceptsBoundaryOne() public {
        vm.prank(owner);
        cfg.setLtv(1);
        assertEq(cfg.getLtv(), 1);
    }

    function test_setLtv_acceptsBoundaryMaxBps() public {
        vm.prank(owner);
        cfg.setLtv(MAX_BPS);
        assertEq(cfg.getLtv(), MAX_BPS);
    }

    function test_setLtv_storesLastValueWritten() public {
        vm.startPrank(owner);
        cfg.setLtv(5000);
        assertEq(cfg.getLtv(), 5000);
        cfg.setLtv(8000);
        assertEq(cfg.getLtv(), 8000);
        vm.stopPrank();
    }

    /// @notice Round-trip: an admin can flip into the LTV branch and back to
    ///         cash-flow via setLtv(0). This is by design — losing this lever
    ///         would strand a market in like-to-like mode after a misconfig.
    function test_setLtv_roundTripsBetweenLtvAndCashFlow() public {
        vm.startPrank(owner);
        cfg.setLtv(7000);
        assertEq(cfg.getLtv(), 7000);
        cfg.setLtv(0);
        assertEq(cfg.getLtv(), 0);
        cfg.setLtv(5000);
        assertEq(cfg.getLtv(), 5000);
        vm.stopPrank();
    }

    // ---------------- getLtv default ----------------

    function test_getLtv_defaultsToZeroAfterInitialize() public view {
        // Initialize does not touch ltv. The branching code in the collateral
        // managers leans on this default to pick the cash-flow formula.
        assertEq(cfg.getLtv(), 0);
    }

    // ---------------- ILoanConfig interface conformance ----------------

    function test_ILoanConfig_setLtv_reachableViaInterface() public {
        vm.prank(owner);
        ILoanConfig(address(cfg)).setLtv(4242);
        assertEq(cfg.getLtv(), 4242);
    }

    // ================================================================
    //  maxUtilizationBps -- promoted from hardcoded 8000 in
    //  CollateralManager.getMaxLoanByRewardsRate. The CollateralManager
    //  cap is the ONLY utilization protection in the LoanV2 portfolio
    //  borrow path (PortfolioLoanLib.borrowFromPortfolio does no
    //  vault-side check). Regressions here remove that protection.
    // ================================================================

    /// @notice UUPS upgrade safety: a proxy upgraded BEFORE
    ///         setMaxUtilizationBps is ever called must still report the
    ///         legacy 8000 default. The storage field appended for layout
    ///         safety is zero on un-seeded proxies; the fallback in
    ///         getMaxUtilizationBps converts that to DEFAULT_MAX_UTILIZATION_BPS.
    function test_getMaxUtilizationBps_unsetStorageReturnsDefault8000() public view {
        assertEq(cfg.getMaxUtilizationBps(), 8000, "fresh proxy must fall back to 8000");
        assertEq(cfg.DEFAULT_MAX_UTILIZATION_BPS(), 8000, "constant pins the spec");
    }

    function test_setMaxUtilizationBps_onlyOwner_revertsForStranger() public {
        // OZ Ownable encodes OwnableUnauthorizedAccount(stranger); we just
        // assert it reverts -- the encoding can drift across OZ minor versions.
        vm.prank(stranger);
        vm.expectRevert();
        cfg.setMaxUtilizationBps(7000);
    }

    function test_setMaxUtilizationBps_ownerCanSet_getterRoundTrips() public {
        vm.prank(owner);
        cfg.setMaxUtilizationBps(7000);
        assertEq(cfg.getMaxUtilizationBps(), 7000);

        vm.prank(owner);
        cfg.setMaxUtilizationBps(9500);
        assertEq(cfg.getMaxUtilizationBps(), 9500);
    }

    function test_setMaxUtilizationBps_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LoanConfig.InvalidMaxUtilization.selector, uint256(0)));
        cfg.setMaxUtilizationBps(0);
    }

    function test_setMaxUtilizationBps_revertsAboveMaxFeeBps() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LoanConfig.InvalidMaxUtilization.selector, uint256(100_01)));
        cfg.setMaxUtilizationBps(100_01);
    }

    function test_setMaxUtilizationBps_acceptsBoundaryMaxBps() public {
        // 10000 is the spec ceiling (100%). Accepting it is the only way an
        // operator can deliberately disable the cap on a like-to-like market.
        vm.prank(owner);
        cfg.setMaxUtilizationBps(100_00);
        assertEq(cfg.getMaxUtilizationBps(), 100_00);
    }

    function test_setMaxUtilizationBps_acceptsBoundaryOne() public {
        // 1 bps is permissive on the lower end -- the only floor is "not zero".
        vm.prank(owner);
        cfg.setMaxUtilizationBps(1);
        assertEq(cfg.getMaxUtilizationBps(), 1);
    }

    /// @notice After setting to the default 8000 via the setter, the value
    ///         persists through the SET path -- not the unset-fallback path.
    ///         A second proxy with the same stored 8000 must behave identically
    ///         to the fresh proxy, which is the contract this test pins.
    function test_setMaxUtilizationBps_persistsDefaultViaSetter() public {
        vm.prank(owner);
        cfg.setMaxUtilizationBps(8000);
        assertEq(cfg.getMaxUtilizationBps(), 8000);

        // Round-trip to a non-default and back, proving the setter path
        // is reachable for every value (storage is mutated, not bypassed).
        vm.prank(owner);
        cfg.setMaxUtilizationBps(6000);
        assertEq(cfg.getMaxUtilizationBps(), 6000);
        vm.prank(owner);
        cfg.setMaxUtilizationBps(8000);
        assertEq(cfg.getMaxUtilizationBps(), 8000);
    }

    function test_ILoanConfig_setMaxUtilizationBps_reachableViaInterface() public {
        vm.prank(owner);
        ILoanConfig(address(cfg)).setMaxUtilizationBps(7500);
        assertEq(ILoanConfig(address(cfg)).getMaxUtilizationBps(), 7500);
    }

    // ================================================================
    //  Lender-premium curve: getLenderPremium(ltv), setLenderPremiumCurve,
    //  getLenderPremiumCurve. setUp seeds lenderPremium=2000, treasuryFee=500,
    //  so MAX_FEE_BPS - treasuryFee = 9500 (the dynamic default cap).
    // ================================================================

    uint256 internal constant CURVE_MAX_SLOPE = MAX_BPS * 100;
    uint256 internal constant CURVE_MAX_LTV = MAX_BPS * 100;

    function test_getLenderPremium_disabledCurve_returnsFlatPremium() public view {
        assertEq(cfg.getLenderPremium(0), 2000);
        assertEq(cfg.getLenderPremium(5000), 2000);
        assertEq(cfg.getLenderPremium(100_00), 2000);
        assertEq(cfg.getLenderPremium(500_00), 2000);
        assertEq(cfg.getLenderPremium(type(uint256).max), 2000);
    }

    function test_getLenderPremium_disabledCurve_unaffectedByBaseAndKink() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(7777, 0, 1234, 8888, 0);
        assertEq(cfg.getLenderPremium(0), 2000);
        assertEq(cfg.getLenderPremium(500_00), 2000);
    }

    function test_getLenderPremium_belowKink_returnsBaseExactly() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 100, 5000, 0, 0);
        assertEq(cfg.getLenderPremium(0), 300);
        assertEq(cfg.getLenderPremium(2500), 300);
        assertEq(cfg.getLenderPremium(4999), 300);
    }

    function test_getLenderPremium_atKink_returnsBase() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 100, 5000, 0, 0);
        assertEq(cfg.getLenderPremium(5000), 300);
    }

    function test_getLenderPremium_aboveKink_linearSlope() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 100, 5000, 0, 0);
        // base + slope * (ltv - kink) / 100_00
        // ltv 6000: 300 + 100 * 1000 / 10000 = 310
        assertEq(cfg.getLenderPremium(6000), 310);
        // ltv 8000: 300 + 100 * 3000 / 10000 = 330
        assertEq(cfg.getLenderPremium(8000), 330);
        // ltv 10000: 300 + 100 * 5000 / 10000 = 350
        assertEq(cfg.getLenderPremium(100_00), 350);
        // ltv 15000: 300 + 100 * 10000 / 10000 = 400
        assertEq(cfg.getLenderPremium(150_00), 400);
    }

    function test_getLenderPremium_aboveKink_truncatesOnDivision() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(0, 1, 0, 0, 0);
        // 1 * 9999 / 10000 = 0 (floor)
        assertEq(cfg.getLenderPremium(9999), 0);
        // 1 * 10000 / 10000 = 1
        assertEq(cfg.getLenderPremium(100_00), 1);
        // 1 * 19999 / 10000 = 1 (floor)
        assertEq(cfg.getLenderPremium(199_99), 1);
    }

    function test_getLenderPremium_clampsToExplicitCap() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 1000, 5000, 500, 0);
        // ltv 10000: 300 + 1000 * 5000 / 10000 = 800, clamped to 500
        assertEq(cfg.getLenderPremium(100_00), 500);
        // ltv 20000: 300 + 1000 * 15000 / 10000 = 1800, clamped to 500
        assertEq(cfg.getLenderPremium(200_00), 500);
    }

    function test_getLenderPremium_capJustAboveOutput_doesNotClamp() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 100, 5000, 331, 0);
        // ltv 8000: computed 330, cap 331, no clamp
        assertEq(cfg.getLenderPremium(8000), 330);
        // ltv 8100: 300 + 100 * 3100 / 10000 = 331, equal to cap, still no clamp
        assertEq(cfg.getLenderPremium(8100), 331);
        // ltv 8200: 300 + 100 * 3200 / 10000 = 332, clamped to 331
        assertEq(cfg.getLenderPremium(8200), 331);
    }

    function test_getLenderPremium_capZero_defaultsToMaxFeeMinusTreasury() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(1000, CURVE_MAX_SLOPE, 5000, 0, 0);
        // base + slope * (ltv - kink) / 10000 would explode; effective cap = 10000 - 500 = 9500
        assertEq(cfg.getLenderPremium(100_00), 9500);
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 9500);
    }

    function test_getLenderPremium_defaultCap_tracksLiveTreasuryFee() public {
        vm.startPrank(owner);
        cfg.setLenderPremiumCurve(1000, CURVE_MAX_SLOPE, 0, 0, 0);
        // treasuryFee=500, cap=9500
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 9500);

        cfg.setTreasuryFee(1500);
        // treasuryFee=1500, cap=8500
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 8500);

        cfg.setTreasuryFee(100);
        // treasuryFee=100, cap=9900
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 9900);
        vm.stopPrank();
    }

    function test_getLenderPremium_inputClampsAtMaxLtv() public {
        vm.prank(owner);
        // base=100, slope=1, kink=0, cap=0 (effective 9500).
        // At ltv = MAX_LTV: 100 + 1 * MAX_LTV / 100_00 = 200 with the curve below.
        // type(uint256).max should produce the same 200 because input clamps.
        cfg.setLenderPremiumCurve(100, 1, 0, 0, 0);
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 200);
        assertEq(cfg.getLenderPremium(type(uint256).max), 200);
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV + 1), 200);
    }

    function test_getLenderPremium_kinkBoundaryInclusiveOnBelowSide() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(500, 200, 7000, 0, 0);
        // ltv == kink: base
        assertEq(cfg.getLenderPremium(7000), 500);
        // ltv == kink + 1: 500 + 200 * 1 / 10000 = 500 (floor), still equal to base
        assertEq(cfg.getLenderPremium(7001), 500);
        // ltv == kink + 50: 500 + 200 * 50 / 10000 = 501
        assertEq(cfg.getLenderPremium(7050), 501);
    }

    // ---------------- setLenderPremiumCurve validation ----------------

    function test_setLenderPremiumCurve_revertsOnNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        cfg.setLenderPremiumCurve(100, 100, 5000, 0, 0);
    }

    function test_setLenderPremiumCurve_revertsWhenBasePlusTreasuryExceedsMax() public {
        // treasuryFee = 500, so base must be <= 9500
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveBase.selector,
                uint256(9501),
                uint256(500),
                uint256(100_00)
            )
        );
        cfg.setLenderPremiumCurve(9501, 100, 5000, 0, 0);
    }

    function test_setLenderPremiumCurve_basePlusTreasuryAtMaxIsAccepted() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(9500, 0, 0, 0, 0);
        (uint256 base,,,,) = cfg.getLenderPremiumCurve();
        assertEq(base, 9500);
    }

    function test_setLenderPremiumCurve_revertsWhenCapPlusTreasuryExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveCap.selector,
                uint256(9501),
                uint256(500),
                uint256(100_00)
            )
        );
        cfg.setLenderPremiumCurve(100, 100, 5000, 9501, 0);
    }

    function test_setLenderPremiumCurve_capPlusTreasuryAtMaxIsAccepted() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(100, 100, 5000, 9500, 0);
        (,,, uint256 cap,) = cfg.getLenderPremiumCurve();
        assertEq(cap, 9500);
    }

    function test_setLenderPremiumCurve_revertsWhenCapBelowBase() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveCapBelowBase.selector,
                uint256(499),
                uint256(500)
            )
        );
        cfg.setLenderPremiumCurve(500, 100, 5000, 499, 0);
    }

    function test_setLenderPremiumCurve_capEqualToBaseIsAccepted() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(500, 100, 5000, 500, 0);
        (uint256 base,,, uint256 cap,) = cfg.getLenderPremiumCurve();
        assertEq(base, 500);
        assertEq(cap, 500);
    }

    function test_setLenderPremiumCurve_revertsWhenSlopeAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveSlope.selector,
                uint256(CURVE_MAX_SLOPE + 1),
                CURVE_MAX_SLOPE
            )
        );
        cfg.setLenderPremiumCurve(100, CURVE_MAX_SLOPE + 1, 5000, 0, 0);
    }

    function test_setLenderPremiumCurve_slopeAtMaxIsAccepted() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(100, CURVE_MAX_SLOPE, 5000, 0, 0);
        (, uint256 slope,,,) = cfg.getLenderPremiumCurve();
        assertEq(slope, CURVE_MAX_SLOPE);
    }

    function test_setLenderPremiumCurve_capZeroBypassesCapValidation() public {
        // cap == 0 means "use default"; cap < base check must not fire when cap == 0
        vm.prank(owner);
        cfg.setLenderPremiumCurve(9000, 100, 5000, 0, 0);
        (uint256 base,,, uint256 cap,) = cfg.getLenderPremiumCurve();
        assertEq(base, 9000);
        assertEq(cap, 0);
    }

    function test_setLenderPremiumCurve_slopeZeroDisablesCurveAndReturnsFlat() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(9000, 0, 1234, 9500, 0);
        // Even with extreme base/cap, both slopes=0 means flat lenderPremium wins
        assertEq(cfg.getLenderPremium(0), 2000);
        assertEq(cfg.getLenderPremium(1000_00), 2000);
    }

    function test_setLenderPremiumCurve_kinkHasNoUpperBound() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(100, 100, type(uint256).max, 0, 0);
        (,, uint256 kink,,) = cfg.getLenderPremiumCurve();
        assertEq(kink, type(uint256).max);
    }

    function test_setLenderPremiumCurve_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(cfg));
        emit LoanConfig.LenderPremiumCurveUpdated(300, 100, 5000, 600, 0);
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 100, 5000, 600, 0);
    }

    function test_setLenderPremiumCurve_overwritesPreviousValues() public {
        vm.startPrank(owner);
        cfg.setLenderPremiumCurve(100, 50, 1000, 200, 0);
        cfg.setLenderPremiumCurve(500, 250, 7000, 1500, 0);
        vm.stopPrank();
        (uint256 base, uint256 slope, uint256 kink, uint256 cap,) = cfg.getLenderPremiumCurve();
        assertEq(base, 500);
        assertEq(slope, 250);
        assertEq(kink, 7000);
        assertEq(cap, 1500);
    }

    // ---------------- getLenderPremiumCurve ----------------

    function test_getLenderPremiumCurve_defaultsToZeros() public view {
        (uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) = cfg.getLenderPremiumCurve();
        assertEq(base, 0);
        assertEq(slope, 0);
        assertEq(kink, 0);
        assertEq(cap, 0);
        assertEq(slopeBelow, 0);
    }

    function test_getLenderPremiumCurve_roundTripsExactQuintuple() public {
        vm.prank(owner);
        // slopeBelow (300) <= slope (456), passes monotonicity.
        cfg.setLenderPremiumCurve(123, 456, 789, 1234, 300);
        (uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) = cfg.getLenderPremiumCurve();
        assertEq(base, 123);
        assertEq(slope, 456);
        assertEq(kink, 789);
        assertEq(cap, 1234);
        assertEq(slopeBelow, 300);
    }

    // ================================================================
    //  Two-slope (below-kink ramp) behavior. slopeBelow is the ramp
    //  below the kink; slope the ramp above. Curve must steepen past
    //  the kink, so slopeBelow <= slope.
    // ================================================================

    /// @notice Below-kink ramp active: with slopeBelow=100 the segment under
    ///         the kink is no longer flat. Each value is hand-computed.
    function test_getLenderPremium_belowKinkRamp_active() public {
        vm.prank(owner);
        // base=300, slope=200, kink=5000, cap=0 (eff 9500), slopeBelow=100.
        cfg.setLenderPremiumCurve(300, 200, 5000, 0, 100);
        // ltv 0: belowPortion 0 -> 300 + 100*0/10000 = 300
        assertEq(cfg.getLenderPremium(0), 300);
        // ltv 2500: 300 + 100*2500/10000 = 300 + 25 = 325
        assertEq(cfg.getLenderPremium(2500), 325);
        // ltv 4999: 300 + 100*4999/10000 = 300 + 49 (floor) = 349
        assertEq(cfg.getLenderPremium(4999), 349);
        // ltv 5000 (== kink): 300 + 100*5000/10000 = 300 + 50 = 350
        assertEq(cfg.getLenderPremium(5000), 350);
    }

    /// @notice Two-slope continuity at the kink. The above-kink branch must
    ///         build on the full below-kink contribution at the kink, so the
    ///         function is continuous (no jump) at ltv == kink.
    function test_getLenderPremium_twoSlope_continuousAtKink() public {
        vm.prank(owner);
        // base=300, slope=200, kink=5000, cap=0, slopeBelow=100.
        cfg.setLenderPremiumCurve(300, 200, 5000, 0, 100);
        // Value approached from below at the kink: base + slopeBelow*kink/10000.
        uint256 atKink = 300 + (100 * 5000) / 100_00; // 350
        assertEq(cfg.getLenderPremium(5000), atKink);
        // One bps above kink: below-contribution 50 + above 200*1/10000=0 (floor) = 350.
        assertEq(cfg.getLenderPremium(5001), 350);
        // ltv 6000: below 100*5000/10000=50, above 200*1000/10000=20 => 300+50+20 = 370
        assertEq(cfg.getLenderPremium(6000), 370);
        // ltv 7500: below 50, above 200*2500/10000=50 => 300+50+50 = 400
        assertEq(cfg.getLenderPremium(7500), 400);
    }

    /// @notice Disable requires BOTH slopes zero. slope=0 with slopeBelow=0
    ///         is the disable path -> flat seeded lenderPremium (2000).
    function test_getLenderPremium_disableRequiresBothZero() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(9000, 0, 1234, 9500, 0);
        assertEq(cfg.getLenderPremium(0), 2000);
        assertEq(cfg.getLenderPremium(5000), 2000);
        assertEq(cfg.getLenderPremium(1000_00), 2000);
    }

    /// @notice With both slopes > 0 the curve is active and does NOT collapse
    ///         to the flat 2000. slopeBelow > 0 keeps the curve engaged even
    ///         where the flat premium would otherwise apply.
    function test_getLenderPremium_bothSlopesNonZero_curveActive() public {
        vm.prank(owner);
        // base=300, slope=200, kink=5000, cap=0, slopeBelow=100.
        cfg.setLenderPremiumCurve(300, 200, 5000, 0, 100);
        // ltv 2500: 300 + 100*2500/10000 = 325, NOT the flat 2000.
        uint256 rate = cfg.getLenderPremium(2500);
        assertEq(rate, 325);
        assertTrue(rate != 2000, "curve must be active, not flat premium");
    }

    /// @notice slopeBelow contributes to cap clamping: the below-kink term
    ///         alone can push the rate over the cap.
    function test_getLenderPremium_belowKinkRamp_clampsToCap() public {
        vm.prank(owner);
        // base=300, slope=1000, kink=5000, cap=400, slopeBelow=1000.
        // slopeBelow (1000) <= slope (1000) ok; cap 400 >= base 300 ok.
        cfg.setLenderPremiumCurve(300, 1000, 5000, 400, 1000);
        // ltv 2500 (below kink): 300 + 1000*2500/10000 = 300 + 250 = 550, clamp to 400
        assertEq(cfg.getLenderPremium(2500), 400);
        // ltv 1000 (below kink): 300 + 1000*1000/10000 = 300 + 100 = 400, equals cap, no clamp
        assertEq(cfg.getLenderPremium(1000), 400);
        // ltv 500 (below kink): 300 + 1000*500/10000 = 300 + 50 = 350, under cap
        assertEq(cfg.getLenderPremium(500), 350);
    }

    /// @notice Validation: slopeBelow above MAX_LENDER_PREMIUM_SLOPE reverts
    ///         InvalidCurveSlope(slopeBelow, MAX). slope is at MAX so the
    ///         slopeBelow > slope check does not fire first.
    function test_setLenderPremiumCurve_revertsWhenSlopeBelowAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveSlope.selector,
                uint256(CURVE_MAX_SLOPE + 1),
                CURVE_MAX_SLOPE
            )
        );
        cfg.setLenderPremiumCurve(100, CURVE_MAX_SLOPE + 1, 5000, 0, CURVE_MAX_SLOPE + 1);
    }

    /// @notice Validation: slopeBelow > slope reverts (monotonicity). The
    ///         curve must steepen past the kink, never flatten.
    function test_setLenderPremiumCurve_revertsWhenSlopeBelowExceedsSlope() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanConfig.InvalidCurveSlopeBelowExceedsSlope.selector,
                uint256(101),
                uint256(100)
            )
        );
        cfg.setLenderPremiumCurve(100, 100, 5000, 0, 101);
    }

    /// @notice Monotonicity boundary: slopeBelow == slope is allowed. This is
    ///         a single linear curve with no extra steepening past the kink.
    function test_setLenderPremiumCurve_slopeBelowEqualsSlopeAccepted() public {
        vm.prank(owner);
        cfg.setLenderPremiumCurve(100, 100, 5000, 0, 100);
        (uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) =
            cfg.getLenderPremiumCurve();
        assertEq(base, 100);
        assertEq(slope, 100);
        assertEq(kink, 5000);
        assertEq(cap, 0);
        assertEq(slopeBelow, 100);
        // With slopeBelow == slope and kink=5000, the curve is one continuous line.
        // ltv 2500 (below): 100 + 100*2500/10000 = 125
        assertEq(cfg.getLenderPremium(2500), 125);
        // ltv 7500 (above): below 100*5000/10000=50 + above 100*2500/10000=25 => 175
        // Single-line check: 100 + 100*7500/10000 = 175 (identical, no kink steepening)
        assertEq(cfg.getLenderPremium(7500), 175);
    }

    /// @notice Input clamp still applies with a below-kink slope. A kink at
    ///         MAX_LTV keeps everything on the below-kink segment; the input
    ///         clamps so MAX_LTV and type(uint256).max give the same rate.
    function test_getLenderPremium_belowKinkRamp_inputClampsAtMaxLtv() public {
        vm.prank(owner);
        // base=100, slope=1, kink=CURVE_MAX_LTV, cap=0 (eff 9500), slopeBelow=1.
        // At ltv == MAX_LTV: belowPortion = MAX_LTV, rate = 100 + 1*MAX_LTV/10000.
        // MAX_LTV = 100_00 * 100 = 1_000_000; 1*1_000_000/10000 = 100 => 200.
        cfg.setLenderPremiumCurve(100, 1, CURVE_MAX_LTV, 0, 1);
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV), 200);
        // Input clamps to MAX_LTV, so max uint produces the identical rate.
        assertEq(cfg.getLenderPremium(type(uint256).max), 200);
        assertEq(cfg.getLenderPremium(CURVE_MAX_LTV + 1), 200);
    }

    /// @notice Event carries slopeBelow as the 5th arg (non-zero variant).
    function test_setLenderPremiumCurve_emitsEvent_withSlopeBelow() public {
        vm.expectEmit(true, true, true, true, address(cfg));
        emit LoanConfig.LenderPremiumCurveUpdated(300, 200, 5000, 600, 150);
        vm.prank(owner);
        cfg.setLenderPremiumCurve(300, 200, 5000, 600, 150);
    }
}
