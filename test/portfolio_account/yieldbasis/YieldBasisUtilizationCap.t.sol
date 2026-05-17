// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisUtilizationCap
 *
 * Issue Summary
 * -------------
 * Utilization-cap enforcement moved off the vault and onto the manager-side
 * `overSuppliedVaultDebt` flag. The vault no longer reverts on over-cap
 * borrows; instead `_recomputeOverSupplied` runs after each debt mutation
 * and stores `activeAssets - cap` (when positive) so
 * `enforceCollateralRequirements()` reverts with BadDebt at end of multicall.
 *
 * The single source of truth for the cap is `LoanConfig.maxUtilizationBps`,
 * which falls back to 8000 when unset. The manager reads it on every borrow
 * AND every quote.
 *
 * Why these tests are load-bearing
 * --------------------------------
 * `_recomputeOverSupplied` is the YB lending stack's ONLY borrow-time
 * utilization protection now. If a refactor reverts to hardcoded 8000 or
 * stops reading `loanConfig.getMaxUtilizationBps()`, the protocol can no
 * longer raise the cap to 9500 (the user-stated motivation) without redeploy.
 * These tests pin the cap-from-LoanConfig wiring and the post-state flag math.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 *  Harness: exposes the library through external entry points; owns the
 *  ERC-7201 slot keccak256("storage.YieldBasisCollateralManager").
 * -------------------------------------------------------------------------*/
contract YBUtilHarness {
    function increaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.increaseTotalDebt(cfg, vault, underlying, amount);
    }
    function decreaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external returns (uint256)
    {
        return YieldBasisCollateralManager.decreaseTotalDebt(cfg, vault, underlying, amount);
    }
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }
    function enforceCollateralRequirements(address cfg, address vault, address underlying) external view returns (bool) {
        return YieldBasisCollateralManager.enforceCollateralRequirements(cfg, vault, underlying);
    }
    function getMaxLoan(address cfg, address vault, address underlying) external view returns (uint256, uint256) {
        return YieldBasisCollateralManager.getMaxLoan(cfg, vault, underlying);
    }

    // Storage probes (raw slot reads to avoid leaning on library getters).
    struct YBData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
    }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 slot = keccak256("storage.YieldBasisCollateralManager");
        assembly { v := sload(add(slot, 3)) } // 4th word = overSuppliedVaultDebt
    }
}

/* ---------------------------------------------------------------------------
 *  Mock lending pool that satisfies BOTH ILendingPool and ILendingVault enough
 *  for the manager. Active assets and totalAssets are independently settable
 *  so we can stage any global utilization state pre-borrow.
 * -------------------------------------------------------------------------*/
contract MockUtilPool {
    IERC20 public immutable assetToken;
    address public immutable portfolioFactory;
    uint256 public _activeAssets;
    uint256 public _totalAssets;
    mapping(address => uint256) public debt;

    constructor(address asset_, address factory_) {
        assetToken = IERC20(asset_);
        portfolioFactory = factory_;
    }

    // --- ILendingPool ---
    function borrowFromPortfolio(uint256 amount) external returns (uint256 originationFee) {
        debt[msg.sender] += amount;
        _activeAssets += amount;
        // No transfer required for these tests -- the manager records debt against the pool
        // but if the asset balance underflows the test mints into the harness as needed.
        if (assetToken.balanceOf(address(this)) >= amount) {
            assetToken.transfer(msg.sender, amount);
        }
        return 0;
    }
    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external returns (uint256 actualPaid) {
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
    function getDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function getEffectiveDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function depositRewards(uint256) external {}

    // --- ILendingVault slice used by manager ---
    function totalAssets() external view returns (uint256) { return _totalAssets; }
    function asset() external view returns (address) { return address(assetToken); }
    function decimals() external pure returns (uint8) { return 18; }

    // --- For setLoanContract validation ---
    function getPortfolioFactory() external view returns (address) { return portfolioFactory; }

    // --- test helpers ---
    function setActive(uint256 v) external { _activeAssets = v; }
    function setTotal(uint256 v) external { _totalAssets = v; }
}

/* ===========================================================================
 *  Tests
 * =========================================================================*/
contract YieldBasisUtilizationCapTest is Test {
    YBUtilHarness internal h;
    MockUtilPool internal pool;
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    MockERC20 internal usdc;
    MockYieldBasisLP internal ybLp;
    MockERC20 internal underlying; // same as lending asset for like-to-like LTV path

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, ) = pm.deployFactory(keccak256("yb-utilcap-test"));
        factory = f;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        usdc = new MockERC20("WETH18", "WETH18", 18);
        underlying = usdc; // like-to-like
        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1e18);

        pool = new MockUtilPool(address(usdc), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // Use LTV path -- like-to-like: lendingAsset == underlying.
        loanConfig.setLtv(7000); // 70%
        loanConfig.setMultiplier(7000);
        // Leave maxUtilizationBps unset -- defaults to 8000.

        vm.stopPrank();

        h = new YBUtilHarness();
        // The library checks msg.sender inside its delegatecall context, which is the
        // caller of the harness external function. We authorize AUTH so AUTH can call
        // the harness through vm.prank and pass the gate.
        vm.prank(OWNER);
        pm.setAuthorizedCaller(AUTH, true);

        vm.label(address(h), "YBUtilHarness");
        vm.label(address(pool), "MockUtilPool");
    }

    /* ---------------------------------------------------------------
     * Helpers
     * --------------------------------------------------------------- */

    function _stageCollateral(uint256 shares) internal {
        ybLp.mint(address(h), shares);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), shares);
    }

    function _setCap(uint256 bps) internal {
        vm.prank(OWNER);
        loanConfig.setMaxUtilizationBps(bps);
    }

    /* ---------------------------------------------------------------
     * Section 1: cap-respecting borrow keeps flag at zero
     * --------------------------------------------------------------- */

    /// @notice With cap 8000 and post-borrow activeAssets below cap,
    /// `_recomputeOverSupplied` MUST leave the flag at zero. The borrow
    /// is well-collateralized so no other flag fires either.
    function test_borrowUnderCap_flagStaysZero() public {
        // totalAssets = 1000e18, cap 8000 -> capValue 800e18.
        pool.setTotal(1000e18);
        usdc.mint(address(pool), 1000e18);

        // Plenty of collateral (10e18 LP @ pps=1e18 = 10e18 value; LTV 70% = 7e18 max).
        _stageCollateral(10e18);

        // Borrow 5e18: activeAssets = 5e18 < cap 800e18, debt 5e18 < maxLoan 7e18.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e18);

        assertEq(h.readOverSupplied(), 0, "flag must be 0 when active <= cap");
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)));
    }

    /* ---------------------------------------------------------------
     * Section 2: over-cap borrow flags the exact excess
     * --------------------------------------------------------------- */

    /// @notice Vault no longer reverts on over-cap. The borrow goes through;
    /// the flag carries the exact (activeAssets - cap) excess, and
    /// `enforceCollateralRequirements()` reverts with BadDebt(excess).
    function test_borrowOverCap_flagEqualsExcess_revertsBadDebt() public {
        // totalAssets = 100e18, cap 8000 -> capValue 80e18.
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);

        // Lots of collateral so the collateral-side guards do NOT trip first.
        _stageCollateral(1000e18); // LTV 70% -> maxLoan 700e18 (cash math) ignoring supply.

        // Borrow 90e18: post-state activeAssets = 90e18 > cap 80e18.
        // Expected flag = 10e18.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 90e18);

        assertEq(h.readOverSupplied(), 10e18, "flag = active - cap");

        // Cross a block so the intra-block shortfall snapshot does not fire
        // (it would also revert, but we are isolating the BadDebt branch).
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(YieldBasisCollateralManager.BadDebt.selector, uint256(10e18)));
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    /* ---------------------------------------------------------------
     * Section 3: repay clears the flag
     * --------------------------------------------------------------- */

    /// @notice After an over-cap borrow staged the flag, repaying enough
    /// to bring activeAssets back under the cap MUST clear the flag.
    /// The post-state recompute is the only place this can happen.
    function test_repayClearsFlag() public {
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 90e18);
        assertEq(h.readOverSupplied(), 10e18, "flag set after over-cap borrow");

        // Fund the harness so it can transferFrom into the pool.
        usdc.mint(address(h), 20e18);

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 20e18);

        // active = 90 - 20 = 70 < cap 80 -> flag must clear.
        assertEq(h.readOverSupplied(), 0, "flag must clear when active <= cap");
    }

    /* ---------------------------------------------------------------
     * Section 4: raising cap unlocks a borrow that would have flagged
     * --------------------------------------------------------------- */

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Reflects the user-stated motivation: "when we update our Vault possibly
    /// we can set the cap a bit higher". With totalAssets=100e18 and a 90e18
    /// borrow, the flag is set at cap 8000 (cap=80e18, excess=10e18) but
    /// MUST be clear at cap 9500 (cap=95e18, no excess). If a refactor pins
    /// the cap to a hardcoded value or stops reading the LoanConfig, this
    /// test fails. Removing this test is not coverage cleanup.
    function test_YieldBasis_RaisingCapUnlocksBorrow_DoNotRemove() public {
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // ---- At default cap (8000 via LoanConfig fallback; storage left unset).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 90e18);
        uint256 flagAtDefault = h.readOverSupplied();
        assertEq(flagAtDefault, 10e18, "default cap 8000: 90e18 borrow exceeds 80e18 cap by 10e18");

        // Wipe the borrow state to set up the cap-9500 trial cleanly.
        usdc.mint(address(h), 90e18);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 90e18);
        assertEq(h.readOverSupplied(), 0, "flag cleared after repay");

        // ---- At cap 9500: same 90e18 borrow now sits under cap (95e18) -> no flag.
        _setCap(9500);
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 90e18);
        assertEq(h.readOverSupplied(), 0, "at cap 9500: 90e18 borrow within 95e18 cap, flag must be 0");

        // And enforcement passes after rolling to a new block.
        vm.roll(block.number + 1);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)));
    }

    /* ---------------------------------------------------------------
     * Section 5: vault no longer reverts on over-cap
     * --------------------------------------------------------------- */

    /// @notice The vault used to revert with ExceedsUtilization at cap+1. After
    /// the refactor, borrowFromPortfolio MUST succeed at any utilization; only
    /// the manager-side flag carries the excess. This test would catch a
    /// regression that re-introduces vault-side cap enforcement.
    function test_vaultNoLongerRevertsOnOverCap() public {
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // Default cap of 8000 via LoanConfig fallback; storage left unset.
        // cap=80e18. Borrow exactly cap+1 wei. Pre-refactor this reverted at the
        // vault level. Post-refactor it succeeds and flags 1 wei.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 80e18 + 1);

        assertEq(h.readOverSupplied(), 1, "cap+1 wei borrow flags exactly 1 wei");
    }

    /* ---------------------------------------------------------------
     * Section 6: zero-totalAssets pool -- any positive active flags FULL excess
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

        // Stage collateral so collateral-side guards do not trip first.
        _stageCollateral(1000e18);

        // 1 wei borrow. activeAssets = 1, cap = 0 -> flag = 1.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1);

        assertEq(h.readOverSupplied(), 1, "1 wei borrow into zero-totalAssets pool flags 1 wei");

        // Cross a block so the intra-block snapshot does not also fire.
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(YieldBasisCollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    /* ---------------------------------------------------------------
     * Section 7: boundary around the cap (cap-1, cap, cap+1)
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
    /// strict-greater-than comparison in `_recomputeOverSupplied`.
    function test_YieldBasis_BoundaryAroundCap_NoFlagSet_DoNotRemove() public {
        // totalAssets = 100e18, cap 8000 bps -> cap = 80e18.
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // ---- cap - 1: under cap, flag stays 0.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 80e18 - 1);
        assertEq(h.readOverSupplied(), 0, "cap - 1: flag must be 0");
        vm.roll(block.number + 1);
        assertTrue(
            h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)),
            "cap - 1: enforcement passes"
        );

        // Repay back to zero to set up the exact-cap trial cleanly.
        usdc.mint(address(h), 80e18 - 1);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 80e18 - 1);
        assertEq(h.readOverSupplied(), 0, "post-repay flag back to 0");

        // ---- exact cap: strict `>` -- flag stays 0, enforcement passes.
        // This is the behavior-change pin: legacy vault used `>=` and reverted here.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 80e18);
        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");
        vm.roll(block.number + 1);
        assertTrue(
            h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)),
            "exact cap: enforcement passes"
        );

        // ---- cap + 1: flag = 1.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1);
        assertEq(h.readOverSupplied(), 1, "cap + 1: flag = exactly 1 wei");

        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(YieldBasisCollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Behavior change vs. legacy vault enforcement which used >= and
    /// reverted at exact cap. Removing this test would silently lose
    /// the boundary documentation. Pins the strict-greater-than
    /// comparison: activeAssets == cap MUST leave the flag at 0 and
    /// enforcement MUST pass.
    function test_YieldBasis_BorrowAtExactCap_NoFlagSet_DoNotRemove() public {
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // Borrow exactly cap (80e18 at 8000 bps).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 80e18);

        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");

        vm.roll(block.number + 1);
        assertTrue(
            h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)),
            "exact cap: enforcement passes"
        );
    }

    /* ---------------------------------------------------------------
     * Section 8: repay-never-reverts invariant (BUG REGRESSION)
     *
     * Pre-fix, `_recomputeOverSupplied` (called from the repay path) set
     * `overSuppliedVaultDebt = max(activeAssets - cap, 0)` absolutely. If
     * external state (another borrower's debt, or vesting shrinking
     * totalAssets) had already pushed the pool over cap, a clean borrower
     * making a legitimate repay would have the global excess pinned to THEM
     * and `enforceCollateralRequirements()` would revert -- blocking the
     * repay.
     *
     * Post-fix, the repay path uses `_clampDownOverSupplied` which only
     * lowers the flag -- never raises it.
     * --------------------------------------------------------------- */

    /// @notice Regression for the repay-never-reverts invariant. External
    /// over-cap state must not be attributed to a borrower who is merely
    /// repaying. Without the clamp-down in `_clampDownOverSupplied`, a repay
    /// during this state would raise the flag and revert.
    function test_YieldBasisCollateralManager_RepayWhenPoolExternallyOverCap_FlagNotRaised_DoNotRemove() public {
        // totalAssets = 100e18, cap 8000 bps -> cap = 80e18.
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // 1) Borrower starts clean.
        assertEq(h.readOverSupplied(), 0, "precondition: flag is 0");

        // 2) Small debt to repay (10e18 << cap 80e18).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 10e18);
        assertEq(h.readOverSupplied(), 0, "small borrow under cap: flag still 0");

        // 3) External state pushes pool over cap. active = 120e18 > cap = 80e18,
        //    excess = 40e18 attributable to "someone else".
        pool.setActive(120e18);

        // 4) Borrower repays a portion.
        usdc.mint(address(h), 5e18);

        vm.roll(block.number + 1);

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e18);

        // 5) Flag MUST still be 0. Clamp-down only LOWERS the flag.
        assertEq(
            h.readOverSupplied(),
            0,
            "repay must not RAISE the supply flag from external over-cap state"
        );

        // 6) Enforcement must NOT revert.
        vm.roll(block.number + 1);
        assertTrue(
            h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)),
            "enforce must pass after legitimate repay"
        );
    }

    /// @notice Paired test: partial-clear case. Under the new per-borrower
    /// semantics, the supply flag is accumulated by `+=` on over-cap borrows
    /// and decremented by `-= actualPaid` on repays. So after a 110e18 borrow
    /// (maxLoan = 80e18, flag += 30e18) and a 10e18 repay (flag -= 10e18),
    /// the flag must read 20e18 -- the original excess minus what was actually
    /// paid down. The flag must NEVER be raised by a repay.
    function test_YieldBasisCollateralManager_RepayPartialClear_FlagLoweredToNewExcess_DoNotRemove() public {
        // totalAssets = 100e18, cap = 80e18.
        pool.setTotal(100e18);
        usdc.mint(address(pool), 100e18);
        _stageCollateral(1000e18);

        // Borrower's own borrow pushes pool over cap: borrow 110e18,
        // active=110e18, cap=80e18 -> flag = 30e18.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 110e18);
        assertEq(h.readOverSupplied(), 30e18, "borrow over cap: flag = active - cap = 30e18");

        // Repay 10e18. active = 110 - 10 = 100; still > cap 80; new excess = 20e18.
        usdc.mint(address(h), 10e18);

        vm.roll(block.number + 1);

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 10e18);

        // Flag must be LOWERED to 20e18 (30e18 - 10e18), never raised.
        assertEq(
            h.readOverSupplied(),
            20e18,
            "partial repay: flag -= actualPaid -> 30e18 - 10e18 = 20e18, never raised"
        );
    }
}
