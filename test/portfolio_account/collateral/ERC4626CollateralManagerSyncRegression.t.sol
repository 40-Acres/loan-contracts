// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ===========================================================================
 * ERC4626CollateralManager — debt-cache regression suite
 * ===========================================================================
 *
 * Mirror of YieldBasisCollateralManagerSyncRegression for the ERC4626 manager.
 * Locks down the same write-through-cache invariant:
 *   `data.debt` is now strictly `lendingPool.getDebtBalance(this)`.
 *
 * The two managers are nearly identical post-refactor. Both libraries gained
 * a `_syncDebt` helper, both call it unconditionally inside `_snapshotIfNeeded`,
 * both resync after `borrowFromPortfolio` / `payFromPortfolio`. Each gets its
 * own regression file because they live at different ERC-7201 slots and
 * regressing one in isolation must remain caught by its own tests.
 * ===========================================================================
 */

import {Test} from "forge-std/Test.sol";

import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626PortfolioFactoryConfig} from "../../../script/portfolio_account/DeployERC4626PortfolioFactoryConfig.s.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 * Harness for the ERC4626CollateralManager library.
 * Owns the keccak256("storage.ERC4626CollateralManager") slot.
 * -------------------------------------------------------------------------*/
contract ERC4626SyncHarness {
    bytes32 internal constant SLOT = keccak256("storage.ERC4626CollateralManager");

    function addCollateral(address cfg, address vault, uint256 s) external {
        ERC4626CollateralManager.addCollateral(cfg, vault, s);
    }
    function removeCollateral(address cfg, address vault, uint256 s) external {
        ERC4626CollateralManager.removeCollateral(cfg, vault, s);
    }
    function increaseTotalDebt(address cfg, address vault, uint256 a)
        external returns (uint256, uint256) {
        return ERC4626CollateralManager.increaseTotalDebt(cfg, vault, a);
    }
    function decreaseTotalDebt(address cfg, address vault, uint256 a) external returns (uint256) {
        return ERC4626CollateralManager.decreaseTotalDebt(cfg, vault, a);
    }
    function snapshotShortfall(address cfg, address vault) external {
        ERC4626CollateralManager.snapshotShortfall(cfg, vault);
    }
    function removeSharesForYield(address cfg, address vault, uint256 s) external {
        ERC4626CollateralManager.removeSharesForYield(cfg, vault, s);
    }
    function getTotalDebt() external view returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }
    function getMaxLoan(address cfg, address vault) external view returns (uint256, uint256) {
        return ERC4626CollateralManager.getMaxLoan(cfg, vault);
    }
    function enforceCollateralRequirements(address cfg, address vault) external view returns (bool) {
        return ERC4626CollateralManager.enforceCollateralRequirements(cfg, vault);
    }

    function rawDebt() external view returns (uint256 d) {
        bytes32 s = SLOT;
        assembly { d := sload(add(s, 2)) }
    }
    function rawSnapshotBlock() external view returns (uint256 b) {
        bytes32 s = SLOT;
        assembly { b := sload(add(s, 5)) }
    }
    function rawStartShortfall() external view returns (uint256 v) {
        bytes32 s = SLOT;
        assembly { v := sload(add(s, 4)) }
    }
}

/* ---------------------------------------------------------------------------
 * Mock ERC4626-like vault that responds to ILendingPool's required
 * surface area. Pretends to be both the lending vault and its underlying
 * asset (which forces the `IERC4626(lendingVault).asset()` lookup to point
 * back at this mock). Allows tests to stage independent debt-balance values
 * pre-pay vs post-pay.
 * -------------------------------------------------------------------------*/
contract MockSyncPool4626 {
    address public immutable _asset;
    address internal _portfolioFactory;
    uint256 public _debtBalance;
    uint256 public _activeAssets;
    uint256 public _actualPaid;
    uint256 public _debtAfterPay;
    bool public _useAfterPay;

    constructor(address asset_, address portfolioFactory_) {
        _asset = asset_;
        _portfolioFactory = portfolioFactory_;
    }

    function setDebt(uint256 v) external { _debtBalance = v; }
    function setDebtAfterPay(uint256 v) external { _debtAfterPay = v; _useAfterPay = true; }
    function setActiveAssets(uint256 v) external { _activeAssets = v; }
    function setActualPaid(uint256 v) external { _actualPaid = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return address(this); }
    function asset() external view returns (address) { return _asset; }
    function activeAssets() external view returns (uint256) { return _activeAssets; }

    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }

    function payFromPortfolio(uint256 totalPayment, uint256) external returns (uint256 actualPaid) {
        actualPaid = _actualPaid;
        if (actualPaid > totalPayment) actualPaid = totalPayment;
        if (actualPaid > 0) {
            IERC20(_asset).transferFrom(msg.sender, address(this), actualPaid);
        }
        if (_useAfterPay) {
            _debtBalance = _debtAfterPay;
        }
    }

    function getDebtBalance(address) external view returns (uint256) {
        return _debtBalance;
    }

    // totalAssets() shim -- managers call ILendingVault(lendingPool.lendingVault()).totalAssets()
    // from getMaxLoan. Mock plays both pool and vault, so report idle + active.
    function totalAssets() public view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssets;
    }

    // Value-neutral mock: no same-block exclusion needed for these tests.
    function borrowableTotalAssets() external view returns (uint256) {
        return totalAssets();
    }

    function depositRewards(uint256) external {}
}

/* ===========================================================================
 * TEST SUITE
 * ==========================================================================*/
contract ERC4626CollateralManagerSyncRegressionTest is Test {
    ERC4626SyncHarness internal h;

    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    MockSyncPool4626 internal pool;

    MockERC4626 internal vault;       // collateral vault
    MockERC20 internal collatAsset;   // underlying of the collateral vault
    MockERC20 internal usdc;          // lending asset

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);
    // Manager-impersonation prank target. The non-AUTH caller path skips the
    // inline `enforceCollateralRequirements` that was added to the AUTH branch
    // of increaseTotalDebt — multicall flows rely on PortfolioManager.multicall
    // to enforce at end-of-tx instead. Tests that intentionally stage
    // stale-cache scenarios via pool.setDebt produce post-borrow states that
    // would trip the inline enforce; they must use this path.
    address internal MANAGER;

    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("erc4626-cm-sync"));
        factory = f;
        registry = r;

        DeployERC4626PortfolioFactoryConfig deployer = new DeployERC4626PortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        collatAsset = new MockERC20("CASS", "CASS", 18);
        vault = new MockERC4626(address(collatAsset), "ERC4626 Vault", "v", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        pool = new MockSyncPool4626(address(usdc), address(factory));
        usdc.mint(address(pool), 100_000_000e6);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS); // like-to-like ERC4626 market uses LTV branch
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));
        ERC4626PortfolioFactoryConfig(address(cfg)).setCollateralVault(address(vault));

        pm.setAuthorizedCaller(AUTH, true);
        MANAGER = address(pm);

        vm.stopPrank();

        h = new ERC4626SyncHarness();

        vm.label(address(h), "ERC4626SyncHarness");
        vm.label(address(pool), "MockSyncPool4626");
        vm.label(address(vault), "ERC4626Vault");
    }

    /// @dev Mints `assets` of CASS to the harness, deposits into vault to get
    /// shares 1:1, returns the share amount.
    function _seedShares(uint256 assets) internal returns (uint256 shares) {
        collatAsset.mint(address(h), assets);
        vm.prank(address(h));
        collatAsset.approve(address(vault), assets);
        vm.prank(address(h));
        shares = vault.deposit(assets, address(h));
    }

    /* -----------------------------------------------------------------------
     * (1) Cache-staleness regression — view sticks, mutating resyncs.
     * ----------------------------------------------------------------------*/
    function test_cacheStaleness_viewSticksToLastCache_mutatingResyncs() public {
        uint256 shares = _seedShares(100e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(50e18);
        // Manager-impersonation: pool.setDebt stages an "already at maxLoan"
        // post-sync state, so the manager's pre-borrow maxLoan = 0 and the
        // request lands fully on the supply flag. AUTH would revert inline
        // on BadDebt; we only want to inspect that the cache resyncs.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), address(vault), 50e18);
        assertEq(h.getTotalDebt(), 50e18, "post-borrow cache reflects pool truth");

        // Pool-side debt vests down out-of-band.
        pool.setDebt(30e18);

        // View: stale.
        assertEq(h.getTotalDebt(), 50e18, "view stale until next mutating call");

        // Mutating: resyncs.
        h.snapshotShortfall(address(cfg), address(vault));
        assertEq(h.getTotalDebt(), 30e18, "first mutating call resyncs");
    }

    /* -----------------------------------------------------------------------
     * (2) Snapshot freshness — startShortfall computed from synced debt.
     * ----------------------------------------------------------------------*/
    function test_snapshotFreshness_startShortfallComputedFromPoolTruth() public {
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);
        // After this addCollateral: snapshot block=current, start=0, debt=0.

        // Roll to make snapshot stale.
        vm.roll(block.number + 1);

        // Pool reports 12e18 of debt out-of-band. Shares=10e18 (assets=10e18) at
        // 70% LTV → maxLoanIgnoreSupply=7e18 → shortfall=5e18.
        pool.setDebt(12e18);

        h.snapshotShortfall(address(cfg), address(vault));

        assertEq(h.rawSnapshotBlock(), block.number, "new snapshot taken");
        assertEq(h.rawStartShortfall(), 5e18, "start = 12 - 7 (computed AFTER sync)");
        assertEq(h.rawDebt(), 12e18, "debt synced before shortfall calc");
    }

    /* -----------------------------------------------------------------------
     * (3) Multi-call within a single block — snapshot once, sync every.
     * ----------------------------------------------------------------------*/
    function test_multiCallSameBlock_snapshotOnceSyncEvery() public {
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);

        uint256 currentBlock = block.number;
        uint256 firstStart = h.rawStartShortfall();

        pool.setDebt(1e18);
        h.snapshotShortfall(address(cfg), address(vault));

        assertEq(h.rawSnapshotBlock(), currentBlock, "snapshot block pinned");
        assertEq(h.rawStartShortfall(), firstStart, "start NOT overwritten on 2nd same-block entry");
        assertEq(h.rawDebt(), 1e18, "but debt was resynced");
    }

    /* -----------------------------------------------------------------------
     * (4) Remove-after-vesting — withdraw must succeed once cache resyncs to
     * the lower pool-side debt.
     * ----------------------------------------------------------------------*/
    function test_removeAfterVesting_successOnceCacheResyncs() public {
        // Borrow up to max. shares=10e18 (1:1) → assets=10e18 → max=7e18.
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(7e18);
        // Manager-impersonation: pool.setDebt(7e18) puts data.debt at the cap
        // after sync, so pre-borrow maxLoan = 0 and the 7e18 request flags
        // supply overshoot. The point of this test is to verify the LATER
        // remove-after-vesting succeeds, not to assert on the borrow's flag.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), address(vault), 7e18);
        assertEq(h.getTotalDebt(), 7e18);

        // Pool debt vests down to 1e18 in a new block.
        vm.roll(block.number + 1);
        pool.setDebt(1e18);

        // Remove 5e18 shares → remaining 5e18 → new max=3.5e18.
        // Stale cache (7e18) > 3.5e18 → would have reverted pre-refactor.
        h.removeCollateral(address(cfg), address(vault), 5e18);

        assertEq(h.getTotalDebt(), 1e18, "cache reflects pool after sync");
    }

    /* -----------------------------------------------------------------------
     * (5) Borrow-with-implicit-interest — pool reports >requested-amount.
     * ----------------------------------------------------------------------*/
    function test_borrowReportingHigherDebt_cacheReflectsPoolNotRequest() public {
        uint256 shares = _seedShares(100e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(105e18); // pool charges 5% on borrow request

        // Manager-impersonation: pool.setDebt(105e18) > maxLoanIgnoreSupply
        // (70e18 at 70% LTV against 100e18 shares), so maxLoan = 0 and the
        // 100e18 request flags supply overshoot. The point of this test is
        // verifying the cache picks up the pool's reported debt, not flag math.
        vm.prank(MANAGER);
        h.increaseTotalDebt(address(cfg), address(vault), 100e18);

        assertEq(h.getTotalDebt(), 105e18, "cache = pool truth, not request");
    }

    /* -----------------------------------------------------------------------
     * (6) Storage layout invariant — slot offsets must not move.
     * ----------------------------------------------------------------------*/
    function test_storageLayout_isStable() public {
        uint256 shares = _seedShares(1e18);
        h.addCollateral(address(cfg), address(vault), shares);
        pool.setDebt(42);
        h.snapshotShortfall(address(cfg), address(vault));

        bytes32 base = keccak256("storage.ERC4626CollateralManager");

        bytes32 sharesSlot = base;
        bytes32 depositedSlot = bytes32(uint256(base) + 1);
        bytes32 debtSlot = bytes32(uint256(base) + 2);
        bytes32 overSuppliedSlot = bytes32(uint256(base) + 3);
        bytes32 startShortfallSlot = bytes32(uint256(base) + 4);
        bytes32 snapshotBlockSlot = bytes32(uint256(base) + 5);

        assertEq(uint256(vm.load(address(h), sharesSlot)), 1e18, "slot[0] = shares");
        assertEq(uint256(vm.load(address(h), depositedSlot)), 1e18, "slot[1] = depositedAssetValue (1:1)");
        assertEq(uint256(vm.load(address(h), debtSlot)), 42, "slot[2] = debt");
        assertEq(uint256(vm.load(address(h), overSuppliedSlot)), 0, "slot[3] = overSuppliedVaultDebt");
        // shortfall depends on debt 42 vs maxIgnore 0.7e18 → 0
        assertEq(uint256(vm.load(address(h), startShortfallSlot)), 0, "slot[4] = startShortfall");
        assertEq(uint256(vm.load(address(h), snapshotBlockSlot)), block.number, "slot[5] = snapshotBlockNumber");
    }

    /* -----------------------------------------------------------------------
     * (7) ERC4626 + YB slots are independent — writing one must not
     * disturb the other. (Diamond co-installation guarantee.)
     * ----------------------------------------------------------------------*/
    function test_storageIsolation_erc4626AndYbSlotsDoNotCollide() public {
        // Seed ERC4626 manager via the library.
        uint256 shares = _seedShares(5e18);
        h.addCollateral(address(cfg), address(vault), shares);
        assertEq(h.rawDebt(), 0, "ERC4626 debt initially 0");

        // Writing into the YB slot shouldn't disturb the ERC4626 slot.
        bytes32 ybBase = keccak256("storage.YieldBasisCollateralManager");
        bytes32 ybDebtSlot = bytes32(uint256(ybBase) + 2);
        vm.store(address(h), ybDebtSlot, bytes32(uint256(123456789)));

        assertEq(h.rawDebt(), 0, "ERC4626 debt slot unaffected by YB write");
        assertEq(uint256(vm.load(address(h), ybDebtSlot)), 123456789, "YB slot holds the test write");
    }

    /* -----------------------------------------------------------------------
     * (8) Public snapshotShortfall parity with implicit snapshot.
     * ----------------------------------------------------------------------*/
    function test_publicSnapshot_matchesImplicit() public {
        // Run A: explicit snapshotShortfall as first mutating entry of block.
        ERC4626SyncHarness hA = new ERC4626SyncHarness();
        // Pre-set pool debt so shortfall is computable. Collateral=0 for hA → max=0.
        pool.setDebt(8e18);
        hA.snapshotShortfall(address(cfg), address(vault));
        uint256 startA = hA.rawStartShortfall();
        uint256 debtA = hA.rawDebt();

        vm.roll(block.number + 1);

        // Run B: implicit via addCollateral as first entry. Snapshot fires
        // BEFORE shares are added, so collateral is still 0 at snapshot time.
        ERC4626SyncHarness hB = new ERC4626SyncHarness();
        // Seed shares for hB
        collatAsset.mint(address(hB), 10e18);
        vm.prank(address(hB));
        collatAsset.approve(address(vault), 10e18);
        vm.prank(address(hB));
        uint256 shB = vault.deposit(10e18, address(hB));

        pool.setDebt(8e18);
        hB.addCollateral(address(cfg), address(vault), shB);
        uint256 startB = hB.rawStartShortfall();
        uint256 debtB = hB.rawDebt();

        assertEq(startA, startB, "explicit and implicit snapshots match (start)");
        assertEq(debtA, debtB, "explicit and implicit snapshots match (debt)");
        assertEq(startA, 8e18, "shortfall = 8e18 (collateral was 0 at snapshot time)");
    }

    /* -----------------------------------------------------------------------
     * (9) Sync runs on every state-changing entry.
     * ----------------------------------------------------------------------*/
    function test_syncRunsOnEveryEntry_evenWhenSnapshotIsPinned() public {
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(1e18);
        h.snapshotShortfall(address(cfg), address(vault));
        assertEq(h.rawDebt(), 1e18);

        pool.setDebt(2e18);
        h.snapshotShortfall(address(cfg), address(vault));
        assertEq(h.rawDebt(), 2e18);

        pool.setDebt(3e18);
        h.snapshotShortfall(address(cfg), address(vault));
        assertEq(h.rawDebt(), 3e18);
    }

    /* -----------------------------------------------------------------------
     * (10) decreaseTotalDebt — pre-pay sync drives balancePayment.
     * ----------------------------------------------------------------------*/
    function test_decreaseTotalDebt_prePaySyncDrivesBalancePayment() public {
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(5e18);
        pool.setActualPaid(5e18);
        pool.setDebtAfterPay(0);

        usdc.mint(address(h), 8e18);

        uint256 excess = h.decreaseTotalDebt(address(cfg), address(vault), 8e18);

        assertEq(excess, 3e18, "excess = amount - actualPaid");
        assertEq(h.getTotalDebt(), 0, "post-pay sync writes pool truth");
    }

    /* -----------------------------------------------------------------------
     * (11) decreaseTotalDebt — zero pool debt clamps payment to zero.
     * ----------------------------------------------------------------------*/
    function test_decreaseTotalDebt_zeroDebtAtPoolMeansNoPayment() public {
        uint256 shares = _seedShares(10e18);
        h.addCollateral(address(cfg), address(vault), shares);

        pool.setDebt(0);
        pool.setActualPaid(0);
        pool.setDebtAfterPay(0);

        usdc.mint(address(h), 1e18);
        uint256 excess = h.decreaseTotalDebt(address(cfg), address(vault), 1e18);

        assertEq(excess, 1e18, "all of amount returned as excess");
        assertEq(h.getTotalDebt(), 0);
        assertEq(usdc.balanceOf(address(h)), 1e18, "no USDC pulled");
    }
}
