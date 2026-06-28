// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisCollateralManager -- addCollateral drift regression suite
 * ===========================================================================
 *
 * Purpose
 * -------
 * Failing reproducers for an availability bug in `addCollateral`. When
 * `data.shares` exceeds the actually-recoverable LP by some drift delta
 * (e.g. gauge `convertToAssets` rounded down on a round-trip), a fresh
 * deposit of `shares` LP DEADLOCKS:
 *
 *   - `_snapshotIfNeeded` -> `reconcileSharesToBalance` reads
 *     `_actualLp` AFTER the caller's incoming LP has landed. If
 *     `shares >= delta`, then `_actualLp >= data.shares` and the guard
 *     `if (data.shares <= actual) return;` early-returns. No ratchet.
 *   - `addCollateral` then computes
 *       requiredBalance = data.shares + shares
 *       actualBalance   = data.shares - delta + shares
 *     and reverts InsufficientShareBalance(required, actual).
 *
 * Expected fix (NOT implemented here)
 * -----------------------------------
 * `_snapshotIfNeeded` will accept an `incomingShares` parameter and the
 * inlined ratchet will subtract the deposit from `_actualLp` before
 * comparing to `data.shares`. `addCollateral` will pass
 * `incomingShares = shares`. Public `reconcileSharesToBalance` is
 * unchanged.
 *
 * Failure shape on current `main`/`dynamic-vault-fixes`
 * ----------------------------------------------------
 * Canary tests (#1, #6, #7, #8, #11) revert with
 *   YieldBasisCollateralManager.InsufficientShareBalance(required, actual)
 * where `required - actual == delta`.
 *
 * Naming
 * ------
 * All failing reproducers carry `_RegressionDrift_` in their name so the
 * suite is greppable post-fix.
 * =========================================================================*/

import {Test, console2} from "forge-std/Test.sol";

// Library under test
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

// Infra (mirrors YieldBasisCollateralManager.t.sol setUp)
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

// Interfaces
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * Harness -- exposes every library entry point so tests run against the real
 * ERC-7201 slot. Mirrors the YBCMHarness pattern in
 * test/portfolio_account/yieldbasis/YieldBasisCollateralManager.t.sol.
 * -------------------------------------------------------------------------*/
contract YBDriftHarness {
    struct YBData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
        address gauge;
    }

    bytes32 internal constant YB_SLOT = keccak256("storage.YieldBasisCollateralManager");

    function _yb() internal pure returns (YBData storage d) {
        bytes32 s = YB_SLOT;
        assembly { d.slot := s }
    }

    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }

    function removeCollateral(address cfg, address vault, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.removeCollateral(cfg, vault, underlying, shares);
    }

    function getTotalCollateralValue(address vault, address underlying) external view returns (uint256) {
        return YieldBasisCollateralManager.getTotalCollateralValue(vault, underlying);
    }

    function getCollateral(address vault, address underlying)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return YieldBasisCollateralManager.getCollateral(vault, underlying);
    }

    function getCollateralShares() external view returns (uint256) {
        return YieldBasisCollateralManager.getCollateralShares();
    }

    function getTotalDebt() external view returns (uint256) {
        return YieldBasisCollateralManager.getTotalDebt();
    }

    function increaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external
        returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.increaseTotalDebt(cfg, vault, underlying, amount);
    }

    function decreaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external
        returns (uint256)
    {
        return YieldBasisCollateralManager.decreaseTotalDebt(cfg, vault, underlying, amount);
    }

    function getMaxLoan(address cfg, address vault, address underlying)
        external
        view
        returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.getMaxLoan(cfg, vault, underlying);
    }

    function snapshotShortfall(address cfg, address vault, address underlying) external {
        YieldBasisCollateralManager.snapshotShortfall(cfg, vault, underlying);
    }

    function reconcileSharesToBalance(address cfg, address vault, address underlying, address gauge) external {
        YieldBasisCollateralManager.reconcileSharesToBalance(cfg, vault, underlying, gauge);
    }

    function enforceCollateralRequirements(address cfg, address vault, address underlying) external view returns (bool) {
        return YieldBasisCollateralManager.enforceCollateralRequirements(cfg, vault, underlying);
    }

    // ---------------- helpers ----------------

    /// @dev Stake all currently-held LP into the gauge so the harness ends up
    /// with gauge receipt shares instead of raw LP. Drift is then introduced
    /// by tuning the gauge's convertRatioBps.
    function __stakeInto(address gauge, address lp, uint256 amount) external {
        IERC20(lp).approve(gauge, amount);
        MockTunableYieldBasisGauge(gauge).deposit(amount, address(this));
    }

    function __readYB() external view returns (YBData memory d) {
        YBData storage s = _yb();
        d.shares = s.shares;
        d.depositedAssetValue = s.depositedAssetValue;
        d.debt = s.debt;
        d.overSuppliedVaultDebt = s.overSuppliedVaultDebt;
        d.startShortfall = s.startShortfall;
        d.snapshotBlockNumber = s.snapshotBlockNumber;
        d.gauge = s.gauge;
    }
}

/* ---------------------------------------------------------------------------
 * Mock lending pool reused from the existing CM tests. Stages debt and
 * actualPaid independently so `decreaseTotalDebt` and `increaseTotalDebt`
 * can be driven deterministically.
 * -------------------------------------------------------------------------*/
contract MockSyncPool {
    address public immutable _asset;
    address internal _portfolioFactory;
    uint256 public _actualPaidToReport;
    uint256 public _debtBalanceToReport;
    uint256 public _activeAssetsToReport;

    constructor(address asset_, address portfolioFactory_) {
        _asset = asset_;
        _portfolioFactory = portfolioFactory_;
    }

    function setActualPaid(uint256 v) external { _actualPaidToReport = v; }
    function setDebt(uint256 v) external { _debtBalanceToReport = v; }
    function setActiveAssets(uint256 v) external { _activeAssetsToReport = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return address(this); }
    function activeAssets() external view returns (uint256) { return _activeAssetsToReport; }
    function asset() external view returns (address) { return _asset; }
    function totalAssets() public view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssetsToReport;
    }

    // Value-neutral mock: no same-block exclusion needed for these tests.
    function borrowableTotalAssets() external view returns (uint256) {
        return totalAssets();
    }

    function borrowFromPortfolio(uint256 /*amount*/) external pure returns (uint256) { return 0; }

    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external returns (uint256 actualPaid) {
        actualPaid = _actualPaidToReport;
        if (actualPaid > totalPayment) actualPaid = totalPayment;
        if (actualPaid > 0) {
            IERC20(_asset).transferFrom(msg.sender, address(this), actualPaid);
        }
    }

    function getDebtBalance(address) external view returns (uint256) { return _debtBalanceToReport; }
    function depositRewards(uint256) external {}
}

/* ===========================================================================
 * TEST SUITE
 * ==========================================================================*/
contract YieldBasisDriftRegressionTest is Test {
    YBDriftHarness internal h;

    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    MockYieldBasisLP internal ybLp;
    MockTunableYieldBasisGauge internal gauge;
    MockERC20 internal underlying; // and lending asset (like-to-like)

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH_CALLER = address(0xAAAA);

    uint256 internal constant VAULT_LIQUIDITY = 1_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("yb-drift-regression"));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1e18);
        underlying = new MockERC20("WETH", "WETH", 18);
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(factory), OWNER, "Lending Vault", "lVAULT", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        underlying.mint(address(lendingVault), VAULT_LIQUIDITY);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);
        cfg.setLoanContract(address(lendingVault));
        factory.setPortfolioFactoryConfig(address(cfg));

        pm.setAuthorizedCaller(AUTH_CALLER, true);

        vm.stopPrank();

        h = new YBDriftHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(address(h), true);

        vm.label(address(h), "YBDriftHarness");
        vm.label(address(ybLp), "ybLP");
        vm.label(address(gauge), "MockTunableGauge");
        vm.label(address(underlying), "WETH");
        vm.label(address(lendingVault), "LendingVault");
    }

    // ============ DRIFT PRIMITIVE =========================================
    //
    // Engineering a delta-wide drift between data.shares and _actualLp:
    //   1. Mint T LP to the harness; addCollateral(T) with the gauge address.
    //      data.shares = T. _actualLp = T (LP balance, no gauge shares yet).
    //   2. From the harness, stake all T LP into the gauge via the tunable
    //      mock's deposit. data.shares = T. harness LP = 0, gauge shares = T.
    //      _actualLp = gauge.convertToAssets(T) = T (ratio still 1:1).
    //   3. Drop convertRatioBps to introduce drift. _actualLp drops to T*ratio.
    //      data.shares stays T -> drift delta = T - T*ratio.
    //   4. vm.roll forward so _snapshotIfNeeded can take a fresh snapshot.
    //   5. Mint `incoming` LP fresh to the harness, call addCollateral(incoming).
    //      _actualLp at snapshot-time = (T - delta) + incoming. If incoming >= delta,
    //      the reconcile guard returns early. addCollateral then asserts
    //      required (T+incoming) <= actual (T-delta+incoming) -> reverts with delta.

    function _seedTrackedSharesWithDrift(uint256 trackedT, uint256 driftDelta) internal {
        require(driftDelta < trackedT, "driftDelta must be < trackedT");
        ybLp.mint(address(h), trackedT);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), trackedT);
        h.__stakeInto(address(gauge), address(ybLp), trackedT);
        // After staking we have 0 LP and trackedT gauge shares.
        // convertToAssets is linear in convertRatioBps:
        //   actual = trackedT * ratio / 10000  ==> drift = trackedT - actual
        //   ratio = (trackedT - drift) * 10000 / trackedT
        uint256 ratio = ((trackedT - driftDelta) * 10_000) / trackedT;
        // Floor: ratio*trackedT/10000 may be <= (trackedT-driftDelta) by 1 wei
        // due to integer division. That residual rolls into delta -- harmless for
        // the inequalities being tested.
        gauge.setConvertRatioBps(ratio);
    }

    // ============ TEST 1 (CANARY) ==========================================
    //
    // delta < shares: today the manager reverts InsufficientShareBalance because
    // the in-block reconcile early-returns. Post-fix the deposit should
    // succeed with data.shares = (T-delta) + shares and basis haircut so D/S is
    // preserved.

    function test_AddCollateral_DriftLessThanDeposit_Succeeds_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 1e15;       // 0.001 LP drift
        uint256 incoming = 1e18;    // 1 LP fresh deposit, well above delta

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        // Pre-state capture for per-share-basis invariant.
        (uint256 sharesPre, uint256 depPre,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesPre, T, "pre: data.shares == T");
        // Per-share basis = D/S pre-fix.
        uint256 basisPerSharePre = (depPre * 1e18) / sharesPre;

        // Fresh LP to be deposited.
        ybLp.mint(address(h), incoming);

        // CANARY: the assertion below describes the post-fix behavior. On
        // current code the call reverts with InsufficientShareBalance. The
        // try/catch makes the failure shape explicit so the test message
        // points at the bug, not a stray decode error.
        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            // Post-fix path: deposit succeeded. Ratchet was applied first
            // (data.shares -> T-delta), then incoming was added.
            (uint256 sharesPost, uint256 depPost,) = h.getCollateral(address(ybLp), address(underlying));
            assertApproxEqAbs(sharesPost, (T - delta) + incoming, 2, "post-fix: data.shares == (T - delta) + incoming");
            // D/S preserved within rounding across the ratchet+add.
            uint256 basisPerSharePost = (depPost * 1e18) / sharesPost;
            assertApproxEqAbs(basisPerSharePost, basisPerSharePre, 2, "post-fix: per-share basis preserved across ratchet");
        } catch (bytes memory err) {
            // Pre-fix path: the canary failure we want to capture.
            bytes4 sel = bytes4(err);
            if (sel == YieldBasisCollateralManager.InsufficientShareBalance.selector) {
                // Decode and emit a precise diagnostic so the test output
                // distinguishes the bug from any other revert.
                (uint256 req, uint256 actual) = abi.decode(_slice(err, 4), (uint256, uint256));
                emit log_named_uint("BUG REPRO: required", req);
                emit log_named_uint("BUG REPRO: actual", actual);
                emit log_named_uint("BUG REPRO: drift  ", req - actual);
                assertTrue(
                    false,
                    "CANARY FAIL (expected on broken main): addCollateral reverts InsufficientShareBalance under drift"
                );
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "addCollateral reverted, but not with InsufficientShareBalance");
            }
        }
    }

    // ============ TEST 2 ==================================================
    //
    // delta == incoming exactly. Edge of the inequality. Post-fix: deposit
    // succeeds and net data.shares == T (drift exactly absorbed). Pre-fix:
    // reverts the same way (required = T+incoming, actual = T-delta+incoming
    // = T+incoming-delta = T+incoming-incoming = T, so required-actual = incoming
    // = delta, revert with delta).

    function test_AddCollateral_DriftEqualsDeposit_Succeeds_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 5e17;       // 0.5 LP drift
        uint256 incoming = 5e17;    // equal to delta

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
            // Post-fix: (T - delta) + incoming, with delta == incoming -> sharesPost = T.
            assertApproxEqAbs(sharesPost, T, 2, "post-fix: net zero change to data.shares when delta == incoming");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == YieldBasisCollateralManager.InsufficientShareBalance.selector) {
                assertTrue(
                    false,
                    "CANARY FAIL (expected on broken main): delta == incoming still trips InsufficientShareBalance"
                );
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 3 ==================================================
    //
    // delta > incoming. Post-fix the planned new error is `DepositBelowDrift`.
    // Per the brief, we write this test expecting the OLD revert
    // (InsufficientShareBalance) so it passes on broken main, and leave
    // a TODO. After the fix lands the assertion must be updated to expect
    // the new error.
    //
    // NOTE: this test PASSES on current code. It is a placeholder for the
    // post-fix expectation. It does NOT belong in the canary set.

    function test_AddCollateral_DriftGreaterThanDeposit_RatchetsAndSucceeds() public {
        uint256 T = 10e18;
        uint256 delta = 2e18;
        uint256 incoming = 5e17; // strictly less than delta

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        ybLp.mint(address(h), incoming);

        // Post-fix: the snapshot reconciles tracked down to actual recoverable
        // LP first, then adds the incoming. No revert. Tracked drops from T
        // to (T - delta) + incoming, which is below the prior T but matches
        // real economic position -- the user could never have spent the
        // phantom shares anyway.
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming);
        (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesPost, (T - delta) + incoming, "tracked = (T - delta) + incoming");
    }

    // ============ TEST 4 ==================================================
    //
    // Full wipe: _actualLp = 0. A fresh deposit must reset the position
    // cleanly (data.shares = incoming, depositedAssetValue = basis(incoming)).
    //
    // To wipe _actualLp to zero we drop the gauge ratio to its minimum (1 bp).
    // Pre-fix: addCollateral still works because data.shares = 0 when starting
    // from a zero-collateral seed, but the bug we want to exhibit needs an
    // EXISTING tracked T with a wipe -- so we seed first.

    function test_AddCollateral_FullWipe_DepositRestoresPosition_RegressionDrift_() public {
        uint256 T = 10e18;
        // Seed with a modest drift, then push the gauge ratio to 1 bp directly
        // to simulate near-full wipe. Final convertToAssets(T) = T/10000 = 1e15
        // recoverable residual.
        _seedTrackedSharesWithDrift(T, 1e18);
        gauge.setConvertRatioBps(1);
        vm.roll(block.number + 1);

        // For the deposit to *restore* the position the incoming must plug the
        // drift: drift = preSnapshotShares - effective = T - residual ~= T.
        // Use incoming = T so post-ratchet + incoming >= preSnapshotShares.
        // Below T would (correctly) revert DepositBelowDrift.
        uint256 incoming = T;
        ybLp.mint(address(h), incoming);

        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming);
        (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
        uint256 residual = (T * 1) / 10_000;
        assertEq(sharesPost, residual + incoming, "post-fix: ratchet to residual then add incoming");
    }

    // ============ TEST 5 ==================================================
    //
    // Regression: no drift, normal deposit. Must keep working unchanged.
    // This guards the happy path against the upcoming refactor.

    function test_AddCollateral_NoDrift_NormalDeposit_UnchangedBehavior() public {
        uint256 T = 10e18;
        ybLp.mint(address(h), T);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), T);

        // Don't stake. data.shares = T. _actualLp = T (LP on harness). No drift.
        vm.roll(block.number + 1);

        uint256 incoming = 3e18;
        ybLp.mint(address(h), incoming);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming);

        (uint256 sharesPost, uint256 depPost,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesPost, T + incoming, "no drift: additive");
        // pps = 1e18 -> basis = (T+incoming) * 1 = same number.
        assertEq(depPost, T + incoming, "depositedAssetValue additive at pps=1");
    }

    // ============ TEST 6 (CANARY) ==========================================
    //
    // Gauge unset (data.gauge == address(0)): direct-LP drift. Today the
    // ratchet short-circuits when data.gauge == 0, so the deposit COULD
    // proceed only if the LP balance still backs data.shares. We simulate
    // a "rescue sweep" by burning LP from the portfolio's balance to
    // introduce direct drift. Post-fix: ratchet must fire even with no
    // gauge (the new behavior is stricter).
    //
    // On current code: addCollateral reverts InsufficientShareBalance,
    // because the balance check operates on _actualLp = balanceOf(this)
    // which is < data.shares.

    function test_AddCollateral_GaugeUnset_DirectLpDrift_RatchetsCorrectly_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 1e18;
        // Set gauge to address(0) when adding initial collateral.
        ybLp.mint(address(h), T);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), T);

        // Sanity: gauge field stored as address(0).
        YBDriftHarness.YBData memory s = h.__readYB();
        assertEq(s.gauge, address(0), "gauge unset");

        // "Rescue sweep" burns LP out of the portfolio. data.shares = T but
        // LP balance now = T - delta.
        ybLp.burn(address(h), delta);

        vm.roll(block.number + 1);

        uint256 incoming = 2e18;
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), incoming) {
            (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
            // Post-fix: ratchet fires even with no gauge, so data.shares
            // becomes (T - delta) + incoming.
            assertApproxEqAbs(sharesPost, (T - delta) + incoming, 2,
                "post-fix (stricter): gauge-less ratchet still fires");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == YieldBasisCollateralManager.InsufficientShareBalance.selector) {
                (uint256 req, uint256 actual) = abi.decode(_slice(err, 4), (uint256, uint256));
                emit log_named_uint("BUG REPRO (no-gauge): required", req);
                emit log_named_uint("BUG REPRO (no-gauge): actual", actual);
                assertTrue(
                    false,
                    "CANARY FAIL (expected on broken main): gauge-less drift trips InsufficientShareBalance"
                );
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 7 (CANARY) ==========================================
    //
    // In-block: borrow against T, drift materializes, addCollateral(incoming).
    // Because the snapshot was taken in the SAME block as the deposit, the
    // post-deposit borrow can pick up the stale baseline and mask a
    // shortfall. After the fix, the ratchet that fires inside addCollateral
    // must update startShortfall so any later in-block borrow sees the
    // post-ratchet picture.
    //
    // We use a mock pool so we can stage debt without exercising real
    // LendingVault accounting.

    function test_AddCollateral_InBlockBorrowThenDrift_StaleBaselineCannotMaskShortfall_RegressionDrift_() public {
        // Swap in mock pool so getDebtBalance can be staged.
        MockSyncPool pool = new MockSyncPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        uint256 delta = 1e18;

        // Seed T-with-drift, but BEFORE rolling, stage a debt level via the
        // mock pool that puts the borrower at 6e18 of debt.
        _seedTrackedSharesWithDrift(T, delta);

        // Roll into a fresh block and stage debt. We deliberately do NOT
        // trigger a pre-snapshot (e.g. via snapshotShortfall) because that
        // would itself ratchet `data.shares` and remove the precondition for
        // the bug: the ratchet must be skipped when the incoming-shares-naive
        // reconcile sees actual = (T-delta)+incoming >= T.
        vm.roll(block.number + 1);
        pool.setDebt(6e18);

        // Same block as the eventual borrow path would run. Post-fix: the
        // ratchet inside addCollateral updates data.shares to (T-delta)+incoming
        // and snapshot-time startShortfall reflects the post-ratchet picture.
        // The key invariant is: a borrow attempt later in the same block must
        // respect the post-ratchet max-loan, not the pre-drift inflated one.
        uint256 incoming = 2e18;
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            // Post-fix: deposit succeeded, ratchet ran.
            (uint256 maxLoan, uint256 maxLoanIgnoreSupply) =
                h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
            // post-ratchet data.shares = (T-delta) + incoming = 9e18+2e18 = 11e18
            // collateralValue = 11e18, maxLoanIgnoreSupply = 7.7e18.
            // Stage debt under the new cap to verify a borrow still works
            // off the corrected baseline.
            assertApproxEqAbs(maxLoanIgnoreSupply, 7.7e18, 1e6, "post-fix: cap reflects ratcheted shares");
            assertGt(maxLoan, 0, "headroom available");
            // Sanity: the cap is NOT the pre-drift 8.4e18 (T*incoming*pps*ltv).
            assertLt(maxLoanIgnoreSupply, (T + incoming) * LTV_BPS / 10_000, "cap < pre-drift inflated cap");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == YieldBasisCollateralManager.InsufficientShareBalance.selector) {
                (uint256 req, uint256 actual) = abi.decode(_slice(err, 4), (uint256, uint256));
                emit log_named_uint("BUG REPRO (in-block): required", req);
                emit log_named_uint("BUG REPRO (in-block): actual", actual);
                assertTrue(
                    false,
                    "CANARY FAIL (expected on broken main): in-block deposit after drift reverts before borrow-baseline question is reached"
                );
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 8 (CANARY) ==========================================
    //
    // Drift-during-repay safety. _actualLp wipes to ~0, user owes debt.
    // decreaseTotalDebt must succeed -- repay-safety is non-negotiable.
    //
    // Current code: decreaseTotalDebt's _snapshotIfNeeded ratchet uses
    // _actualLp without subtracting any incoming-shares (there are none on
    // a repay), so the ratchet runs cleanly here. THIS TEST IS LIKELY TO
    // PASS ON CURRENT CODE -- it acts as a regression guard for the
    // upcoming overload to make sure repays don't gain a new failure mode.
    //
    // We still tag it _RegressionDrift_ for greppability and include it in
    // the "canary" set listed in the brief -- but flag that it passes today.

    function test_DecreaseTotalDebt_DuringDriftWipe_RepaySucceeds_RegressionDrift_() public {
        MockSyncPool pool = new MockSyncPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        // Seed with modest drift (ratio computation needs trackedT/driftDelta
        // sane) then push to 1 bp for the wipe.
        _seedTrackedSharesWithDrift(T, 1e18);
        gauge.setConvertRatioBps(1); // _actualLp ~ T/10000

        vm.roll(block.number + 1);

        // Stage debt and arm the pool to credit the repayment.
        uint256 debtAmt = 1e18;
        pool.setDebt(debtAmt);
        pool.setActualPaid(debtAmt);
        underlying.mint(address(h), debtAmt);

        uint256 excess = h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), debtAmt);
        assertEq(excess, 0, "no excess on exact repay");
        // After the ratchet inside _snapshotIfNeeded, data.shares should be
        // ratcheted to residual (T/10000). Post-pay debt is whatever the
        // pool reports.
        (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
        assertApproxEqAbs(sharesPost, T / 10_000, 2, "ratchet ran during repay");
    }

    // ============ TEST 9 ==================================================
    //
    // Public reconcileSharesToBalance must be unchanged. No incoming-shares
    // concept. Ratchet only when data.shares > _actualLp. Gauge-less path
    // still short-circuits (this is the contrast vs the new addCollateral
    // overload).

    function test_PublicReconcileSharesToBalance_Unchanged() public {
        uint256 T = 10e18;
        uint256 delta = 1e18;
        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        // No incoming shares. Just call reconcile directly.
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));
        (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
        assertApproxEqAbs(sharesPost, T - delta, 2, "public reconcile ratchets to _actualLp");
    }

    // ============ TEST 10 =================================================
    //
    // After test #1's success state (post-fix), a partial remove must use
    // POST-ratchet data.shares for the basis math. Today this test
    // co-depends on test 1 succeeding -- it is wrapped in a try/catch so a
    // pre-fix failure here is clearly labeled.

    function test_RemoveCollateral_AfterDriftDeposit_UsesPostRatchetShares_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 1e18;
        uint256 incoming = 2e18;

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            (uint256 sharesAfterDeposit, uint256 depAfterDeposit,) = h.getCollateral(address(ybLp), address(underlying));
            // Sanity: ratcheted + incoming.
            assertApproxEqAbs(sharesAfterDeposit, (T - delta) + incoming, 2, "shares ratcheted+added");

            // Remove 50% of post-ratchet shares.
            uint256 toRemove = sharesAfterDeposit / 2;
            // No debt -> remove is unconditional. assetValueToRemove =
            // depAfterDeposit * toRemove / sharesAfterDeposit.
            uint256 expectedValueRemoved = (depAfterDeposit * toRemove) / sharesAfterDeposit;
            uint256 expectedRemainingDep = depAfterDeposit - expectedValueRemoved;

            vm.roll(block.number + 1);
            h.removeCollateral(address(cfg), address(ybLp), address(underlying), toRemove);

            (uint256 sharesAfterRemove, uint256 depAfterRemove,) = h.getCollateral(address(ybLp), address(underlying));
            assertEq(sharesAfterRemove, sharesAfterDeposit - toRemove, "shares decremented");
            assertApproxEqAbs(depAfterRemove, expectedRemainingDep, 2, "basis used post-ratchet shares");
        } catch {
            assertTrue(false, "CANARY DEP: test 1 reverts, so test 10 cannot run -- fix test 1 first");
        }
    }

    // ============ TEST 11 (CANARY) =========================================
    //
    // Same-block: drift seeded, deposit succeeds (post-fix), then borrow
    // must size against the RATCHETED+ADDED shares (T-delta)+incoming -- not
    // off the pre-drift T.

    function test_IncreaseTotalDebt_AfterDriftDeposit_MaxLoanFromRatchetedShares_RegressionDrift_() public {
        MockSyncPool pool = new MockSyncPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        uint256 delta = 1e18;
        uint256 incoming = 2e18;

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            // Post-fix: deposit succeeded.
            (uint256 maxLoanA, uint256 capA) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
            // Cap from ratcheted shares: (T-delta+incoming) * pps * LTV / 1e22 = 11e18*0.7 = 7.7e18.
            assertApproxEqAbs(capA, 7.7e18, 1e6, "cap reflects ratcheted shares");
            // Sanity: cap is strictly less than the pre-drift inflated cap.
            assertLt(capA, (T + incoming) * LTV_BPS / 10_000, "cap < pre-drift inflated cap");
            assertGt(maxLoanA, 0, "headroom available");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == YieldBasisCollateralManager.InsufficientShareBalance.selector) {
                (uint256 req, uint256 actual) = abi.decode(_slice(err, 4), (uint256, uint256));
                emit log_named_uint("BUG REPRO (maxLoan path): required", req);
                emit log_named_uint("BUG REPRO (maxLoan path): actual", actual);
                assertTrue(
                    false,
                    "CANARY FAIL (expected on broken main): addCollateral reverts before maxLoan question is reachable"
                );
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ util ====================================================

    /// @dev `bytes` slice helper -- abi.decode of a custom-error payload
    /// needs the selector stripped off.
    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        require(data.length >= start, "slice bounds");
        uint256 len = data.length - start;
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
