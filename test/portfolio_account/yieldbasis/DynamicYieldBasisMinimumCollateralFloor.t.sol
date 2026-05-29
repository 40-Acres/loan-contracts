// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ---------------------------------------------------------------------------
 * Minimum-collateral dust floor on
 * DynamicYieldBasisCollateralManager.removeCollateral (live-debt YB LP variant),
 * driven through DynamicYieldBasisLpFacet.withdraw.
 * ---------------------------------------------------------------------------
 *
 * Same floor as the cached-debt variant, on a distinct storage slot / manager.
 * MockTunableYieldBasisLP defaults to pps == 1e18 and zero haircut, so
 * collateral value == LP shares. getTotalCollateralValue clamps tracked shares
 * to actual recoverable LP (direct + gauge receipts).
 *
 * Invariants pinned:
 *  1. Partial withdraw leaving live value in (0, minimum) reverts.
 *  2. Full exit (remaining == 0) succeeds despite 0 < minimum.
 *  3. Partial withdraw leaving remaining >= minimum succeeds.
 *  4. minimum == 0 disables the floor.
 *  5. Floor applies with zero debt.
 *  6. Drained-gauge bypass: clamped recoverable value of 0 bypasses the floor.
 *
 * Pure additions; extends DynamicYieldBasisLpFacetTest via inheritance. The
 * inherited harness builds its diamond in its own setUp(); we add a deposit
 * helper that seeds the larger collateral amounts these tests need.
 * -------------------------------------------------------------------------*/

import {DynamicYieldBasisLpFacetTest} from "./DynamicYieldBasisLpFacet.t.sol";
import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract DynamicYieldBasisMinimumCollateralFloorTest is DynamicYieldBasisLpFacetTest {
    uint256 internal constant COLLATERAL = 1000e18; // value 1000e18 at pps 1:1

    function _setMinimum(uint256 minimum) internal {
        vm.prank(owner_);
        portfolioFactoryConfig.setMinimumCollateral(minimum);
    }

    function _expectWithdrawRevert(uint256 amount, bytes memory expectedRevert) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.withdraw.selector, amount);
        vm.expectRevert(expectedRevert);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _seedUnstaked(uint256 amount) internal {
        lp.mint(user, amount); // top up so the larger deposit can be funded
        _depositVia(portfolioAccount, MockERC20(address(lp)), amount);
    }

    // 1. Partial withdraw into (0, minimum) reverts.
    function test_withdraw_belowMinimumPartial_revertsNoDebt() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _expectWithdrawRevert(
            950e18, // leaves 50e18 in (0, 100e18)
            abi.encodeWithSelector(DynamicYieldBasisCollateralManager.BelowMinimumCollateral.selector, 50e18, 100e18)
        );

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), COLLATERAL, "collateral retained after revert");
    }

    // 2. Full exit succeeds.
    function test_withdraw_fullExit_bypassesFloor() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawVia(portfolioAccount, COLLATERAL);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "fully exited");
    }

    // 3. Partial withdraw leaving remaining >= minimum succeeds.
    function test_withdraw_aboveMinimumPartial_succeeds() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawVia(portfolioAccount, 800e18); // leaves 200e18

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 200e18, "remaining >= minimum");
    }

    // 3b. Remaining exactly equal to minimum succeeds.
    function test_withdraw_exactlyMinimum_succeeds() public {
        _seedUnstaked(COLLATERAL);
        _setMinimum(100e18);

        _withdrawVia(portfolioAccount, 900e18); // leaves exactly 100e18

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 100e18, "remaining exactly minimum allowed");
    }

    // 4. minimum == 0 disables the floor.
    function test_withdraw_minimumUnset_allowsDust() public {
        _seedUnstaked(COLLATERAL);
        assertEq(portfolioFactoryConfig.getMinimumCollateral(), 0, "precondition: floor disabled");

        _withdrawVia(portfolioAccount, COLLATERAL - 1); // leaves 1 wei

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 1, "dust allowed when disabled");
    }

    // 6. Drained-gauge bypass. Stake into the gauge, then externally drain the account's
    //    gauge receipt shares so recoverable LP reads 0. The floor's guard is
    //    `remaining != 0 && remaining < minimum`; once getTotalCollateralValue clamps to
    //    0, `remaining != 0` is false and the floor cannot fire.
    //
    //    NOTE: As in the cached-debt variant, withdraw delivery also fails once the gauge
    //    holds no recoverable LP, so a withdraw reverts downstream -- NOT on the floor. We
    //    pin the load-bearing fact: the clamped value is 0 (floor disabled), and that the
    //    withdraw revert (if any) is not BelowMinimumCollateral.
    function test_withdraw_drainedGauge_clampsToZero_disablesFloor() public {
        _setStakedMode(true);
        _seedUnstaked(COLLATERAL); // auto-stakes since staked mode is on

        (uint256 staked, uint256 unstaked) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, COLLATERAL, "all staked");
        assertEq(unstaked, 0, "no direct LP");

        _setMinimum(100e18);

        // Externally drain the account's gauge receipt shares so recoverable LP collapses.
        // _actualLp = direct LP + gauge.convertToAssets(gaugeShares); zeroing the account's
        // gauge balance drives it to 0.
        uint256 gaugeShares = gauge.balanceOf(portfolioAccount);
        assertEq(gaugeShares, COLLATERAL, "account holds gauge receipts");
        vm.prank(portfolioAccount);
        gauge.transfer(address(0xdead), gaugeShares);

        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "drained position reads zero");

        // Confirm the floor is bypassed: any revert must NOT be BelowMinimumCollateral.
        bytes memory floorSelector = abi.encodeWithSelector(
            DynamicYieldBasisCollateralManager.BelowMinimumCollateral.selector, uint256(0), uint256(0)
        );
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.withdraw.selector, 950e18);
        try portfolioManager.multicall(calldatas, factories) {
            // No revert is also acceptable: the floor did not block.
        } catch (bytes memory reason) {
            assertTrue(
                bytes4(reason) != bytes4(floorSelector),
                "drained position must not revert on the minimum-collateral floor"
            );
        }
        vm.stopPrank();
    }
}
