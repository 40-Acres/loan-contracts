// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ---------------------------------------------------------------------------
 * Minimum-collateral dust floor on ERC4626CollateralManager.removeCollateral
 * ---------------------------------------------------------------------------
 *
 * New behavior under test (added immediately after the existing
 * "Debt exceeds max loan" check in removeCollateral):
 *
 *     uint256 remaining = getTotalCollateralValue(vault);
 *     uint256 minimum   = PortfolioFactoryConfig(cfg).getMinimumCollateral();
 *     if (remaining != 0 && remaining < minimum)
 *         revert BelowMinimumCollateral(remaining, minimum);
 *
 * Intended invariants pinned here:
 *  1. Partial withdraw leaving live value in the open interval (0, minimum)
 *     reverts with BelowMinimumCollateral(remaining, minimum).
 *  2. A full exit (remaining value == 0) succeeds even though 0 < minimum.
 *  3. A partial withdraw leaving remaining value >= minimum succeeds.
 *  4. minimum == 0 disables the floor: any non-zero dust remainder is allowed.
 *  5. The floor triggers regardless of outstanding debt -- a no-debt account
 *     cannot draw down into (0, minimum). Explicit product decision.
 *
 * These are pure additions. The existing ERC4626CollateralFacet tests run
 * with minimum == 0 (default), so the floor is a no-op there and they are
 * untouched. This file extends the same harness via inheritance.
 * -------------------------------------------------------------------------*/

import {ERC4626CollateralFacetTest} from "./ERC4626CollateralFacet.t.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";

contract ERC4626MinimumCollateralFloorTest is ERC4626CollateralFacetTest {
    // Helper: set the protocol-wide minimum collateral (onlyOwner).
    function _setMinimum(uint256 minimum) internal {
        vm.prank(_owner);
        _portfolioFactoryConfig.setMinimumCollateral(minimum);
    }

    // Helper: add `shares` worth of collateral (value == shares for the 1:1 mock vault).
    function _seedCollateral(uint256 shares) internal {
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);
    }

    // Helper: attempt a removeCollateral via multicall and expect a specific revert.
    function _expectRemoveRevert(uint256 shares, bytes memory expectedRevert) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, shares);
        vm.expectRevert(expectedRevert);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // 1. Partial withdraw into (0, minimum) reverts with BelowMinimumCollateral.
    //    1000e6 collateral, minimum 100e6, remove 950e6 -> remaining 50e6 in (0, 100e6).
    function test_removeCollateral_belowMinimumPartial_revertsNoDebt() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT); // 1000e6 shares, value 1000e6
        _seedCollateral(shares);
        _setMinimum(100e6);

        uint256 removeAmount = 950e6; // leaves 50e6 value, which is in (0, 100e6)

        _expectRemoveRevert(
            removeAmount,
            abi.encodeWithSelector(ERC4626CollateralManager.BelowMinimumCollateral.selector, 50e6, 100e6)
        );

        // State unchanged: the revert rolled back the share decrement.
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), shares, "shares unchanged after revert");
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), INITIAL_DEPOSIT, "value unchanged after revert");
    }

    // 2. Full exit (remaining == 0) succeeds despite 0 < minimum.
    function test_removeCollateral_fullExit_bypassesFloor() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);
        _setMinimum(100e6);

        // Remove everything: remaining value == 0, so the floor must not fire.
        removeCollateralViaMulticall(shares);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0, "fully exited");
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "value zero");
    }

    // 3. Partial withdraw leaving remaining >= minimum succeeds.
    //    1000e6 collateral, minimum 100e6, remove 800e6 -> remaining 200e6 >= 100e6.
    function test_removeCollateral_aboveMinimumPartial_succeeds() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);
        _setMinimum(100e6);

        uint256 removeAmount = 800e6; // leaves 200e6 value >= 100e6
        removeCollateralViaMulticall(removeAmount);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), shares - removeAmount, "partial removed");
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 200e6, "remaining at/above minimum");
    }

    // 3b. Remaining exactly equal to minimum succeeds (boundary: remaining == minimum is NOT < minimum).
    function test_removeCollateral_exactlyMinimum_succeeds() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);
        _setMinimum(100e6);

        uint256 removeAmount = 900e6; // leaves exactly 100e6 == minimum
        removeCollateralViaMulticall(removeAmount);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 100e6, "remaining exactly minimum allowed");
    }

    // 3c. One wei below minimum reverts (boundary just inside the forbidden interval).
    function test_removeCollateral_oneWeiBelowMinimum_reverts() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);
        _setMinimum(100e6);

        // Leave 100e6 - 1 value: remove 1000e6 - (100e6 - 1).
        uint256 removeAmount = INITIAL_DEPOSIT - (100e6 - 1);

        _expectRemoveRevert(
            removeAmount,
            abi.encodeWithSelector(ERC4626CollateralManager.BelowMinimumCollateral.selector, 100e6 - 1, 100e6)
        );
    }

    // 4. minimum == 0 disables the floor: a tiny non-zero remainder is allowed.
    function test_removeCollateral_minimumUnset_allowsDust() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);
        // minimum stays at default 0.
        assertEq(_portfolioFactoryConfig.getMinimumCollateral(), 0, "precondition: floor disabled");

        // Leave 1 wei of value.
        uint256 removeAmount = INITIAL_DEPOSIT - 1;
        removeCollateralViaMulticall(removeAmount);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 1, "dust remainder allowed when floor disabled");
    }

    // 5. Floor applies even when the account carries debt: removing into (0, minimum)
    //    while still solvent (debt <= maxLoan) must still revert on the floor, not on LTV.
    //    Borrow 100e6 against 1000e6 (well within 70% LTV). Then try to leave 50e6 collateral.
    //    At 50e6 collateral, maxLoan = 35e6 < 100e6 debt -> the LTV check would also reject.
    //    To isolate the floor, we pay debt down to a level the reduced collateral still covers,
    //    then leave a (0, minimum) remainder. See the no-debt test (test #1) for the pure floor.
    function test_removeCollateral_belowMinimum_revertsWithSmallDebtStillSolvent() public {
        // Use a smaller minimum so the surviving collateral still covers the small debt,
        // forcing the BelowMinimumCollateral path rather than the LTV path.
        // 1000e6 collateral, minimum 20e6, debt 5e6.
        // Remove 990e6 -> remaining 10e6 in (0, 20e6). maxLoan at 10e6 = 7e6 >= 5e6 debt: solvent.
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _seedCollateral(shares);

        borrowViaMulticall(5e6);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 5e6, "debt seeded");

        _setMinimum(20e6);

        uint256 removeAmount = 990e6; // remaining value 10e6 in (0, 20e6); 70% of 10e6 = 7e6 >= 5e6 debt

        _expectRemoveRevert(
            removeAmount,
            abi.encodeWithSelector(ERC4626CollateralManager.BelowMinimumCollateral.selector, 10e6, 20e6)
        );
    }
}
