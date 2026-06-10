// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * LiveAerodromeLoanConfigCurve.t.sol -- fork validation for the Aerodrome
 *   LoanConfig UUPS upgrade that introduces the two-slope lender-premium curve.
 *
 * Standalone: pokes only the live LoanConfig proxy. No portfolio account,
 * no LiveDeploymentSetup. Upgrade is atomic via upgradeToAndCall.
 *
 * Run:
 *   make test-fork ARGS="--match-path \
 *     test/fork/portfolio_account/live/LiveAerodromeLoanConfigCurve.t.sol -vv"
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LoanConfig} from "src/facets/account/config/LoanConfig.sol";

contract LiveAerodromeLoanConfigCurve is Test {
    // Live Aerodrome prod LoanConfig proxy on Base (chain 8453).
    address constant PROXY = 0xa5b8bC2C39c669132930AdFD3e56E988e5629C88;
    // Proxy owner Safe multisig.
    address constant OWNER_SAFE = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Upgrade args: setLenderPremiumCurve(base, slope, kink, cap, slopeBelow).
    uint256 constant BASE = 1500;
    uint256 constant SLOPE = 1500;
    uint256 constant KINK = 15000;
    uint256 constant CAP = 4500;
    uint256 constant SLOPE_BELOW = 500;

    LoanConfig config;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        config = LoanConfig(PROXY);
    }

    // Deploy a fresh impl and atomically apply the curve under the Safe.
    function _upgrade() internal {
        LoanConfig newImpl = new LoanConfig();
        bytes memory data = abi.encodeCall(
            LoanConfig.setLenderPremiumCurve, (BASE, SLOPE, KINK, CAP, SLOPE_BELOW)
        );
        vm.prank(OWNER_SAFE);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), data);
    }

    // The curve getter must not exist on the live impl before the upgrade.
    function test_PreUpgrade_CurveAbsent() public {
        (bool ok,) = PROXY.staticcall(abi.encodeWithSignature("getLenderPremiumCurve()"));
        assertFalse(ok, "curve should not exist pre-upgrade");
    }

    // storage.LoanConfig base slot; ltv is the 6th field (index 5).
    bytes32 constant LOAN_CONFIG_BASE_SLOT =
        0x56934078f186da11d4c9a63b9f80cffd0995a6f4faf49b2f387b460b80ba0528;
    bytes32 constant LTV_SLOT =
        bytes32(uint256(LOAN_CONFIG_BASE_SLOT) + 5);

    // Append-only storage guard: pre-existing fields survive the upgrade.
    // The live impl predates the getLtv() getter, so ltv is read from its
    // raw storage slot pre-upgrade and compared to the getter post-upgrade.
    function test_PreExistingFields_SurviveUpgrade() public {
        (bool okFee, bytes memory feeData) =
            PROXY.staticcall(abi.encodeWithSignature("getTreasuryFee()"));
        assertTrue(okFee, "getTreasuryFee should exist pre-upgrade");
        uint256 treasuryBefore = abi.decode(feeData, (uint256));
        assertEq(treasuryBefore, 500, "treasuryFee should be 500 pre-upgrade");

        uint256 ltvBefore = uint256(vm.load(PROXY, LTV_SLOT));

        _upgrade();

        assertEq(config.getTreasuryFee(), 500, "treasuryFee changed across upgrade");
        assertEq(config.getLtv(), ltvBefore, "ltv changed across upgrade");
    }

    // Curve params are stored exactly as supplied.
    function test_PostUpgrade_CurveParamsSet() public {
        _upgrade();
        (uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) =
            config.getLenderPremiumCurve();
        assertEq(base, 1500, "base");
        assertEq(slope, 1500, "slope");
        assertEq(kink, 15000, "kink");
        assertEq(cap, 4500, "cap");
        assertEq(slopeBelow, 500, "slopeBelow");
    }

    // Hand-computed checkpoints across the piecewise-linear curve.
    function test_GetLenderPremium_Checkpoints() public {
        _upgrade();
        assertEq(config.getLenderPremium(0), 1500, "ltv 0");
        assertEq(config.getLenderPremium(5000), 1750, "ltv 5000");
        assertEq(config.getLenderPremium(10000), 2000, "ltv 10000");
        assertEq(config.getLenderPremium(15000), 2250, "ltv 15000 kink");
        assertEq(config.getLenderPremium(20000), 3000, "ltv 20000");
        assertEq(config.getLenderPremium(25000), 3750, "ltv 25000");
        assertEq(config.getLenderPremium(30000), 4500, "ltv 30000 cap");
    }

    // Output clamps to cap; oversized input clamps to MAX first.
    function test_GetLenderPremium_CapClamps() public {
        _upgrade();
        assertEq(config.getLenderPremium(50000), 4500, "ltv 50000 clamps to cap");
        assertEq(config.getLenderPremium(2_000_000), 4500, "huge ltv clamps to cap");
        assertLe(config.getLenderPremium(2_000_000), 4500, "never exceeds cap");
    }

    // Monotonic nondecreasing, and steeper above the kink than below.
    function test_Curve_MonotonicAndSteeperAboveKink() public {
        _upgrade();
        uint256[8] memory sweep = [
            uint256(0), 5000, 10000, 15000, 20000, 25000, 30000, 40000
        ];
        uint256 prev = config.getLenderPremium(sweep[0]);
        for (uint256 i = 1; i < sweep.length; i++) {
            uint256 cur = config.getLenderPremium(sweep[i]);
            assertGe(cur, prev, "curve must be nondecreasing");
            prev = cur;
        }

        uint256 belowStep =
            config.getLenderPremium(10000) - config.getLenderPremium(5000);
        uint256 aboveStep =
            config.getLenderPremium(20000) - config.getLenderPremium(15000);
        assertEq(belowStep, 250, "below-kink step width 5000");
        assertEq(aboveStep, 750, "above-kink step width 5000");
        assertGt(aboveStep, belowStep, "above-kink ramp must be steeper");
    }

    // Max combined lender premium plus protocol treasury fee is 50%.
    function test_CombinedCeiling() public {
        _upgrade();
        (,,, uint256 cap,) = config.getLenderPremiumCurve();
        uint256 treasuryFee = config.getTreasuryFee();
        assertEq(cap + treasuryFee, 5000, "combined ceiling must be 5000 bps");
    }
}
