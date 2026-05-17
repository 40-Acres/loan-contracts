// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * CollateralManagerMaxUtilizationCap
 *
 * Issue Summary
 * -------------
 * The legacy `CollateralManager` library used to hardcode `8000` (80%) as
 * the vault utilization cap in `getMaxLoanByRewardsRate`. That constant has
 * been promoted to a configurable field on `LoanConfig.maxUtilizationBps`,
 * read by `CollateralManager.getMaxLoan` at quote time.
 *
 * Why these tests are load-bearing
 * --------------------------------
 * The CollateralManager cap is the ONLY utilization protection on the
 * LoanV2 portfolio-account borrow path. `LoanV2.borrowFromPortfolio`
 * (src/PortfolioLoanLib.sol:92-111) does NOT recheck utilization on its
 * side -- it trusts the caller's max-loan quote. If the cap is silently
 * removed from `CollateralManager.getMaxLoan` (or the wiring to LoanConfig
 * is broken), nothing else stops a portfolio account from borrowing the
 * vault dry. These tests are designed to catch that regression at PR time.
 *
 * Strategy
 * --------
 * - Use the real `LoanConfig` (no mocks) via `LocalSetup`. The point is to
 *   catch regressions on either side of the contract.
 * - Stage the vault to be SUPPLY-BOUND (vault balance < cash-flow maxLoan)
 *   so that the cap arithmetic actually pins the result. With LocalSetup
 *   defaults, cash-flow `maxLoanIgnoreSupply = 5e9` USDC; we drop a
 *   smaller amount into the vault so `maxUtilization = vaultSupply * cap
 *   / 10000` is the binding constraint.
 *
 * Math reference (LocalSetup defaults: rewardsRate=10000, multiplier=100,
 *                 veBalance=5000e18, lendingAsset=USDC 6dec)
 * ---------------------------------------------------------------------
 *   maxLoanIgnoreSupply = (((5e21 * 10000) / 1e6) * 100) / 1e12 = 5e9 USDC
 *   With a fresh borrow path, outstandingCapital=0 and currentLoanBalance=0.
 *   Hence:
 *     vaultAvailableSupply = (vaultBalance * cap) / 10000
 *     maxLoan = min(maxLoanIgnoreSupply, vaultAvailableSupply)
 *
 *   We pick vaultBalance=1_000_000_000 (1e9 USDC = $1000) so:
 *     cap = 5000  -> supply-bound maxLoan = 5e8
 *     cap = 8000  -> supply-bound maxLoan = 8e8
 *     cap = 9500  -> supply-bound maxLoan = 9.5e8
 *   All three are < cash-flow maxLoanIgnoreSupply (5e9), so the cap is
 *   provably the binding constraint.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalSetup} from "../utils/LocalSetup.sol";

contract CollateralManagerMaxUtilizationCapTest is Test, LocalSetup {

    // Cash-flow maxLoanIgnoreSupply with LocalSetup defaults.
    uint256 constant CASH_FLOW_MAX = 5e9; // $5000 USDC

    // Supply-bound vault balance. Picked so every reasonable cap pins
    // below the cash-flow ceiling.
    uint256 constant VAULT_BAL = 1_000_000_000; // $1000 USDC (6 decimals)

    function _setCap(uint256 capBps) internal {
        vm.prank(_owner);
        _loanConfig.setMaxUtilizationBps(capBps);
    }

    function _seedVault(uint256 amount) internal {
        deal(address(_asset), _vault, amount);
    }

    function _addCollateral() internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    //  Section 1: unset-storage fallback path equals explicit 8000 path
    // -----------------------------------------------------------------

    /// @notice With a fresh CollateralManager-backed portfolio whose
    ///         `maxUtilizationBps` storage was NEVER written, the legacy
    ///         8000 fallback in `getMaxUtilizationBps` MUST produce the same
    ///         max-loan quote as if 8000 had been set explicitly.
    ///
    ///         If a future refactor removes the fallback constant (or
    ///         changes its value), this test fails -- catching the
    ///         silent regression on proxies upgraded before the seed call.
    function test_unsetCap_matchesExplicit8000() public {
        // LocalSetup's _setLoanConfigDefaults does NOT call
        // setMaxUtilizationBps -- so storage is unset here. (If a future
        // LocalSetup change starts seeding it, this preamble guards us
        // by re-reading the constant fallback explicitly.)
        assertEq(_loanConfig.getMaxUtilizationBps(), 8000, "fallback constant must be 8000");

        _addCollateral();
        _seedVault(VAULT_BAL);
        (uint256 maxLoanUnset,) = CollateralFacet(_portfolioAccount).getMaxLoan();

        _setCap(8000);
        (uint256 maxLoanExplicit,) = CollateralFacet(_portfolioAccount).getMaxLoan();

        assertEq(maxLoanUnset, maxLoanExplicit, "fallback path must equal explicit-8000 path");
        // Sanity: pin the supply-bound number too, so a stealth math change surfaces.
        assertEq(maxLoanUnset, (VAULT_BAL * 8000) / 10_000, "supply-bound formula: vaultBal * cap / 10000");
    }

    // -----------------------------------------------------------------
    //  Section 2: cap directionally affects supply-bound maxLoan
    // -----------------------------------------------------------------

    /// @notice Lowering the cap below the default MUST lower the supply-bound
    ///         quote. The math is exact: 50% cap -> half the available supply.
    function test_cap5000_lowersMaxLoan() public {
        _addCollateral();
        _seedVault(VAULT_BAL);

        // Baseline at the default cap (8000 via LoanConfig fallback; storage unset).
        (uint256 maxLoanDefault,) = CollateralFacet(_portfolioAccount).getMaxLoan();

        _setCap(5000);
        (uint256 maxLoan50pct,) = CollateralFacet(_portfolioAccount).getMaxLoan();

        // Exact: vaultBal * 5000 / 10000 = vaultBal / 2.
        assertEq(maxLoan50pct, VAULT_BAL / 2, "50% cap pins to half the vault supply");
        assertLt(maxLoan50pct, maxLoanDefault, "50% cap must be strictly lower than 80%");
    }

    /// @notice CANARY for the user's motivation -- "when we update our Vault
    ///         possibly we can set the cap a bit higher". Raising the cap
    ///         above the default 8000 MUST raise the supply-bound quote.
    ///         If a future refactor caps writes at 8000 (or ignores values
    ///         above 8000), this test fails.
    function test_cap9500_raisesMaxLoan() public {
        _addCollateral();
        _seedVault(VAULT_BAL);

        // Baseline at the default cap (8000 via LoanConfig fallback; storage unset).
        (uint256 maxLoanDefault,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanDefault, (VAULT_BAL * 8000) / 10_000, "baseline @ 80%");

        _setCap(9500);
        (uint256 maxLoan95pct,) = CollateralFacet(_portfolioAccount).getMaxLoan();

        assertEq(maxLoan95pct, (VAULT_BAL * 9500) / 10_000, "95% cap pins to 95% of vault supply");
        assertGt(maxLoan95pct, maxLoanDefault, "95% cap must strictly exceed 80% baseline");
    }

    // -----------------------------------------------------------------
    //  Section 3: over-utilized branch returns (0, maxLoanIgnoreSupply)
    // -----------------------------------------------------------------

    /// @notice Guards the over-utilized branch at CollateralManager:309.
    ///         When `outstandingCapital >= maxUtilization`, getMaxLoan must
    ///         return (0, maxLoanIgnoreSupply) -- no further borrow allowed,
    ///         but the cash-flow ceiling is preserved for collateral math.
    ///
    ///         We exercise this by borrowing the entire supply-bound capacity
    ///         and then quoting again. outstandingCapital now equals
    ///         maxUtilization, so the equal-or-greater branch fires.
    function test_overUtilized_returnsZeroMaxLoan_keepsIgnoreSupply() public {
        // Default cap 8000 via LoanConfig fallback; storage left unset. Tight enough
        // that the supply budget is small and easy to exhaust.
        _addCollateral();

        // Drop vault balance such that supply-bound max == 200e6 USDC.
        uint256 vaultBal = 250_000_000; // 250e6 -> 80% cap = 200e6
        _seedVault(vaultBal);

        (uint256 maxLoanBefore, uint256 ignoreSupplyBefore) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanBefore, (vaultBal * 8000) / 10_000, "supply-bound baseline");
        assertEq(ignoreSupplyBefore, CASH_FLOW_MAX, "cash-flow ceiling unchanged");

        // Borrow the entire supply-bound capacity. After this,
        // outstandingCapital == maxUtilization.
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, maxLoanBefore);
        _portfolioManager.multicall(data, factories);
        vm.stopPrank();

        (uint256 maxLoanAfter, uint256 ignoreSupplyAfter) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanAfter, 0, "over-utilized: maxLoan must be 0");
        assertEq(ignoreSupplyAfter, CASH_FLOW_MAX, "ignoreSupply preserved on over-utilized branch");
    }

    // -----------------------------------------------------------------
    //  Section 4: The DO-NOT-REMOVE regression
    // -----------------------------------------------------------------

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    ///
    ///         This is the LoanV2 portfolio-account borrow path's ONLY
    ///         utilization protection. `LoanV2.borrowFromPortfolio`
    ///         (src/PortfolioLoanLib.sol:92-111) does not recheck the
    ///         vault-side cap; it trusts the caller's max-loan quote.
    ///         If a future refactor "unifies" CollateralManager with one
    ///         of its sibling libraries, or strips this branch as dead
    ///         code, the entire vault becomes drainable up to
    ///         maxLoanIgnoreSupply with no utilization brake.
    ///
    ///         Removing this test does NOT constitute coverage cleanup.
    ///         If you are touching this, read CollateralManager.getMaxLoan
    ///         and PortfolioLoanLib.borrowFromPortfolio first and confirm
    ///         the cap is still enforced somewhere on the borrow path.
    function test_CollateralManager_BorrowCapBoundedByLoanConfig_DoNotRemove() public {
        _addCollateral();
        _seedVault(VAULT_BAL);

        // Three caps, three distinct supply-bound answers. The mapping is
        // exact and easily checked from the LoanConfig value alone --
        // breaking the wiring breaks at least one of these equalities.
        _setCap(5000);
        (uint256 m50,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(m50, (VAULT_BAL * 5000) / 10_000, "cap 5000 must pin to 50% of vault supply");

        _setCap(8000);
        (uint256 m80,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(m80, (VAULT_BAL * 8000) / 10_000, "cap 8000 must pin to 80% of vault supply");

        _setCap(9500);
        (uint256 m95,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(m95, (VAULT_BAL * 9500) / 10_000, "cap 9500 must pin to 95% of vault supply");

        // Monotonicity -- the cap is the dominant lever; the only way to
        // fail this is to ignore the LoanConfig value entirely.
        assertLt(m50, m80, "cap monotonicity (50 < 80)");
        assertLt(m80, m95, "cap monotonicity (80 < 95)");
    }
}
