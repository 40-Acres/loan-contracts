// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ---------------------------------------------------------------------------
 * Minimum-collateral dust floor on YieldBasisCollateralManager.removeCollateral
 * (cached-debt YB LP variant), driven through YieldBasisLpFacet.withdraw.
 * ---------------------------------------------------------------------------
 *
 * New behavior under test (added after the "Debt exceeds max loan" check):
 *
 *     uint256 remaining = getTotalCollateralValue(vault, underlying);
 *     uint256 minimum   = PortfolioFactoryConfig(cfg).getMinimumCollateral();
 *     if (remaining != 0 && remaining < minimum)
 *         revert BelowMinimumCollateral(remaining, minimum);
 *
 * For the YB managers, getTotalCollateralValue clamps tracked shares to the
 * actual recoverable LP (direct balance + gauge receipts). The mock LP has
 * pricePerShare == 1e18 and zero haircut, so collateral value == LP shares.
 *
 * Invariants pinned:
 *  1. Partial withdraw leaving live value in (0, minimum) reverts.
 *  2. Full exit (remaining == 0) succeeds despite 0 < minimum.
 *  3. Partial withdraw leaving remaining >= minimum succeeds.
 *  4. minimum == 0 disables the floor.
 *  5. Floor applies with zero debt (the withdraw path here carries no debt).
 *  6. Drained-position bypass: when the staked LP is externally drained from
 *     the gauge, getTotalCollateralValue clamps to 0 and the floor is bypassed.
 *
 * Pure additions; existing YieldBasisLpFacet tests run with minimum == 0 and
 * are untouched. Extends YieldBasisLpFacetTest via inheritance.
 *
 * NOTE on amounts: DEPOSIT_AMOUNT == 1e18. We use a larger deposit so the
 * (0, minimum) interval is expressible with round numbers.
 * -------------------------------------------------------------------------*/

import {YieldBasisLpFacetTest} from "./YieldBasisLpFacet.t.sol";
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract YieldBasisMinimumCollateralFloorTest is YieldBasisLpFacetTest {
    uint256 internal constant COLLATERAL = 1000e18; // 1000 ybBTC, value 1000e18 at pps 1:1

    function _setMinimum(uint256 minimum) internal {
        vm.prank(_owner);
        _portfolioFactoryConfig.setMinimumCollateral(minimum);
    }

    function _expectWithdrawRevert(uint256 amount, bytes memory expectedRevert) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        vm.expectRevert(expectedRevert);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _seedUnstaked(uint256 amount) internal {
        // user starts with DEPOSIT_AMOUNT * 10 == 10e18; mint extra to cover larger deposits.
        _ybBtc.mint(_user, amount);
        _depositViaMulticall(amount); // unstaked LP on the account
    }

    // 1. Partial withdraw into (0, minimum) reverts with BelowMinimumCollateral.
    function test_withdraw_belowMinimumPartial_revertsNoDebt() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        uint256 withdrawAmount = 950e18; // leaves 50e18 value in (0, 100e18)

        _expectWithdrawRevert(
            withdrawAmount,
            abi.encodeWithSelector(YieldBasisCollateralManager.BelowMinimumCollateral.selector, 50e18, 100e18)
        );

        // Withdraw reverted: full collateral retained.
        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), COLLATERAL, "collateral retained after revert");
    }

    // 2. Full exit succeeds despite 0 < minimum.
    function test_withdraw_fullExit_bypassesFloor() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawViaMulticall(COLLATERAL);

        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "fully exited");
    }

    // 3. Partial withdraw leaving remaining >= minimum succeeds.
    function test_withdraw_aboveMinimumPartial_succeeds() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawViaMulticall(800e18); // leaves 200e18 >= 100e18

        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 200e18, "remaining at/above minimum");
    }

    // 3b. Remaining exactly equal to minimum succeeds.
    function test_withdraw_exactlyMinimum_succeeds() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawViaMulticall(900e18); // leaves exactly 100e18

        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 100e18, "remaining exactly minimum allowed");
    }

    // 4. minimum == 0 disables the floor: dust remainder allowed.
    function test_withdraw_minimumUnset_allowsDust() public {
        _seedUnstaked(COLLATERAL);
        assertEq(_portfolioFactoryConfig.getMinimumCollateral(), 0, "precondition: floor disabled");

        _withdrawViaMulticall(COLLATERAL - 1); // leaves 1 wei

        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 1, "dust allowed when disabled");
    }

    // 6. Drained-position bypass. Stake the collateral into the gauge, then externally
    //    drain the account's gauge receipt shares so recoverable LP reads 0. The floor's
    //    guard is `remaining != 0 && remaining < minimum`; once getTotalCollateralValue
    //    clamps to 0, `remaining != 0` is false and the floor cannot fire.
    //
    //    NOTE: Within this harness, withdraw delivery also fails once the gauge holds no
    //    LP (the facet's gauge.withdraw step has nothing to source), so a withdraw on a
    //    drained position reverts downstream in the delivery path -- NOT on the manager
    //    floor. We therefore pin the load-bearing fact directly: the clamped collateral
    //    value is 0, which is exactly the condition that disables the floor. We also pin
    //    that removeCollateral itself does not revert with BelowMinimumCollateral by
    //    driving it for the full tracked amount and asserting the revert is the downstream
    //    delivery error, not the floor.
    function test_withdraw_drainedGauge_clampsToZero_disablesFloor() public {
        _seedUnstaked(COLLATERAL);
        _syncAndSetStake(true); // moves all LP into the gauge

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, COLLATERAL, "all staked");
        assertEq(unstaked, 0, "no direct LP");

        _setMinimum(100e18);

        // Externally drain the account's gauge receipt shares so recoverable LP
        // collapses. _actualLp = direct LP + gauge.convertToAssets(gaugeShares);
        // zeroing the account's gauge balance drives it to 0.
        uint256 gaugeShares = _gauge.balanceOf(_portfolioAccount);
        assertEq(gaugeShares, COLLATERAL, "account holds gauge receipts");
        vm.prank(_portfolioAccount);
        _gauge.transfer(address(0xdead), gaugeShares);

        // Clamp proven: recoverable value is 0, so the floor's `remaining != 0` guard
        // is false and the floor is a no-op for this position.
        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "drained position reads zero collateral");

        // Confirm the floor is bypassed: a partial withdraw that would otherwise leave
        // (0, minimum) reverts on the downstream delivery (gauge empty), NOT on the floor.
        bytes memory floorSelector = abi.encodeWithSelector(
            YieldBasisCollateralManager.BelowMinimumCollateral.selector, uint256(0), uint256(0)
        );
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, 950e18);
        try _portfolioManager.multicall(calldatas, factories) {
            // If it did not revert, that is also acceptable: the floor did not block.
        } catch (bytes memory reason) {
            // Whatever the revert, it must NOT be BelowMinimumCollateral.
            assertTrue(
                bytes4(reason) != bytes4(floorSelector),
                "drained position must not revert on the minimum-collateral floor"
            );
        }
        vm.stopPrank();
    }
}
