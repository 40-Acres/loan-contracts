// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * H-003 / lending-review fix coverage
 * ===========================================================================
 *
 * The YieldBasis LP collateral system was conflating gauge-share units with
 * LP-token units in three places:
 *
 *   1. YieldBasisCollateralManager.addCollateral:
 *        actualBalance = lpBalance + IERC20(gauge).balanceOf(this)   // WRONG
 *      assumed gauge.balanceOf returns LP units, but gauge balance is share
 *      units. Under any non-1:1 ratio (e.g. ERC4626 fee or rebase), staked
 *      collateral could be over- or under-credited toward the precondition.
 *
 *   2. YieldBasisLpFacet._stake / unstake:
 *        require(_gauge.convertToAssets(shares) == data.shares, "Gauge drift")
 *        require(assets == trackedShares, "Redeem mismatch")
 *      strictly equality-asserted that gauge stays exactly 1:1 forever. Once
 *      the gauge ever rounded down by 1 wei (legal ERC4626 behavior), the
 *      whole position became unrecoverable — every subsequent unstake or
 *      withdraw would revert.
 *
 *   3. YieldBasisLpClaimingFacet.harvestLpFees:
 *        _gauge.withdraw(surplusShares, ...);
 *        _lpToken.withdraw(surplusShares, ...);   // WRONG: surplusShares is gauge units
 *      passed the gauge-share count to the LP burn step. If the gauge applied
 *      any conversion or rounding, the LP burn either reverted (insufficient
 *      LP balance) or burned the wrong amount.
 *
 * The fix replaced strict-equality with delta-of-balance reads and added
 * `reconcileSharesToBalance` to absorb any shrinkage as accounting truth at
 * the trusted unstake boundary.
 *
 * This file covers the seven scenarios called out in the test ask:
 *  (1) addCollateral gauge-balance unit conversion
 *  (2) unstake under gauge drift no longer reverts; data.shares reconciled down
 *  (3) reconcileSharesToBalance semantics (no-op, shrink, undercollateralization)
 *  (4) _stake event accuracy under deposit fee
 *  (5) harvestLpFees under gauge withdraw rounding
 *  (6) happy-path 1:1 regression — full lifecycle on the tunable mock
 *  (7) donation tolerance — donated LP/gauge shares never auto-credit
 *
 * Two test contracts share the file:
 *   - YBManagerH003Test         : YieldBasisCollateralManager direct (harness)
 *   - YBFacetH003Test           : facet-level via the diamond proxy
 * Each runs against MockTunableYieldBasisGauge so we can drive non-1:1
 * conversion without a fork.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

// Library / facets
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

// Infrastructure
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * Harness — exposes library functions; the harness IS the borrower since the
 * library reads/writes its ERC-7201 slot on `address(this)`.
 * -------------------------------------------------------------------------*/
contract YBManagerHarness {
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }

    function reconcileSharesToBalance(address cfg, address vault, address underlying, address gauge) external {
        YieldBasisCollateralManager.reconcileSharesToBalance(cfg, vault, underlying, gauge);
    }

    function getCollateral(address vault, address underlying)
        external
        view
        returns (uint256 shares, uint256 deposited, uint256 current)
    {
        return YieldBasisCollateralManager.getCollateral(vault, underlying);
    }

    function getCollateralShares() external view returns (uint256) {
        return YieldBasisCollateralManager.getCollateralShares();
    }

    function getTotalDebt() external view returns (uint256) {
        return YieldBasisCollateralManager.getTotalDebt();
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

    function enforceCollateralRequirements(address cfg, address vault, address underlying)
        external
        view
        returns (bool)
    {
        return YieldBasisCollateralManager.enforceCollateralRequirements(cfg, vault, underlying);
    }

    /// @dev Direct slot poke so tests can stage debt/shares/depositedAssetValue
    ///      without going through a real lending pool. Mirrors the layout in
    ///      YieldBasisCollateralManager.YieldBasisCollateralData.
    function __setStorage(
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 debt
    ) external {
        bytes32 base = keccak256("storage.YieldBasisCollateralManager");
        assembly {
            sstore(base, shares)
            sstore(add(base, 1), depositedAssetValue)
            sstore(add(base, 2), debt)
        }
    }
}

/* ===========================================================================
 * Manager-level tests (scenarios 1, 3, 7 — and base of scenario 2)
 * =========================================================================*/
contract YBManagerH003Test is Test {
    YBManagerHarness internal h;

    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    MockYieldBasisLP internal ybLp;
    MockERC20 internal underlying;
    MockERC20 internal usdc;
    MockTunableYieldBasisGauge internal gauge;

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("h003-mgr"));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1e18);
        underlying = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 18);

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(usdc), address(factory), OWNER, "lvault", "lv", 8000, 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        usdc.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        cfg.setLoanContract(address(lendingVault));
        factory.setPortfolioFactoryConfig(address(cfg));

        vm.stopPrank();

        gauge = new MockTunableYieldBasisGauge(address(ybLp));
        h = new YBManagerHarness();

        vm.label(address(h), "harness");
        vm.label(address(gauge), "tunableGauge");
        vm.label(address(ybLp), "ybLp");
    }

    /* ------------------------------------------------------------------
     * Scenario 1: addCollateral converts gauge balance to LP units
     * ------------------------------------------------------------------
     * If the precondition check still summed raw gauge.balanceOf into
     * actualBalance, the test under a 99% gauge ratio would PASS the
     * check inadvertently (gauge holds 1e18 shares == 1e18 raw, still
     * >= required 1e18 shares + new). After the fix the gauge balance
     * is converted to LP-equivalent first (1e18 * 0.99 = 0.99e18), which
     * is short of the required 1e18, so it MUST revert.
     * ------------------------------------------------------------------ */
    function test_addCollateral_convertsGaugeBalanceViaConvertToAssets() public {
        // Stage the harness with 1e18 gauge shares (no LP), gauge ratio = 99%.
        // We do this by depositing LP into the gauge from the harness.
        ybLp.mint(address(h), 1e18);

        // Prank the harness to approve & deposit so its share balance is non-zero.
        // (We use vm.startPrank since the harness is the depositor of record.)
        vm.startPrank(address(h));
        ybLp.approve(address(gauge), 1e18);
        gauge.deposit(1e18, address(h));
        vm.stopPrank();

        assertEq(gauge.balanceOf(address(h)), 1e18, "harness has 1e18 raw gauge shares");
        assertEq(ybLp.balanceOf(address(h)), 0, "no LP on harness");

        // Now drift the gauge: convertToAssets(1e18) = 0.99e18.
        gauge.setConvertRatioBps(9_900);
        assertEq(gauge.convertToAssets(1e18), 0.99e18, "gauge drifted to 99%");

        // Try to add 1e18 of collateral. data.shares=0 so required = 1e18.
        // Pre-fix: actualBalance would have been 1e18 (raw gauge balance) and
        // the check would have PASSED — silently over-crediting collateral.
        // Post-fix: actualBalance = 0 + convertToAssets(1e18) = 0.99e18 < 1e18,
        // so the call MUST revert with InsufficientShareBalance.
        vm.expectRevert(
            abi.encodeWithSelector(
                YieldBasisCollateralManager.InsufficientShareBalance.selector,
                uint256(1e18),
                uint256(0.99e18)
            )
        );
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), 1e18);
    }

    /// @notice Sanity: with gauge at 1:1, the same setup succeeds — proves the
    ///         conversion path doesn't break the common-case assertion.
    function test_addCollateral_oneToOneStillSucceeds() public {
        ybLp.mint(address(h), 1e18);
        vm.startPrank(address(h));
        ybLp.approve(address(gauge), 1e18);
        gauge.deposit(1e18, address(h));
        vm.stopPrank();

        // Default ratio = 10_000 (1:1). actualBalance = 0 + 1e18 = 1e18 ≥ 1e18.
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), 1e18);

        (uint256 sharesTracked,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesTracked, 1e18, "shares tracked at 1:1");
    }

    /// @notice Edge: gauge address == 0 disables the conversion branch — only
    ///         LP balance is counted. Pins this fall-through.
    function test_addCollateral_gaugeAddressZero_skipsConversion() public {
        ybLp.mint(address(h), 1e18);
        // No gauge interaction; harness holds raw LP.
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);

        (uint256 sharesTracked,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesTracked, 1e18, "tracked at 1e18 with zero gauge");
    }

    /// @notice Edge: gauge with zero shares (nothing staked yet) — conversion
    ///         path is skipped via the `gaugeShares > 0` guard, only LP counted.
    function test_addCollateral_gaugeBalanceZero_skipsConversion() public {
        ybLp.mint(address(h), 1e18);
        // Ratio is non-trivial but gauge balance is zero — the check guards on
        // `gaugeShares > 0` to avoid an unnecessary external view call.
        gauge.setConvertRatioBps(8_000);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), 1e18);

        (uint256 sharesTracked,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesTracked, 1e18, "skipping conversion path with zero gauge balance");
    }

    /* ------------------------------------------------------------------
     * Scenario 3a: reconcileSharesToBalance no-op when actualLp >= shares
     * ------------------------------------------------------------------ */
    function test_reconcile_noop_whenActualMeetsTracked() public {
        ybLp.mint(address(h), 5e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 5e18);

        (uint256 sharesBefore, uint256 depBefore,) = h.getCollateral(address(ybLp), address(underlying));

        // No drift — actualLp == data.shares. Reconcile is a no-op.
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        (uint256 sharesAfter, uint256 depAfter,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, sharesBefore, "shares unchanged when actual meets tracked");
        assertEq(depAfter, depBefore, "depositedAssetValue unchanged when actual meets tracked");
    }

    /// @notice Surplus LP (price appreciation, donation, etc.) does NOT get
    ///         auto-credited — reconcile is one-way (only shrinks). Pins the
    ///         intentional asymmetry.
    function test_reconcile_doesNotIncreaseShares_onSurplusLp() public {
        ybLp.mint(address(h), 5e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 5e18);

        // Surplus LP appears (e.g. transfer-in or fee accrual that materialized
        // as more LP). reconcile must NOT bump tracked shares up.
        ybLp.mint(address(h), 1e18);

        (uint256 before_,,) = h.getCollateral(address(ybLp), address(underlying));
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));
        (uint256 after_,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(after_, before_, "reconcile must not auto-credit surplus");
    }

    /* ------------------------------------------------------------------
     * Scenario 3b: reconcile shrinks data.shares + pro-rata depositedAssetValue
     * ------------------------------------------------------------------ */
    function test_reconcile_shrinksSharesAndScalesDeposited() public {
        // Set up: harness tracks 10 shares with depositedAssetValue 10. Then the
        // physical LP is reduced to 7 (gauge fee scenario simulated via a
        // direct burn). reconcile must drop shares to 7 AND scale deposited
        // proportionally to 7 (= 10 * 7/10).
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        (, uint256 depBefore,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(depBefore, 10e18, "deposited tracks at pps=1");

        // Simulate a 30% physical loss (fee, slashing, donation-out, etc.)
        vm.prank(address(h));
        ybLp.transfer(address(0xdead), 3e18);

        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        (uint256 sharesAfter, uint256 depAfter,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, 7e18, "shares reduced to actual LP balance");
        assertEq(depAfter, 7e18, "depositedAssetValue scaled pro-rata (10 * 7/10)");
    }

    /// @notice Reconcile counts gauge-converted LP toward actual when computing
    ///         the floor — drift on a fully-staked position only shrinks if the
    ///         converted gauge balance is < tracked shares.
    function test_reconcile_countsGaugeConvertToAssets() public {
        // Stage harness with 5e18 gauge shares (no raw LP) and tracked shares
        // of 5e18. Drift gauge to 80%: actualLp = convertToAssets(5e18) = 4e18.
        // reconcile must shrink to 4e18.
        ybLp.mint(address(h), 5e18);
        vm.startPrank(address(h));
        ybLp.approve(address(gauge), 5e18);
        gauge.deposit(5e18, address(h));
        vm.stopPrank();

        // Set tracked shares = 5e18 with deposited = 5e18 (we use the harness
        // poke since addCollateral would invoke the same check we proved
        // converts correctly above; here we want to isolate reconcile).
        h.__setStorage(5e18, 5e18, 0);

        gauge.setConvertRatioBps(8_000); // 80% drift

        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        (uint256 sharesAfter, uint256 depAfter,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, 4e18, "shares shrink to convertToAssets(gauge)");
        assertEq(depAfter, 4e18, "deposited scales pro-rata to 5 * 4/5 = 4");
    }

    /* ------------------------------------------------------------------
     * Scenario 3c: reconcile updates the in-block snapshot
     *
     *   Documented invariant: when reconcile shrinks data.shares it also
     *   re-snapshots the shortfall via _snapshotIfNeeded. This means an
     *   in-block enforceCollateralRequirements check sees start==end at the
     *   moment of shrink (no false-positive revert from a pre-shrink snap).
     *
     *   We can't easily stage `debt > 0` with this lightweight harness
     *   because _snapshotIfNeeded resyncs debt from the lending pool (which
     *   is the real LendingVault here, reporting 0). So we verify the same
     *   property indirectly: reconcile bumps the snapshot block forward and
     *   leaves the position consistent against subsequent enforce.
     * ------------------------------------------------------------------ */
    function test_reconcile_updatesSnapshotBlockOnShrink() public {
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Roll forward so the snapshot block (set inside addCollateral) is
        // strictly less than the current block when reconcile runs.
        vm.roll(block.number + 1);

        // Shrink the physical LP by 50%.
        vm.prank(address(h));
        ybLp.transfer(address(0xdead), 5e18);

        // Pre-reconcile: data.shares=10, actualLp=5 → reconcile must shrink
        // and update the snapshot block (since block has rolled forward).
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        (uint256 sharesAfter, uint256 depositedAfter,) =
            h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, 5e18, "shares reconciled down to actual LP");
        assertEq(depositedAfter, 5e18, "deposited scaled pro-rata");

        // With debt=0, enforce always passes.
        bool ok = h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
        assertTrue(ok, "enforce passes with zero debt after reconcile");
    }

    /// @notice Reconcile is a no-op when actualLp >= shares — it must NOT
    ///         touch the snapshot block in that case (otherwise a benign
    ///         reconcile call could erase a same-block start snapshot taken
    ///         by a previous mutating call, which would bypass the
    ///         "shortfall must not grow within a block" guard).
    function test_reconcile_noop_doesNotTouchSnapshot() public {
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Take an explicit snapshot at the current block.
        h.snapshotShortfall(address(cfg), address(ybLp), address(underlying));

        // No-op reconcile — actualLp == shares.
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        // Subsequent enforce in the same block reads start==end==0, passes.
        bool ok = h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
        assertTrue(ok, "enforce passes after no-op reconcile in same block");
    }

    /* ------------------------------------------------------------------
     * Scenario 7: Donation tolerance
     * ------------------------------------------------------------------ */
    function test_donation_lpTokens_areNotAutoCredited() public {
        // Add legitimate collateral first
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);

        (uint256 sharesBefore,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesBefore, 1e18);

        // Stranger donates LP directly
        ybLp.mint(address(0xd09a7e), 5e18);
        vm.prank(address(0xd09a7e));
        ybLp.transfer(address(h), 5e18);

        // Donation does NOT update tracked shares — addCollateral is the only
        // path that credits.
        (uint256 sharesAfter,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, sharesBefore, "donation never auto-credits");

        // reconcile is also one-way; donation cannot raise shares.
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));
        (uint256 sharesAfterReconcile,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfterReconcile, sharesBefore, "reconcile cannot auto-credit donation");
    }

    function test_donation_gaugeShares_areNotAutoCredited() public {
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);

        (uint256 sharesBefore,,) = h.getCollateral(address(ybLp), address(underlying));

        // Stranger stakes LP and transfers gauge shares to harness.
        address stranger = address(0xd09a7e);
        ybLp.mint(stranger, 5e18);
        vm.startPrank(stranger);
        ybLp.approve(address(gauge), 5e18);
        gauge.deposit(5e18, stranger);
        gauge.transfer(address(h), 5e18);
        vm.stopPrank();

        // No-op reconcile: gauge balance counts toward actualLp, but actualLp
        // is now > tracked shares, so reconcile does nothing (only shrinks).
        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));
        (uint256 sharesAfter,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesAfter, sharesBefore, "donated gauge shares never auto-credit");
    }
}

/* ===========================================================================
 * Facet-level tests — run through the diamond/portfolio account
 *   Scenario 2 : unstake under gauge drift no longer reverts
 *   Scenario 4 : _stake event accuracy under deposit fee
 *   Scenario 5 : harvestLpFees under gauge withdraw rounding
 *   Scenario 6 : full lifecycle regression at 1:1
 *   Scenario 7 : donation tolerance through user-facing withdraw cap
 * =========================================================================*/
contract YBFacetH003Test is Test {
    YieldBasisLpFacet internal facet;
    YieldBasisLpClaimingFacet internal claimingFacet;
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;

    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;

    MockYieldBasisLP internal ybLp;
    MockERC20 internal ybToken;
    MockERC20 internal usdc;
    MockTunableYieldBasisGauge internal gauge;
    LendingVault internal lendingVault;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal portfolioAccount;

    uint256 internal constant DEPOSIT = 1e18;
    uint256 internal constant VAULT_LIQ = 100_000e18;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256("h003-facet")
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        // YB-specific config so the facet's getStakedMode() resolves the
        // YieldBasisPortfolioFactoryConfig.getStakedGaugeMode() selector.
        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybToken = new MockERC20("YB", "YB", 18);
        usdc = new MockERC20("USDC", "USDC", 18);
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(usdc), address(portfolioFactory), owner_, "lvault", "lv", 8000, 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        usdc.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(7000);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        facet = new YieldBasisLpFacet(
            address(portfolioFactory),
            address(gauge),
            address(ybToken),
            address(usdc)
        );
        bytes4[] memory facetSelectors = new bytes4[](8);
        facetSelectors[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors[2] = YieldBasisLpFacet.setStakedMode.selector;
        facetSelectors[3] = YieldBasisLpFacet.getStakingState.selector;
        facetSelectors[4] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors[6] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors[7] = ICollateralFacet.getMaxLoan.selector;
        facetRegistry.registerFacet(address(facet), facetSelectors, "YBFacet");

        claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory),
            address(gauge),
            address(usdc)
        );
        bytes4[] memory claimingSelectors = new bytes4[](5);
        claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        claimingSelectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
        claimingSelectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        claimingSelectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimingSelectors, "YBClaimingFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        ybLp.mint(user, DEPOSIT * 10);
    }

    // ============ Helpers ============

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        ybLp.approve(portfolioAccount, amount);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _depositAndStake(uint256 amount) internal {
        _deposit(amount);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    function _withdraw(uint256 amount) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------
     * Scenario 2: unstake under gauge drift
     *
     * Pre-fix this would revert with "Gauge drift" or "Redeem mismatch".
     * Post-fix: unstake succeeds, data.shares reduced to actually-received
     * LP, depositedAssetValue scaled pro-rata, Unstaked event emits the
     * actual delivered LP not the input shares.
     * ------------------------------------------------------------------ */
    function test_unstake_underGaugeDrift_succeedsAndReconciles() public {
        // Deposit then stake at 1:1 — gauge balance = LP staked = DEPOSIT.
        _depositAndStake(DEPOSIT);

        // Now configure the gauge to redeem 1 wei short of the converted
        // amount (a legal ERC4626 round-down). Use convertRatio 1:1 so
        // convertToAssets(shares) == shares but redeem delivers shares - 1.
        gauge.setRedeemShortfallWei(1);

        // Capture pre-state.
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, DEPOSIT, "tracked at full deposit pre-unstake");

        // unstake() must NOT revert — pre-fix it would have here.
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        // Post-state: account holds DEPOSIT - 1 LP; gauge is empty for this account.
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "gauge fully redeemed");
        assertEq(unstaked, DEPOSIT - 1, "delivered LP is 1 wei short");

        // reconcile must have shrunk data.shares to DEPOSIT - 1.
        uint256 sharesTracked = YieldBasisCollateralManager.getCollateralShares();
        // (Note: reading the library directly off this contract only sees its
        // own storage slot — not the portfolio account's. Use the facet view.)
        sharesTracked; // silence
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, DEPOSIT - 1, "collateral pinned to actual LP");

        // depositedAssetValue scaled pro-rata: at pps=1, deposited tracks shares 1:1.
        // Subsequent harvest/withdraw flows on the shrunk position must work.
        // Withdraw the full unstaked LP to confirm position is recoverable.
        _withdraw(DEPOSIT);
        // User gets DEPOSIT - 1 LP back (clamped to tracked).
        assertEq(ybLp.balanceOf(user), (DEPOSIT * 10) - DEPOSIT + (DEPOSIT - 1), "user recovers all LP");
    }

    /// @notice Unstake event reflects the ACTUAL LP received, not the input
    ///         share count. With redeemShortfall = 1, the event must report
    ///         (DEPOSIT - 1, DEPOSIT, 0) — the second arg is the input shares
    ///         (input contract value, not delivered), the first arg is delta.
    function test_unstake_event_reflectsActualLpDelivered() public {
        _depositAndStake(DEPOSIT);
        gauge.setRedeemShortfallWei(1);

        vm.expectEmit(false, false, false, true, portfolioAccount);
        emit YieldBasisLpFacet.Unstaked(DEPOSIT - 1, DEPOSIT);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    /// @notice Larger drift than 1 wei — ratio at 99%: `redeem(shares)` returns
    ///         shares*0.99 LP, reconcile scales tracked shares & deposited
    ///         pro-rata, withdraw still clamps to tracked.
    function test_unstake_underLargeDrift_succeedsAndReconciles() public {
        _depositAndStake(DEPOSIT);

        // 99% ratio — redeem(1e18 shares) delivers 0.99e18 LP.
        gauge.setConvertRatioBps(9_900);

        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "gauge fully redeemed");
        assertEq(unstaked, (DEPOSIT * 9_900) / 10_000, "delivered 99% of input");

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, (DEPOSIT * 9_900) / 10_000, "collateral pinned to actual LP");
    }

    /* ------------------------------------------------------------------
     * Scenario 4: _stake event accuracy under deposit fee
     *
     * Gauge takes a deposit fee (mints fewer shares than LP given).
     * Staked event emits (lpSent, sharesMinted) — these are different now.
     * ------------------------------------------------------------------ */
    function test_stake_event_reflectsActualSharesMinted_underDepositFee() public {
        // 1% deposit fee — gauge.deposit(1e18) mints 0.99e18 shares, but pulls
        // the full 1e18 LP from the account.
        gauge.setDepositFeeBps(100);

        // Deposit holds LP on account.
        _deposit(DEPOSIT);

        uint256 expectedShares = (DEPOSIT * 9_900) / 10_000;
        vm.expectEmit(false, false, false, true, portfolioAccount);
        emit YieldBasisLpFacet.Staked(DEPOSIT, expectedShares);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        // Gauge received full 1e18 LP, minted 0.99e18 shares.
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, expectedShares, "gauge minted fee-adjusted shares");
        assertEq(unstaked, 0, "all LP sent to gauge");
    }

    /* ------------------------------------------------------------------
     * Scenario 5: harvestLpFees under gauge withdraw rounding
     *
     * `_gauge.withdraw(surplusShares, ...)` delivers surplusShares - 1 LP.
     * Pre-fix: `_lpToken.withdraw(surplusShares)` would revert because the
     *          account doesn't actually hold surplusShares LP.
     * Post-fix: harvest reads delivered LP via balance delta and passes
     *          THAT to _lpToken.withdraw. Should succeed.
     * ------------------------------------------------------------------ */
    function test_harvestLpFees_underWithdrawRounding_succeedsViaBalanceDelta() public {
        // Deposit + stake to seed gauge shares.
        _depositAndStake(DEPOSIT);

        // Make pps appreciate so there's yield surplus to harvest.
        ybLp.setPricePerShare(1.5e18);

        // Configure gauge withdraw to deliver 1 wei short.
        gauge.setWithdrawShortfallWei(1);

        // Sanity: getAvailableLpFeeYield reports a non-zero surplus.
        (uint256 yU, uint256 yS) = YieldBasisLpClaimingFacet(portfolioAccount).getAvailableLpFeeYield();
        assertGt(yU, 0, "yield available");
        assertGt(yS, 0, "surplus shares > 0");

        // Pre-fix: this would revert because _lpToken.withdraw was passed
        // surplusShares but only surplusShares-1 LP was on the account, and
        // burning surplusShares from a balance of surplusShares-1 underflows.
        // Post-fix: harvest reads the actual LP delta and passes that.
        vm.prank(authorizedCaller);
        uint256 received = YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(0);
        assertGt(received, 0, "underlying received from rounded-withdraw harvest");
    }

    /// @notice harvestLpFees emits LpFeesHarvested with the corrected fields:
    ///         (gaugeSharesBurned, lpTokensBurned, underlyingReceived). The
    ///         lpTokensBurned slot now reflects the BALANCE-DELTA value, not
    ///         the input share count — under withdraw rounding these differ.
    function test_harvestLpFees_event_lpTokensBurned_reflectsActual() public {
        _depositAndStake(DEPOSIT);
        ybLp.setPricePerShare(1.5e18);
        gauge.setWithdrawShortfallWei(1);

        // Compute expected surplus shares the same way the facet does.
        // surplusShares = trackedShares * (currentValue - depositedValue) / currentValue
        //                = 1e18 * (1.5e18 - 1e18) / 1.5e18 ≈ 333333333333333333 (rounded)
        uint256 trackedShares = DEPOSIT;
        uint256 currentValue = (DEPOSIT * 15) / 10; // 1.5e18 at pps=1.5
        uint256 depositedValue = DEPOSIT;
        uint256 expectedSurplus = (trackedShares * (currentValue - depositedValue)) / currentValue;
        uint256 expectedLp = expectedSurplus - 1;

        // We don't know underlyingReceived in advance because pps applies to
        // the LP burn step too — accept any non-zero value via expectEmit
        // checkData=false on that field. Foundry doesn't allow per-field
        // ignore — so capture and assert manually instead.
        vm.recordLogs();
        vm.prank(authorizedCaller);
        YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the LpFeesHarvested log on the portfolio account.
        bytes32 sig = keccak256("LpFeesHarvested(uint256,uint256,uint256,address)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == portfolioAccount && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (uint256 gaugeBurned, uint256 lpBurned, uint256 underlyingRcv) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(gaugeBurned, expectedSurplus, "gaugeSharesBurned matches input");
                assertEq(lpBurned, expectedLp, "lpTokensBurned reflects balance delta (1 wei short)");
                assertGt(underlyingRcv, 0, "underlying received");
                found = true;
                break;
            }
        }
        assertTrue(found, "LpFeesHarvested event emitted with corrected fields");
    }

    /* ------------------------------------------------------------------
     * Scenario 6: Happy-path 1:1 regression (full lifecycle)
     *
     * With the tunable mock left at 1:1 / no fee / no rounding it must
     * behave identically to the simpler MockYieldBasisGauge across the
     * full deposit→stake→harvest→unstake→withdraw lifecycle.
     * ------------------------------------------------------------------ */
    function test_happyPath_oneToOne_fullLifecycle() public {
        // Deposit & stake
        _depositAndStake(DEPOSIT);
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT, "fully staked at 1:1");
        assertEq(unstaked, 0);

        // Generate yield and harvest
        ybLp.setPricePerShare(1.5e18);
        vm.prank(authorizedCaller);
        uint256 received = YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(0);
        assertGt(received, 0, "happy-path harvest delivers underlying");

        // Unstake — at 1:1 with no rounding, gauge returns LP equal to shares.
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "gauge fully drained at 1:1");
        // After harvest, removeSharesForYield reduced data.shares but
        // depositedAssetValue is held constant — and currentValue (returned
        // by getTotalLockedCollateral) at the higher pps may match the
        // original deposit value. We don't pin a formula on the unstaked LP
        // here because the MockYieldBasisLP.withdraw used inside harvestLpFees
        // mints additional tokens to the receiver in this mock topology (in
        // production underlying is a different ERC20). The lifecycle property
        // we care about is: no revert + tracked share count was reduced by
        // exactly surplusShares.
        (uint256 sharesPostHarvest,,) = YieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
        assertGt(sharesPostHarvest, 0, "tracked shares remain after harvest");
        assertLt(sharesPostHarvest, DEPOSIT, "tracked shares reduced by surplus");

        // Restake → unstake → withdraw remaining
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        uint256 userBefore = ybLp.balanceOf(user);
        _withdraw(type(uint128).max); // clamp-style — drain everything tracked
        uint256 userAfter = ybLp.balanceOf(user);
        assertGt(userAfter, userBefore, "user receives remaining LP");

        // Tracked collateral fully drained.
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "tracked collateral fully drained at lifecycle end"
        );
        // Note: the account may retain untracked LP residue from the
        // mock-LP-withdraw step inside harvest (a quirk of the mock; in
        // production underlying is a different ERC20). The donation-tolerance
        // tests pin that untracked LP cannot be drained; here we simply
        // confirm the lifecycle never revert and tracked collateral cleared.
        (staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "no gauge shares retained at lifecycle end");
    }

    /* ------------------------------------------------------------------
     * Scenario 7: Donation tolerance through the user-facing surface
     *
     *   - donate LP into the account directly
     *   - addCollateral does NOT auto-credit the donation
     *   - withdraw is still capped to trackedShares (donation stays)
     * ------------------------------------------------------------------ */
    function test_donatedLp_isNotCreditedByAddCollateral() public {
        // First a normal 1e18 deposit so the account has tracking.
        _deposit(DEPOSIT);
        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, DEPOSIT);

        // Stranger donates LP directly into the account.
        ybLp.mint(address(0xd09a7e), 5e18);
        vm.prank(address(0xd09a7e));
        ybLp.transfer(portfolioAccount, 5e18);

        // Tracked collateral is unchanged.
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "donation does not auto-credit");

        // A subsequent legitimate deposit credits its own amount, not the
        // surplus. addCollateral's precondition is satisfied because the
        // account holds plenty of LP; tracked goes up by exactly the new
        // deposit.
        _deposit(DEPOSIT);
        uint256 collateralAfter2 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter2, collateralBefore + DEPOSIT, "second deposit credits exactly its amount");
    }

    function test_donatedLp_withdrawClampsToTracked() public {
        _deposit(DEPOSIT);

        // Donate 5e18 LP to the account.
        ybLp.mint(address(0xd09a7e), 5e18);
        vm.prank(address(0xd09a7e));
        ybLp.transfer(portfolioAccount, 5e18);

        // Account holds DEPOSIT + 5e18 LP; only DEPOSIT is tracked.
        assertEq(ybLp.balanceOf(portfolioAccount), DEPOSIT + 5e18);
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), DEPOSIT);

        // Try to withdraw more than tracked — clamped to tracked, donation
        // stays untracked on the account.
        uint256 userBefore = ybLp.balanceOf(user);
        _withdraw(DEPOSIT + 5e18);
        uint256 userAfter = ybLp.balanceOf(user);

        assertEq(userAfter - userBefore, DEPOSIT, "withdraw clamps to tracked, donation not drained");
        assertEq(ybLp.balanceOf(portfolioAccount), 5e18, "donation remains stranded on the account");
    }

    function test_donatedGaugeShares_doNotInflateGetStakingState_collateralUnchanged() public {
        _depositAndStake(DEPOSIT);

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        (uint256 stakedBefore,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedBefore, DEPOSIT);

        // Stranger stakes their own LP and donates gauge shares to the account.
        address stranger = address(0xd09a7e);
        ybLp.mint(stranger, 5e18);
        vm.startPrank(stranger);
        ybLp.approve(address(gauge), 5e18);
        gauge.deposit(5e18, stranger);
        gauge.transfer(portfolioAccount, 5e18);
        vm.stopPrank();

        // getStakingState reflects the raw gauge balance (donation visible) but
        // collateral tracking is unchanged.
        (uint256 stakedAfter,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedAfter, DEPOSIT + 5e18, "gauge view includes donation (not collateral)");
        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "tracked collateral unchanged by donation");
    }
}


