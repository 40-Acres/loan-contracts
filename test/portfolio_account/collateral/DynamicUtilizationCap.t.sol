// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicUtilizationCap
 *
 * Issue Summary
 * -------------
 * `DynamicCollateralManager._recomputeEnforcementFlags` now maintains TWO
 * independent flags:
 *
 *   * `undercollateralizedDebt = max(actualTotalDebt - maxLoanIgnoreSupply, 0)`
 *     -- collateral-side shortfall (borrower's debt above their cash-flow
 *        ceiling).
 *
 *   * `overSuppliedVaultDebt = max(activeAssets - (totalAssets * cap / 10000), 0)`
 *     -- global pool utilization above the LoanConfig cap.
 *
 * Pre-refactor both were derived from the same `excess`. Now they answer
 * separate questions and can be non-zero independently. `enforceCollateralRequirements()`
 * reverts on either non-zero flag.
 *
 * Why these tests are load-bearing
 * --------------------------------
 * If a refactor collapses the two flags back into one, the diagnostic
 * distinction (which gate tripped?) is lost. If `_recomputeEnforcementFlags`
 * regresses to hardcoded 8000, the operator can no longer raise the cap.
 * These tests pin both the separation and the cap-from-LoanConfig wiring.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {DynamicCollateralManager} from "../../../src/facets/account/collateral/DynamicCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 *  Harness owning the ERC-7201 slot keccak256("storage.DynamicCollateralManager").
 *  Storage layout per CollateralManagerData (Dynamic variant):
 *    slot+0: lockedCollaterals (mapping)
 *    slot+1: originTimestamps (mapping)
 *    slot+2: totalLockedCollateral
 *    slot+3: overSuppliedVaultDebt
 *    slot+4: undercollateralizedDebt
 * -------------------------------------------------------------------------*/
contract DynUtilHarness {
    function increaseTotalDebt(address cfg, uint256 amount) external returns (uint256, uint256) {
        return DynamicCollateralManager.increaseTotalDebt(cfg, amount);
    }
    function decreaseTotalDebt(address cfg, uint256 amount) external returns (uint256) {
        return DynamicCollateralManager.decreaseTotalDebt(cfg, amount);
    }
    function enforceCollateralRequirements() external view returns (bool) {
        return DynamicCollateralManager.enforceCollateralRequirements();
    }
    function getMaxLoan(address cfg) external view returns (uint256, uint256) {
        return DynamicCollateralManager.getMaxLoan(cfg);
    }

    function readTotalLockedCollateral() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { v := sload(add(s, 2)) }
    }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { v := sload(add(s, 3)) }
    }
    function readUndercollat() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { v := sload(add(s, 4)) }
    }
    /// @dev Pokes totalLockedCollateral directly so we can set up the cash-flow
    /// ceiling without dragging a full VotingEscrow into the test. The library
    /// only reads this value via getMaxLoan; storage layout is documented above.
    function __setTotalLocked(uint256 v) external {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { sstore(add(s, 2), v) }
    }
}

/* ---------------------------------------------------------------------------
 *  Mock vault+pool: implements both ILendingPool and the ILendingVault slice
 *  the Dynamic manager reads. activeAssets and totalAssets are independently
 *  settable so we can stage any global utilization state pre- and post-borrow.
 * -------------------------------------------------------------------------*/
contract MockDynPool {
    IERC20 public immutable assetToken;
    address public immutable portfolioFactory;
    uint256 public _activeAssets;
    uint256 public _totalAssets;
    mapping(address => uint256) public debt;

    constructor(address asset_, address factory_) {
        assetToken = IERC20(asset_);
        portfolioFactory = factory_;
    }

    function borrowFromPortfolio(uint256 amount) external returns (uint256) {
        debt[msg.sender] += amount;
        _activeAssets += amount;
        if (assetToken.balanceOf(address(this)) >= amount) {
            assetToken.transfer(msg.sender, amount);
        }
        return 0;
    }
    function payFromPortfolio(uint256 totalPayment, uint256) external returns (uint256 actualPaid) {
        uint256 d = debt[msg.sender];
        actualPaid = totalPayment > d ? d : totalPayment;
        if (actualPaid > 0) {
            assetToken.transferFrom(msg.sender, address(this), actualPaid);
            debt[msg.sender] -= actualPaid;
            if (_activeAssets >= actualPaid) _activeAssets -= actualPaid;
            else _activeAssets = 0;
        }
    }
    function lendingAsset() external view returns (address) { return address(assetToken); }
    function lendingVault() external view returns (address) { return address(this); }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    // Mirrors DynamicFeesVault's conservative read. This harness models a vault with
    // no unsettled borrower pending, so the conservative figure equals activeAssets().
    // Required because DynamicCollateralManager.getMaxLoan now hard-casts the lending
    // pool to IDynamicLendingPool and reads activeAssetsConservative().
    function activeAssetsConservative() external view returns (uint256) { return _activeAssets; }
    function getDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function getEffectiveDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function totalAssets() external view returns (uint256) { return _totalAssets; }
    function asset() external view returns (address) { return address(assetToken); }
    function getPortfolioFactory() external view returns (address) { return portfolioFactory; }
    function depositRewards(uint256) external {}

    function setActive(uint256 v) external { _activeAssets = v; }
    function setTotal(uint256 v) external { _totalAssets = v; }
    function setDebt(address b, uint256 v) external { debt[b] = v; }
}

contract DynamicUtilizationCapTest is Test {
    DynUtilHarness internal h;
    MockDynPool internal pool;
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    MockERC20 internal usdc;

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);
    // Manager-impersonation prank target. The non-AUTH caller path skips the
    // inline `enforceCollateralRequirements` that was added to the AUTH branch
    // of increaseTotalDebt — multicall flows rely on PortfolioManager.multicall
    // to enforce at end-of-tx instead. Tests that intentionally stage over-cap
    // state to inspect flag math must use this path so the inline enforce
    // doesn't revert mid-borrow before the assertions can run.
    address internal MANAGER;

    // rewardsRate=10000, multiplier=100, locked=5000e18
    //   maxLoanIgnoreSupply = (((5e21 * 10000)/1e6) * 100)/1e12 = 5e9 (USDC 6dec)
    uint256 internal constant LOCKED = 5000e18;
    uint256 internal constant CASH_FLOW_MAX = 5e9;

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, ) = pm.deployFactory(keccak256("dyn-utilcap-test"));
        factory = f;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        usdc = new MockERC20("USDC", "USDC", 6);

        pool = new MockDynPool(address(usdc), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // Dynamic / Velo cash-flow path: rewardsRate * multiplier defines max.
        // Leave LTV at 0 so getMaxLoan uses the cash-flow branch.
        loanConfig.setRewardsRate(10000);
        loanConfig.setMultiplier(100);
        // maxUtilizationBps unset -> defaults to 8000.

        vm.stopPrank();

        h = new DynUtilHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(AUTH, true);

        MANAGER = address(pm);

        // Seed totalLockedCollateral so getMaxLoan's cash-flow ceiling is non-zero.
        h.__setTotalLocked(LOCKED);

        vm.label(address(h), "DynUtilHarness");
        vm.label(address(pool), "MockDynPool");
    }

    function _setCap(uint256 bps) internal {
        vm.prank(OWNER);
        loanConfig.setMaxUtilizationBps(bps);
    }

    /* ---------------------------------------------------------------
     * Section 1: cap-respecting borrow keeps both flags at zero
     * --------------------------------------------------------------- */

    function test_borrowUnderCap_bothFlagsZero() public {
        pool.setTotal(1_000_000_000); // 1e9 USDC totalAssets; cap 8000 -> 8e8
        usdc.mint(address(pool), 1_000_000_000);

        // Borrow 100e6: active=100e6 < cap 8e8; debt 100e6 << cash-flow 5e9.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 100e6);

        assertEq(h.readOverSupplied(), 0, "overSupplied must be 0 (under cap)");
        assertEq(h.readUndercollat(), 0, "undercollat must be 0 (well-collateralized)");
        assertTrue(h.enforceCollateralRequirements());
    }

    /* ---------------------------------------------------------------
     * Section 2: supply overshoot is independent of collateral overshoot
     * --------------------------------------------------------------- */

    /// @notice With totalAssets=100e6, cap=8000 -> 80e6. Borrow 90e6.
    /// activeAssets 90e6 > cap 80e6 -> overSupplied = 10e6.
    /// debt 90e6 << cash-flow ceiling 5e9 -> undercollat MUST stay 0.
    /// This proves the two flags are computed from independent inputs.
    function test_overCap_supplyFlagSet_collateralFlagZero() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // Manager-impersonation: this borrow is intentionally over-cap to
        // inspect raw flag accumulation. The AUTH path now reverts inline on
        // BadDebt, which would short-circuit the assertions below. The
        // multicall path (manager-impersonation) is the canonical path that
        // exercises this state pre-enforce.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 90e6);

        assertEq(h.readOverSupplied(), 10e6, "supply flag = active - cap");
        assertEq(h.readUndercollat(), 0, "collateral flag must stay 0; borrower is well-collateralized");
    }

    /* ---------------------------------------------------------------
     * Section 3: both flags non-zero simultaneously
     * --------------------------------------------------------------- */

    /// @notice Drop the cash-flow ceiling so a single borrow lands BOTH:
    ///   (a) amount > maxLoan (cap-pinned)              -> supply flag +=
    ///   (b) actualDebt > maxLoanIgnoreSupply (cash-flow)-> undercollat set
    /// Then enforcement reverts -- in the current implementation order it
    /// reverts on BadDebt(supply) FIRST. The point of this test is that BOTH
    /// flags are populated, so a future flip in order is still caught.
    ///
    /// Note: under the new per-borrower semantics, both flags must be raised
    /// by THIS borrower's own action. Pre-staging global state via setDebt /
    /// setActive + a no-op decreaseTotalDebt no longer raises the supply
    /// flag because the repay path only decrements (never reads global state
    /// to raise). So we drive both flags through one over-cap, over-cash-flow
    /// borrow.
    function test_bothOvershoot_bothFlagsSetAndEnforcementReverts() public {
        // Reduce collateral so the cash-flow ceiling drops:
        // locked=1000e18 -> maxLoanIgnoreSupply = (((1e21 * 10000)/1e6) * 100)/1e12 = 1e9
        h.__setTotalLocked(1000e18);

        // totalAssets=100e6 -> cap 80e6. maxLoan = min(1e9, 80e6) = 80e6.
        pool.setTotal(100e6);
        // Mint enough to satisfy the borrow transfer (cash-flow ceiling > cap, but
        // the borrow pulls past totalAssets; mock pool just transfers if it has the
        // balance, so seed it with the borrow amount).
        usdc.mint(address(pool), 1_100_000_000);

        // Borrow 1.1e9:
        //   pre-borrow:  amount 1.1e9 > maxLoan 80e6  -> overSupplied += 1.02e9
        //   post-borrow: debt 1.1e9 > maxLoanIgnoreSupply 1e9 -> undercollat = 100e6
        // Use manager-impersonation so the inline AUTH enforce doesn't revert
        // before the flag assertions can inspect raw state.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 1_100_000_000);

        assertEq(h.readUndercollat(), 100e6, "undercollat = actualDebt - maxLoanIgnoreSupply = 100e6");
        assertEq(h.readOverSupplied(), 1_100_000_000 - 80e6, "overSupplied = amount - maxLoan = 1.02e9");

        // Order check: BadDebt fires first per current branch order.
        vm.expectRevert(
            abi.encodeWithSelector(DynamicCollateralManager.BadDebt.selector, uint256(1_100_000_000 - 80e6))
        );
        h.enforceCollateralRequirements();
    }

    /* ---------------------------------------------------------------
     * Section 4: collateral overshoot alone reverts UndercollateralizedDebt
     * --------------------------------------------------------------- */

    function test_collateralOvershootAlone_revertsUndercollateralized() public {
        // Drop the cash-flow ceiling: locked=1000e18 -> maxLoanIgnoreSupply = 1e9.
        h.__setTotalLocked(1000e18);

        // Stage debt > maxLoanIgnoreSupply but active <= cap so ONLY the
        // collateral flag fires.
        pool.setTotal(10e9);                       // cap 8e9, easy to stay under
        pool.setDebt(address(h), 1_100_000_000);   // 1.1e9 > 1e9 -> undercollat 100e6
        pool.setActive(100e6);                     // 100e6 < 8e9 -> overSupplied 0

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 0);

        assertEq(h.readUndercollat(), 100e6, "undercollat = 100e6");
        assertEq(h.readOverSupplied(), 0, "overSupplied must be 0");

        vm.expectRevert(
            abi.encodeWithSelector(DynamicCollateralManager.UndercollateralizedDebt.selector, uint256(100e6))
        );
        h.enforceCollateralRequirements();
    }

    /* ---------------------------------------------------------------
     * Section 5: repay brings utilization back under cap -> flag clears
     * --------------------------------------------------------------- */

    function test_repayClearsSupplyFlag() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // Manager-impersonation so the over-cap borrow can stage the flag.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 90e6);
        assertEq(h.readOverSupplied(), 10e6, "flag set after over-cap borrow");

        // Fund harness for repayment.
        usdc.mint(address(h), 20e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 20e6);

        // active = 90 - 20 = 70 <= cap 80 -> flag clears.
        assertEq(h.readOverSupplied(), 0, "flag must clear after repay brings util under cap");
        assertEq(h.readUndercollat(), 0, "collateral flag must stay 0");
    }

    /* ---------------------------------------------------------------
     * Section 6: raising cap unlocks borrow that would have flagged
     * --------------------------------------------------------------- */

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// User-stated motivation: "when we update our Vault possibly we can set
    /// the cap a bit higher". At cap 8000, a 90e6 borrow against 100e6
    /// totalAssets flags 10e6 supply overshoot. At cap 9500, the same borrow
    /// is clean. This pins the cap-from-LoanConfig wiring in the Dynamic
    /// manager and the post-state recompute path. Removing this test is not
    /// coverage cleanup.
    function test_Dynamic_RaisingCapUnlocksBorrow_DoNotRemove() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // ---- At default cap (8000 via LoanConfig fallback; storage left unset).
        // Manager-impersonation for the over-cap leg so inline enforce doesn't
        // mask the flag-math we want to inspect.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 90e6);
        assertEq(h.readOverSupplied(), 10e6, "default cap 8000: 90e6 exceeds 80e6 by 10e6");

        // Wipe and re-stage.
        usdc.mint(address(h), 90e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 90e6);
        assertEq(h.readOverSupplied(), 0, "flag cleared after repay");

        // ---- At cap 9500: borrow now sits under cap, AUTH path is clean.
        _setCap(9500);
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 90e6);
        assertEq(h.readOverSupplied(), 0, "at cap 9500: 90e6 within 95e6 cap, flag must be 0");

        assertTrue(h.enforceCollateralRequirements());
    }

    /* ---------------------------------------------------------------
     * Section 7: zero-totalAssets pool -- any positive active flags FULL excess
     *
     * Ported from the legacy vault-side `*revertsOnZeroTotalAssets` test.
     * Old behavior: vault reverted ExceedsUtilization on any borrow when
     * totalAssets == 0. New behavior: borrow succeeds at the vault, the
     * cap evaluates to `0 * bps / 10000 == 0`, so the entire activeAssets
     * is "over" the cap and overSuppliedVaultDebt absorbs it. Enforcement
     * then reverts BadDebt with the full excess.
     * --------------------------------------------------------------- */

    /// @notice With vault.totalAssets() == 0 the cap collapses to 0 and any
    /// borrow >= 1 wei is fully over the cap. Borrow MUST succeed at the
    /// pool but enforcement MUST revert with BadDebt(borrowAmount).
    function test_borrowAgainstZeroTotalAssets_flagAbsorbsAll_revertsBadDebt() public {
        // pool.totalAssets stays 0 (default). Mint to pool so transfer works.
        usdc.mint(address(pool), 1);

        // 1 wei borrow. activeAssets = 1, cap = 0 -> flag = 1.
        // Manager-impersonation to bypass inline AUTH enforce so we can inspect
        // the staged flag rather than the inline revert.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 1);

        assertEq(h.readOverSupplied(), 1, "1 wei borrow into zero-totalAssets pool flags 1 wei");
        assertEq(h.readUndercollat(), 0, "collateral flag must stay 0 (well-collateralized)");

        vm.expectRevert(abi.encodeWithSelector(DynamicCollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements();
    }

    /* ---------------------------------------------------------------
     * Section 8: boundary around the cap (cap-1, cap, cap+1)
     *
     * Ported from the legacy `*revertsAtExactCap` and
     * `*succeedsOneWeiBelowCap` vault tests. The new `_recomputeOverSupplied`
     * uses strict `>` so activeAssets == cap is FINE -- a behavior change
     * vs. legacy vault enforcement which used `>=` and reverted at exact cap.
     * Removing this test would silently lose the boundary documentation.
     * --------------------------------------------------------------- */

    /// @notice Behavior change vs. legacy vault enforcement which used >=
    /// and reverted at exact cap. Removing this test would silently lose
    /// the boundary documentation. Walks cap-1, cap, cap+1 to pin the
    /// strict-greater-than comparison in `_recomputeEnforcementFlags`.
    function test_Dynamic_BoundaryAroundCap_NoFlagSet_DoNotRemove() public {
        // totalAssets = 100e6, cap 8000 bps -> cap = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // ---- cap - 1: under cap, flag stays 0. AUTH path is clean.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 80e6 - 1);
        assertEq(h.readOverSupplied(), 0, "cap - 1: flag must be 0");
        assertTrue(h.enforceCollateralRequirements(), "cap - 1: enforcement passes");

        // Repay back to zero to set up the exact-cap trial cleanly.
        usdc.mint(address(h), 80e6 - 1);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 80e6 - 1);
        assertEq(h.readOverSupplied(), 0, "post-repay flag back to 0");

        // ---- exact cap: strict `>` -- flag stays 0, enforcement passes.
        // This is the behavior-change pin: legacy vault used `>=` and reverted here.
        // AUTH path is clean because the flag stays at 0.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 80e6);
        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");
        assertTrue(h.enforceCollateralRequirements(), "exact cap: enforcement passes");

        // ---- cap + 1: flag = 1. Manager-impersonation here -- AUTH would
        // revert inline on BadDebt(1) and short-circuit the flag inspection.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 1);
        assertEq(h.readOverSupplied(), 1, "cap + 1: flag = exactly 1 wei");

        vm.expectRevert(abi.encodeWithSelector(DynamicCollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements();
    }

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Behavior change vs. legacy vault enforcement which used >= and
    /// reverted at exact cap. Removing this test would silently lose
    /// the boundary documentation. Pins the strict-greater-than
    /// comparison: activeAssets == cap MUST leave the flag at 0 and
    /// enforcement MUST pass.
    function test_Dynamic_BorrowAtExactCap_NoFlagSet_DoNotRemove() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // Borrow exactly cap (80e6 at 8000 bps).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 80e6);

        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");
        assertEq(h.readUndercollat(), 0, "collateral flag must stay 0");
        assertTrue(h.enforceCollateralRequirements(), "exact cap: enforcement passes");
    }

    /* ---------------------------------------------------------------
     * Section 9: repay-never-reverts invariant (BUG REGRESSION)
     *
     * Pre-fix, `_recomputeEnforcementFlags` (called from the repay path) set
     * `overSuppliedVaultDebt = max(activeAssets - cap, 0)` absolutely. If
     * external state (another borrower's debt, or vesting shrinking
     * totalAssets) had already pushed the pool over cap, a clean borrower
     * making a legitimate repay would have the global excess pinned to THEM,
     * and `enforceCollateralRequirements()` would revert -- blocking the
     * repay.
     *
     * Post-fix, the repay path uses `_recomputeFlagsOnDecrease` which only
     * lowers `overSuppliedVaultDebt` -- never raises it.
     * --------------------------------------------------------------- */

    /// @notice Regression for the repay-never-reverts invariant. External
    /// over-cap state must not be attributed to a borrower who is merely
    /// repaying. Without the clamp-down in `_recomputeFlagsOnDecrease`,
    /// a repay during this state would raise the flag and revert.
    function test_DynamicCollateralManager_RepayWhenPoolExternallyOverCap_FlagNotRaised_DoNotRemove() public {
        // totalAssets = 100e6, cap 8000 bps -> cap = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // 1) Borrower starts clean: flag is 0.
        assertEq(h.readOverSupplied(), 0, "precondition: borrower flag is 0");

        // 2) Borrower has a small debt to repay. 10e6 << cap 80e6, so the
        //    borrow alone does NOT trip the flag.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 10e6);
        assertEq(h.readOverSupplied(), 0, "small borrow under cap: flag still 0");
        assertEq(h.readUndercollat(), 0, "borrower is well-collateralized");

        // 3) External state pushes pool over cap. Bump activeAssets directly
        //    (simulates another borrower's debt growing -- or totalAssets
        //    shrinking via vesting). Pool now has active=120e6 vs cap=80e6
        //    -- 40e6 over cap, attributable to "someone else".
        pool.setActive(120e6);

        // 4) Borrower repays a portion (5e6 of their 10e6).
        usdc.mint(address(h), 5e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 5e6);

        // 5) Flag MUST still be 0. The clamp-down path only LOWERS the flag.
        assertEq(
            h.readOverSupplied(),
            0,
            "repay must not RAISE the supply flag from external over-cap state"
        );
        assertEq(h.readUndercollat(), 0, "collateral flag must stay 0");

        // 6) Enforcement must NOT revert -- repay path succeeds end-to-end.
        assertTrue(h.enforceCollateralRequirements(), "enforce must pass after legitimate repay");
    }

    /// @notice Paired test: partial-clear case. Under the new per-borrower
    /// semantics, the supply flag is accumulated by `+=` on over-cap borrows
    /// and decremented by `-= actualPaid` on repays. So after a 110e6 borrow
    /// (maxLoan = 80e6, flag += 30e6) and a 10e6 repay (flag -= 10e6), the
    /// flag must read 20e6 -- the original excess minus what was actually
    /// paid down. The flag must NEVER be raised by a repay, and it must
    /// strictly decrease toward zero as the borrower pays.
    function test_DynamicCollateralManager_RepayPartialClear_FlagLoweredToNewExcess_DoNotRemove() public {
        // totalAssets = 100e6, cap = 80e6 -> maxLoan = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // Borrower's own borrow pushes pool over cap: borrow 110e6 against
        // maxLoan 80e6 -> flag += (110 - 80) = 30e6, attributed to this borrower.
        // Manager-impersonation so the inline AUTH enforce doesn't revert
        // before the flag can be inspected.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), 110e6);
        assertEq(h.readOverSupplied(), 30e6, "over-cap borrow: flag += amount - maxLoan = 30e6");

        // Repay 10e6. actualPaid = 10e6 -> flag -= 10e6 = 20e6.
        usdc.mint(address(h), 10e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), 10e6);

        // Flag must be LOWERED to 20e6 (30e6 - 10e6), never raised.
        assertEq(
            h.readOverSupplied(),
            20e6,
            "partial repay: flag -= actualPaid -> 30e6 - 10e6 = 20e6, never raised"
        );
    }
}
