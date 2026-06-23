// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * BUG UNDER TEST -- borrow capacity priced at appreciated value
 * ==========================================================================
 *
 * Both ERC4626CollateralManager and YieldBasisCollateralManager feed
 * getMaxLoan from getTotalCollateralValue, which marks shares at their full
 * CURRENT value (appreciation included). A borrower can therefore draw
 * against collateral appreciation. That appreciation is supposed to be
 * reserved for yield harvesting -- so a borrower who borrows against it later
 * cannot harvest (the harvest path reverts "Debt exceeds max loan"), starving
 * lender premium.
 *
 * Agreed fix (Option A): the value feeding getMaxLoan must be capped at cost
 * basis, i.e. min(depositedAssetValue, currentCollateralValue). An appreciated
 * position's borrow capacity is based on cost basis, NOT the appreciated value.
 *
 * These tests assert the POST-FIX (~cost-basis) numbers. The appreciation
 * cases FAIL on current code (they report the appreciated value). The
 * depreciation and no-yield cases must PASS both before and after, proving
 * the cap is min() rather than a bare cost-basis substitution.
 * ==========================================================================
 */

import {Test} from "forge-std/Test.sol";

import {ERC4626CollateralFacetTest} from "./ERC4626CollateralFacet.t.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";

import {YieldBasisCollateralManagerTest} from "../yieldbasis/YieldBasisCollateralManager.t.sol";

/* ---------------------------------------------------------------------------
 * ERC4626 cost-basis cap
 *
 * Reuses ERC4626CollateralFacetTest's full setUp (PortfolioFactory, configs,
 * DynamicFeesVault, MockERC4626 with simulateYield, 70% LTV like-to-like).
 * We assert on maxLoanIgnoreSupply, which is the supply-independent LTV
 * ceiling computed purely from collateral value * ltv / 10000.
 * -------------------------------------------------------------------------*/
contract ERC4626CostBasisCappedMaxLoanTest is ERC4626CollateralFacetTest {
    // INITIAL_DEPOSIT = 1000e6, LTV = 7000 bps (from the inherited setUp).
    // 1 share == 1 asset at deposit time, so deposited value == 1000e6.

    function _addOneThousandCollateral() internal returns (uint256 shares) {
        shares = prepareUserWithVaultShares(INITIAL_DEPOSIT); // 1000e6 -> 1000e6 shares
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);
    }

    // Double the value of the existing shares: deposit 1000e6 collateral, then
    // mint another 1000e6 of underlying into the vault as yield. previewRedeem
    // of the same shares now reports ~2000e6.
    function _appreciateToDouble() internal {
        uint256 yieldAmount = INITIAL_DEPOSIT; // +1000e6 -> shares worth 2000e6
        _underlyingAsset.mint(_owner, yieldAmount);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yieldAmount);
        _mockVault.simulateYield(yieldAmount);
        vm.stopPrank();
    }

    // Case 1 (PRIMARY): over-borrow against appreciation.
    // Deposit worth 1000e6, appreciate to 2000e6.
    //   buggy:    maxLoanIgnoreSupply = 2000e6 * 70% = 1400e6
    //   post-fix: min(1000e6, 2000e6) * 70% = 1000e6 * 70% = 700e6
    // Asserting 700e6 -> FAILS on current code (it returns 1400e6).
    function test_erc4626_maxLoan_cappedAtCostBasis_whenAppreciated() public {
        _addOneThousandCollateral();

        // sanity: current value is the appreciated 2000e6
        _appreciateToDouble();
        uint256 currentValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(currentValue, 2000e6, "sanity: shares appreciated to 2000e6");

        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // POST-FIX expectation: capped at cost basis (1000e6), not 2000e6.
        assertEq(
            maxLoanIgnoreSupply,
            700e6,
            "maxLoan must price collateral at cost basis (1000e6 * 70%), not appreciated value"
        );
    }

    // Case 2 (DEPRECIATION SAFETY): must pass before and after the fix.
    // Deposit worth 1000e6, value drops to 600e6.
    //   min(1000e6, 600e6) = 600e6 -> maxLoanIgnoreSupply = 600e6 * 70% = 420e6
    // Guards that the fix keeps min() semantics rather than always using cost basis.
    function test_erc4626_maxLoan_usesCurrentValue_whenDepreciated() public {
        _addOneThousandCollateral();

        // Drain 40% of vault assets so the same shares are worth 600e6.
        // Withdraw 400e6 of underlying out of the vault (no shares burned),
        // dropping previewRedeem to 600e6.
        uint256 drain = 400e6;
        vm.prank(address(_mockVault));
        _underlyingAsset.transfer(_owner, drain);

        uint256 currentValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(currentValue, 600e6, "sanity: shares depreciated to 600e6");

        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // min(1000e6, 600e6) * 70% = 420e6. Uses the lower current value, not cost basis.
        assertEq(
            maxLoanIgnoreSupply,
            420e6,
            "maxLoan must use the lower current value (600e6 * 70%) when depreciated"
        );
    }

    // Case 3 (NO-YIELD): current == cost basis, behavior unchanged.
    //   maxLoanIgnoreSupply = 1000e6 * 70% = 700e6
    function test_erc4626_maxLoan_unchanged_whenNoYield() public {
        _addOneThousandCollateral();

        uint256 currentValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(currentValue, 1000e6, "sanity: no appreciation, current == cost basis");

        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanIgnoreSupply, 700e6, "no-yield: maxLoan = costBasis * 70%");
    }
}

/* ---------------------------------------------------------------------------
 * YieldBasis cost-basis cap (Case 4)
 *
 * Reuses YieldBasisCollateralManagerTest's harness + infra (70% LTV
 * like-to-like). The YB harness exposes getMaxLoan directly. pps appreciation
 * is simulated via MockYieldBasisLP.setPricePerShare.
 * -------------------------------------------------------------------------*/
contract YieldBasisCostBasisCappedMaxLoanTest is YieldBasisCollateralManagerTest {
    // Deposit 10e18 LP @ pps=1 -> depositedAssetValue = 10e18.
    // Appreciate pps 1 -> 2 -> current value = 20e18.
    //   buggy:    maxLoanIgnoreSupply = 20e18 * 70% = 14e18
    //   post-fix: min(10e18, 20e18) * 70% = 10e18 * 70% = 7e18
    // Asserting 7e18 -> FAILS on current code (returns 14e18).
    function test_yb_maxLoan_cappedAtCostBasis_whenAppreciated() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Appreciate. depositedAssetValue stays frozen at 10e18; current -> 20e18.
        ybLp.setPricePerShare(2e18);

        uint256 currentValue = h.getTotalCollateralValue(address(ybLp), address(underlying));
        assertEq(currentValue, 20e18, "sanity: pps doubled -> current value 20e18");

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));

        assertEq(
            maxLoanIgnoreSupply,
            7e18,
            "YB maxLoan must price collateral at cost basis (10e18 * 70%), not appreciated value"
        );
    }

    // Depreciation safety on the YB path: pps drops below deposit, min() picks
    // the lower current value. Passes before and after the fix.
    //   deposit 10e18 @ pps=1, pps drops to 0.6 -> current 6e18
    //   min(10e18, 6e18) * 70% = 4.2e18
    function test_yb_maxLoan_usesCurrentValue_whenDepreciated() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        ybLp.setPricePerShare(0.6e18);

        uint256 currentValue = h.getTotalCollateralValue(address(ybLp), address(underlying));
        assertEq(currentValue, 6e18, "sanity: pps dropped -> current value 6e18");

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
        assertEq(maxLoanIgnoreSupply, 4.2e18, "YB maxLoan uses lower current value (6e18 * 70%)");
    }
}
