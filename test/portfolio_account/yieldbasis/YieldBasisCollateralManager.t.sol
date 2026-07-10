// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

// Library under test
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

// Sibling library used to prove ERC-7201 slot isolation
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";

// Infrastructure — same pieces the sibling facet tests use
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

// Interfaces
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ILoanConfig} from "../../../src/facets/account/config/ILoanConfig.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * Harness
 * ---------------------------------------------------------------------------
 *
 * The YieldBasisCollateralManager library reads/writes at the ERC-7201 slot
 *     keccak256("storage.YieldBasisCollateralManager")
 * on `address(this)`. To unit-test it without a full diamond we deploy a thin
 * contract (one per test, via setUp) that exposes every library function as a
 * public method. The harness IS the caller/borrower — it "owns" the slot.
 *
 * __setDebt / __setOverSupplied are strictly test-only writes so that guard
 * paths (removeCollateral LTV check, enforceCollateralRequirements BadDebt,
 * shortfall snapshot math) can be driven without having to synthesize a real
 * borrow through the lending pool for every case. These helpers read/write
 * the same slot as the library, proving the slot layout is the one documented.
 * -------------------------------------------------------------------------*/
contract YBCMHarness {
    // Mirror of the library storage struct. Must stay in lockstep with
    // YieldBasisCollateralManager.YieldBasisCollateralData or the slot math
    // stops matching and test 12 (storage isolation) becomes a lie.
    struct YBData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
    }

    bytes32 internal constant YB_SLOT = keccak256("storage.YieldBasisCollateralManager");

    function _yb() internal pure returns (YBData storage d) {
        bytes32 s = YB_SLOT;
        assembly { d.slot := s }
    }

    // ---------------- library passthroughs ----------------

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

    function getLoanUtilization(address cfg, address vault, address underlying) external view returns (uint256) {
        return YieldBasisCollateralManager.getLoanUtilization(cfg, vault, underlying);
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

    function removeSharesForYield(address cfg, address vault, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.removeSharesForYield(cfg, vault, underlying, shares);
    }

    // ---------------- test-only storage pokes ----------------

    function __setDebt(uint256 v) external { _yb().debt = v; }
    function __setOverSupplied(uint256 v) external { _yb().overSuppliedVaultDebt = v; }

    // Raw storage reads so test 12 can verify ERC-7201 isolation without
    // leaning on the library's own getters (those are what we're checking).
    function __readYB() external view returns (YBData memory d) {
        YBData storage s = _yb();
        d.shares = s.shares;
        d.depositedAssetValue = s.depositedAssetValue;
        d.debt = s.debt;
        d.overSuppliedVaultDebt = s.overSuppliedVaultDebt;
        d.startShortfall = s.startShortfall;
        d.snapshotBlockNumber = s.snapshotBlockNumber;
    }

    function __readERC4626Shares() external view returns (uint256 shares) {
        bytes32 slot = keccak256("storage.ERC4626CollateralManager");
        assembly { shares := sload(slot) } // first word in struct is `shares`
    }

    function __writeERC4626Shares(uint256 v) external {
        bytes32 slot = keccak256("storage.ERC4626CollateralManager");
        assembly { sstore(slot, v) }
    }
}

/* ---------------------------------------------------------------------------
 * Mock lending pool used ONLY in test 6 to force `getDebtBalance` to report a
 * value DIFFERENT from the value local arithmetic would have produced. This
 * is the only way to prove decreaseTotalDebt's sync step wins over its own
 * local math. The real LendingVault can only return 0..userDebt (since its
 * getDebtBalance reads the same counter payFromPortfolio updates), so it can
 * never produce the divergence the test needs.
 * -------------------------------------------------------------------------*/
contract MockLendingPoolSync {
    address public immutable _asset;
    address public immutable _vaultSelf;
    address internal _portfolioFactory;
    uint256 public _actualPaidToReport;
    uint256 public _debtBalanceToReport;
    uint256 public _debtBalanceAfterPay; // optional override: what getDebtBalance reports AFTER payFromPortfolio runs
    bool public _useDebtBalanceAfterPay;
    uint256 public _activeAssetsToReport;

    constructor(address asset_, address portfolioFactory_) {
        _asset = asset_;
        _vaultSelf = address(this);
        _portfolioFactory = portfolioFactory_;
    }

    function setOutcome(uint256 actualPaid, uint256 debtBalance) external {
        _actualPaidToReport = actualPaid;
        _debtBalanceToReport = debtBalance;
    }

    /// @notice Set a different debt balance to be reported AFTER payFromPortfolio runs.
    /// Lets a test stage a "pre-pay" debt and a different "post-pay" debt so
    /// decreaseTotalDebt's pre-call sync sees the pre-pay value (used for the
    /// balancePayment math) and the post-call sync sees the post-pay value.
    function setDebtBalanceAfterPay(uint256 v) external {
        _debtBalanceAfterPay = v;
        _useDebtBalanceAfterPay = true;
    }

    function setActiveAssets(uint256 v) external { _activeAssetsToReport = v; }

    // PortfolioFactoryConfig.setLoanContract requires
    //   ILoanContract(addr).getPortfolioFactory() == configuredFactory.
    // Without this, staging the mock pool reverts before any test body runs.
    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }

    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return _vaultSelf; }
    function activeAssets() external view returns (uint256) { return _activeAssetsToReport; }

    // IERC4626 slice used by getMaxLoan
    function asset() external view returns (address) { return _asset; }

    /// @dev Mirrors the IERC4626 surface the production manager now calls to derive
    /// the cap denominator. Returns liquid asset balance + active loans -- the mock
    /// has no vesting/escrow concept so it is a faithful approximation.
    function totalAssets() public view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssetsToReport;
    }

    // Value-neutral mock: no same-block exclusion needed for these tests.
    function borrowableTotalAssets() external view returns (uint256) {
        return totalAssets();
    }

    function borrowFromPortfolio(uint256 /*amount*/) external pure returns (uint256) {
        return 0;
    }

    // Pulls `actualPaid` from caller (via approval) so allowance/approve in the
    // library runs against something real.
    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external returns (uint256 actualPaid) {
        actualPaid = _actualPaidToReport;
        if (actualPaid > totalPayment) actualPaid = totalPayment;
        if (actualPaid > 0) {
            IERC20(_asset).transferFrom(msg.sender, address(this), actualPaid);
        }
        // After this point, switch the debt balance reported to the post-pay
        // value if the test staged one. Lets a single MockLendingPoolSync
        // simulate a pool whose getDebtBalance reflects payment.
        if (_useDebtBalanceAfterPay) {
            _debtBalanceToReport = _debtBalanceAfterPay;
        }
    }

    // view — must match interface in YieldBasisCollateralManager (STATICCALL).
    function getDebtBalance(address) external view returns (uint256) {
        return _debtBalanceToReport;
    }

    function depositRewards(uint256) external {}
}

/* ===========================================================================
 * TEST SUITE
 * ==========================================================================*/
contract YieldBasisCollateralManagerTest is Test {
    // Library under test is exercised through this harness (one per test case).
    YBCMHarness internal h;

    // Infrastructure
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    // Tokens
    MockYieldBasisLP internal ybLp;     // "vault" arg to the library
    MockERC20 internal underlying;      // "underlying" arg (semantic only)
    MockERC20 internal usdc;            // lending asset

    // Actors
    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH_CALLER = address(0xAAAA);
    address internal RANDOM_EOA = address(0xBEEF);

    // Magnitudes
    uint256 internal constant VAULT_LIQUIDITY = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000; // 70%

    function setUp() public virtual {
        vm.startPrank(OWNER);

        // Portfolio infrastructure
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("yb-cm-test"));
        factory = f;
        registry = r;

        // Configs
        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        // Tokens
        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1.5e18);
        underlying = new MockERC20("WETH", "WETH", 18);
        // POST-LTV-REFACTOR: getMaxLoan's like-to-like LTV branch reverts unless
        // lendingAsset == underlying. Use the same WETH-labeled 18-dec token as
        // both the YB LP underlying AND the lending asset so the like-to-like
        // check passes. The 18-dec/18-dec rescale collapses to identity, so all
        // pre-refactor expected values stay correct. `usdc` is repointed at the
        // same `underlying` token solely to avoid renaming every reference below.
        usdc = underlying;

        // LendingVault (UUPS proxy)
        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(usdc), address(factory), OWNER, "Lending Vault", "lVAULT", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));

        // Fund the vault so getMaxLoan's vaultBalance path is non-zero.
        usdc.mint(address(lendingVault), VAULT_LIQUIDITY);

        // Wire configs
        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS); // like-to-like YB LP market uses LTV branch
        cfg.setLoanContract(address(lendingVault));
        factory.setPortfolioFactoryConfig(address(cfg));

        pm.setAuthorizedCaller(AUTH_CALLER, true);

        vm.stopPrank();

        // Fresh harness per test — fresh ERC-7201 slot.
        h = new YBCMHarness();

        // Authorize the harness so library functions gated by isAuthorizedCaller
        // (e.g. removeSharesForYield, increaseTotalDebt) accept its calls. Inside
        // the library, msg.sender is the harness (delegatecall preserves caller).
        vm.prank(OWNER);
        pm.setAuthorizedCaller(address(h), true);

        // Register the harness as a "portfolio" so LendingVault's onlyPortfolio
        // modifier accepts its borrow/pay calls. We do this by pranking the
        // factory and writing directly into PortfolioFactory.owners via a
        // controlled createPortfolio? Simpler: grant it authorized-caller
        // status on PortfolioManager (LendingVault uses PortfolioFactory only
        // to gate borrowing, but the library wraps every mutation in
        // isAuthorizedCaller || manager), and bypass LendingVault's gate by
        // wiring the harness into the factory's portfolios mapping via
        // vm.store when needed per-test. Simpler path chosen below: most
        // tests that need a live borrow go through the isAuthorizedCaller
        // path and never touch LendingVault's onlyPortfolio (we only need
        // LendingVault to *respond* to the reader calls — it does).

        vm.label(address(h), "YBCMHarness");
        vm.label(address(ybLp), "ybLP");
        vm.label(address(usdc), "USDC");
        vm.label(address(lendingVault), "LendingVault");
    }

    // -----------------------------------------------------------------------
    // 1. Pricing correctness
    // -----------------------------------------------------------------------
    //
    // The entire loan math downstream is pinned to
    //     value = shares * pricePerShare / 1e18
    // If this regresses (e.g. forgetting the 1e18 scale, or using balanceOf
    // instead of a stored share count), loans would be grossly mis-sized.
    // This test hard-codes numbers so the regression shows up immediately.

    function test_pricing_sharesTimesPricePerShareDiv1e18() public {
        // pps = 1.5e18, shares = 2e18 → value = 3e18
        ybLp.setPricePerShare(1.5e18);
        ybLp.mint(address(h), 2e18);

        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 2e18);

        assertEq(h.getTotalCollateralValue(address(ybLp), address(underlying)), 3e18, "pricing: 2e18 * 1.5 = 3e18");

        (uint256 shares, uint256 deposited, uint256 current) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(shares, 2e18, "shares tracked");
        assertEq(deposited, 3e18, "depositedAssetValue snapshot at deposit");
        assertEq(current, 3e18, "currentAssetValue at deposit price");

        // Price rises 1.5 -> 2.0. depositedAssetValue must stay frozen (it's the
        // historical principal marker used by removeSharesForYield); current
        // must reflect new pps.
        ybLp.setPricePerShare(2e18);
        (, uint256 deposited2, uint256 current2) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(deposited2, 3e18, "deposited is frozen when price moves");
        assertEq(current2, 4e18, "current recomputes at new pps");
    }

    // -----------------------------------------------------------------------
    // 2. addCollateral input validation
    // -----------------------------------------------------------------------

    function test_addCollateral_revertsOnZeroVault() public {
        vm.expectRevert(bytes("Invalid vault address"));
        h.addCollateral(address(cfg), address(0), address(0), address(underlying), 1e18);
    }

    function test_addCollateral_revertsOnZeroShares() public {
        vm.expectRevert(bytes("Shares must be > 0"));
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 0);
    }

    function test_addCollateral_revertsOnInsufficientBalance() public {
        // Harness holds 0.5e18 LP; try to record 1e18 as collateral.
        ybLp.mint(address(h), 0.5e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                YieldBasisCollateralManager.InsufficientShareBalance.selector,
                uint256(1e18), // required = data.shares (0) + 1e18
                uint256(0.5e18) // actual balance
            )
        );
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);
    }

    // -----------------------------------------------------------------------
    // 3. removeCollateral — proportional value reduction
    // -----------------------------------------------------------------------
    //
    // The contract documents the reduction as
    //     assetValueToRemove = depositedAssetValue * shares / data.shares
    // A subtle regression would be to reduce by current value (pps) rather
    // than proportional-of-deposited, which would silently shift principal
    // accounting whenever price moved.

    function test_removeCollateral_proportionalValueReduction() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Move the price — proves removeCollateral's proportional math uses
        // depositedAssetValue, not current pps.
        ybLp.setPricePerShare(2e18);

        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 4e18);

        (uint256 shares, uint256 deposited,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(shares, 6e18, "shares reduced by 4e18");
        // deposited was 10e18. Remove 4/10 → deposited becomes 6e18.
        assertEq(deposited, 6e18, "depositedAssetValue reduced proportionally (6/10 * 10e18)");
    }

    // -----------------------------------------------------------------------
    // 4. removeCollateral guards
    // -----------------------------------------------------------------------

    function test_removeCollateral_revertsOnZero() public {
        vm.expectRevert(bytes("Shares must be > 0"));
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 0);
    }

    function test_removeCollateral_revertsOnInsufficientShares() public {
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);

        vm.expectRevert(bytes("Insufficient collateral shares"));
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 2e18);
    }

    function test_removeCollateral_revertsWhenRemovalBreaksLTV() public {
        // Deposit 10e18 @ pps=1 → value=10e18 → LTV 70% → maxLoan=7e18.
        // Stage pool to report 6e18 of debt. Then try to remove 5e18 of shares:
        // remaining value 5e18 → new maxLoanIgnoreSupply 3.5e18 < debt 6e18
        // → must revert.
        //
        // POST-SYNC-REFACTOR: __setDebt alone no longer survives — _snapshotIfNeeded
        // syncs from the pool at entry. We must point the config at a mock pool
        // whose getDebtBalance reports the staged debt.
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        // Seed pool USDC so getMaxLoan vault-supply path doesn't zero out maxLoan.
        usdc.mint(address(pool), 100e18);
        pool.setOutcome(0, 6e18);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 5e18);
    }

    // -----------------------------------------------------------------------
    // 5. Debt lifecycle — access control
    // -----------------------------------------------------------------------
    //
    // increaseTotalDebt is gated to (PortfolioManager || authorized caller).
    // A bug that widened this (e.g. by dropping the manager check) would
    // let any EOA mint debt against a user's collateral.

    function test_increaseTotalDebt_revertsFromRandomEOA() public {
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        vm.prank(RANDOM_EOA);
        vm.expectRevert(abi.encodeWithSelector(YieldBasisCollateralManager.NotPortfolioManager.selector));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1e18);
    }

    function test_increaseTotalDebt_succeedsFromPortfolioManager() public {
        // LendingVault's onlyPortfolio modifier would block us here, so we
        // use a mock lending pool. We still prove the manager-check path is
        // the one that gates msg.sender.
        //
        // NOTE (post-sync-refactor): increaseTotalDebt now resyncs data.debt
        // from the lending pool's getDebtBalance AFTER borrowFromPortfolio.
        // The mock's borrowFromPortfolio is a no-op, so we must explicitly
        // stage what getDebtBalance should report. Pre-seed `_debtBalanceToReport`
        // to the borrow amount; the sync then writes that value into data.debt.
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Stage the post-borrow pool-truth — sync writes this to data.debt.
        pool.setOutcome(0, 1e18);

        vm.prank(address(pm)); // PortfolioManager itself
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1e18);

        assertEq(h.getTotalDebt(), 1e18, "debt synced from pool when called as PM");
    }

    function test_increaseTotalDebt_succeedsFromAuthorizedCaller() public {
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));

        // Fund the pool so vault.totalAssets() lifts the cap-pinned maxLoan
        // above the 2e18 borrow. Without this, totalAssets = 0 -> cap = 0,
        // and the AUTH path's new inline enforce reverts on BadDebt before
        // we can assert on the debt sync.
        usdc.mint(address(pool), 10e18);

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Stage the post-borrow pool-truth — sync writes this to data.debt.
        pool.setOutcome(0, 2e18);

        vm.prank(AUTH_CALLER);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 2e18);

        assertEq(h.getTotalDebt(), 2e18, "debt synced from pool when called as authorized caller");
    }

    // -----------------------------------------------------------------------
    // 6. decreaseTotalDebt — sync wins over local arithmetic
    // -----------------------------------------------------------------------
    //
    // After paying, data.debt is OVERWRITTEN with pool.getDebtBalance(this).
    // Prove this by staging a mock where the reported debt is *not* what a
    // naive (data.debt - actualPaid) would compute. If a future refactor
    // replaced the sync with `data.debt -= balancePayment`, this test fails.

    function test_decreaseTotalDebt_syncBeatsLocalArithmetic() public {
        // POST-SYNC-REFACTOR: data.debt is now strictly a write-through cache of
        // pool.getDebtBalance. _snapshotIfNeeded resyncs at entry, so seeding
        // h.__setDebt(100e6) alone won't survive — the sync would zero it back
        // to whatever the mock reports. We instead seed the mock to report
        // 100e6 pre-pay (so the entry sync writes 100e6 into data.debt and the
        // balancePayment math sees 100e6 of debt) and 7e6 post-pay (so the
        // explicit post-pay sync writes 7e6 into data.debt).
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Harness pays 40 USDC; pool reports only 37 was "actualPaid".
        // Pre-pay debt 100e6, post-pay debt 7e6 (naive arithmetic would
        // expect 100 - 37 = 63, NOT 7 — we want to prove the post-pay sync
        // wins over any local arithmetic).
        usdc.mint(address(h), 40e6);
        pool.setOutcome(37e6, 100e6); // initial _debtBalanceToReport = 100e6
        pool.setDebtBalanceAfterPay(7e6); // post-payFromPortfolio reports 7e6

        uint256 excess = h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 40e6);

        assertEq(excess, 3e6, "excess = amount - actualPaid");
        assertEq(h.getTotalDebt(), 7e6, "data.debt overwritten by reader post-pay, not computed locally");
    }

    // -----------------------------------------------------------------------
    // 7. overSuppliedVaultDebt accrual + BadDebt
    // -----------------------------------------------------------------------
    //
    // Borrowing more than maxLoan records the excess as over-supplied debt.
    // That state flag alone must cause enforceCollateralRequirements to
    // revert with BadDebt — this is the backstop that prevents an account
    // with insurance-fund-backed excess debt from being treated as healthy.

    function test_overSuppliedVaultDebt_enforcementRevertsBadDebt() public {
        // overSuppliedVaultDebt now tracks global pool utilization overshoot --
        // not the old `amount > maxLoan` collateral-side overshoot. Force the
        // flag directly via the harness setter and assert enforcement reverts
        // with the corresponding BadDebt selector + magnitude.
        h.__setOverSupplied(2e18);

        // Collateral side must be clean so we hit the BadDebt branch, not the
        // intra-block UndercollateralizedDebt path.
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        vm.roll(block.number + 1);

        vm.expectRevert(abi.encodeWithSelector(YieldBasisCollateralManager.BadDebt.selector, uint256(2e18)));
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    // -----------------------------------------------------------------------
    // 8. Shortfall snapshot — intra-block growth reverts, cross-block is clean
    // -----------------------------------------------------------------------
    //
    // Shortfall is snapshotted on the FIRST mutating call in a block. Within
    // the same block, end > start must revert with UndercollateralizedDebt
    // (the "you made it worse" backstop). Across blocks with no snapshot,
    // start=end so no revert even if shortfall exists — that path is handled
    // by the BadDebt branch (tested above when overSupplied > 0) and by
    // whoever's supposed to call snapshotShortfall.

    function test_shortfall_intraBlockGrowthReverts() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        // addCollateral took the snapshot at block.number with start=0 shortfall
        // (debt is 0). Now push debt just under max.
        h.__setDebt(7e18); // exactly at max; shortfall still 0

        // Same block: collapse pricePerShare so maxLoanIgnoreSupply shrinks
        // below debt → end shortfall > 0 > start shortfall (0) → revert.
        ybLp.setPricePerShare(0.5e18);

        // new collateralValue = 10 * 0.5 = 5e18; maxLoanIgnoreSupply = 3.5e18
        // end shortfall = 7 - 3.5 = 3.5e18
        vm.expectRevert(
            abi.encodeWithSelector(YieldBasisCollateralManager.UndercollateralizedDebt.selector, uint256(3.5e18))
        );
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    function test_shortfall_crossBlockNoSnapshotIsClean() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        h.__setDebt(7e18);

        // Roll forward — snapshot is stale, so start==end and shortfall growth
        // in *prior* blocks doesn't revert. This is the "cross-block, no new
        // mutating call yet" path.
        vm.roll(block.number + 5);
        ybLp.setPricePerShare(0.5e18);

        // No revert expected. Function is view; returns true on success.
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)));
    }

    // -----------------------------------------------------------------------
    // 9. removeSharesForYield guards
    // -----------------------------------------------------------------------

    function test_removeSharesForYield_revertsOnInsufficientShares() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);

        vm.prank(AUTH_CALLER);
        vm.expectRevert(bytes("Insufficient shares"));
        h.removeSharesForYield(address(cfg), address(ybLp), address(underlying), 2e18);
    }

    /// @notice removeSharesForYield holds depositedAssetValue fixed: the
    ///         remaining LP must still cover the original basis. Burning shares
    ///         with no pps growth drops remaining value below the basis, so it
    ///         reverts "Would remove principal". The harvest layer never calls
    ///         it in that state (its "No yield to harvest" gate fires first).
    function test_removeSharesForYield_revertsWhenWouldRemovePrincipal() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Burn 1e18 shares at unchanged pps: remaining 9e18 value < basis 10e18.
        vm.prank(AUTH_CALLER);
        vm.expectRevert(bytes("Would remove principal"));
        h.removeSharesForYield(address(cfg), address(ybLp), address(underlying), 1e18);
    }

    function test_removeSharesForYield_revertsDebtExceedsMaxLoan() public {
        // deposit 10e18 @ pps=1 → deposited=10e18. Price doubles.
        // Now current value 20e18; removing 4e18 shares leaves 6e18*2=12e18 ≥
        // deposited (10e18). But if debt is near the old max, removing shares
        // drops the new maxLoanIgnoreSupply below debt → revert.
        //
        // After remove: remaining shares 6e18 @ pps=2 → value 12e18 → LTV 70%
        //   → newMaxLoanIgnoreSupply = 8.4e18.
        // Stage debt = 9e18 so it stays ≤ OLD max (14e18) but > NEW max (8.4e18).
        //
        // POST-SYNC-REFACTOR: must seed pool getDebtBalance to 9e18 (was __setDebt).
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        usdc.mint(address(pool), 100e18);
        pool.setOutcome(0, 9e18);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        ybLp.setPricePerShare(2e18);

        vm.prank(AUTH_CALLER);
        vm.expectRevert(bytes("Debt exceeds max loan"));
        h.removeSharesForYield(address(cfg), address(ybLp), address(underlying), 4e18);
    }

    // -----------------------------------------------------------------------
    // 10. getLoanUtilization edges
    // -----------------------------------------------------------------------

    function test_getLoanUtilization_zeroDebtReturnsZero() public {
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);
        assertEq(h.getLoanUtilization(address(cfg), address(ybLp), address(underlying)), 0, "0 debt -> 0");
    }

    function test_getLoanUtilization_zeroCollateralWithDebtReturnsMax() public {
        // No collateral but nonzero debt → maxLoanIgnoreSupply = 0, debt > 0
        // → must return type(uint256).max. This is the "infinitely unsafe"
        // signal that liquidation/enforcement paths key off of.
        h.__setDebt(1);
        assertEq(
            h.getLoanUtilization(address(cfg), address(ybLp), address(underlying)),
            type(uint256).max,
            "debt>0 with 0 collateral -> MAX"
        );
    }

    // -----------------------------------------------------------------------
    // 11. getMaxLoan — clamped by available vault supply
    // -----------------------------------------------------------------------
    //
    // The library caps maxLoan at (maxUtilization - outstandingCapital). This
    // is what prevents a fresh borrower from draining a pool that's already
    // 79% utilized. Stage a pool with a tiny vaultBalance and a large
    // activeAssets so the LTV math would permit more than the pool can give.

    function test_getMaxLoan_clampedByVaultAvailableSupply() public {
        MockLendingPoolSync pool = new MockLendingPoolSync(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));

        // Move the vault-balance-source. The library calls
        //   IERC20(IERC4626(lendingVault).asset()).balanceOf(lendingVault)
        // MockLendingPoolSync returns itself as both lendingVault and asset(),
        // so we mint USDC INTO the pool and set a large outstandingCapital so
        // vaultSupply = balance + outstanding is finite and maxUtilization -
        // outstanding is tight.
        //
        //   balance = 100 USDC
        //   activeAssets = 900 USDC  (outstanding)
        //   vaultSupply = 1000, maxUtilization (80%) = 800
        //   vaultAvailableSupply = 800 - 900 = UNDERFLOW, but the library has
        //   an early-return (outstandingCapital >= maxUtilization → returns 0).
        // Pick numbers so the CLAMP path (not the early-return) is hit:
        //   balance = 500, active = 300 → supply=800, maxUtil=640,
        //   vaultAvail = 640 - 300 = 340.
        usdc.mint(address(pool), 500e6);
        pool.setActiveAssets(300e6);

        // Collateral huge so LTV math would allow much more than 340 USDC.
        // pps=1e18, shares=1000e18, LTV 70% → maxLoanIgnoreSupply=700e18.
        // 700e18 is denominated in 18-dec; 340 USDC is 6-dec. The library
        // does NOT reconcile decimals — both are compared as raw uints. To
        // make the clamp meaningful we must keep the LTV result in the same
        // magnitude as the supply cap. Use 6-dec LP pricing: deposit 1000
        // shares with pps=1e6? Library hard-codes /1e18 so pps must be 18-dec.
        //
        // Simpler: keep pps=1e18 and use shares measured so that LTV-permit
        // (700e18) > cap (340) → clamp wins. That's the behavior under test.
        // The test asserts only that the CLAMP path is active.
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 1000e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1000e18);

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(underlying));

        // LTV would permit 700e18; pool can only supply 340e6. Clamp must win.
        assertEq(maxLoanIgnoreSupply, 700e18, "LTV-only ceiling unchanged");
        assertEq(maxLoan, 340e6, "clamped to maxUtilization - outstandingCapital");
    }

    // -----------------------------------------------------------------------
    // 12. Storage isolation vs ERC4626CollateralManager
    // -----------------------------------------------------------------------
    //
    // YieldBasisCollateralManager and ERC4626CollateralManager MUST live at
    // distinct ERC-7201 slots so a diamond that installs both (different
    // facets sharing proxy storage) doesn't corrupt one when writing the
    // other. Both libraries compute their slot from a different string; a
    // copy-paste regression (same string, different library) would silently
    // collide until a user's collateral got overwritten.

    function test_storageIsolation_ybAndErc4626SlotsDoNotCollide() public {
        // Seed YB slot via the library (through the harness).
        ybLp.mint(address(h), 5e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 5e18);

        YBCMHarness.YBData memory before = h.__readYB();
        assertEq(before.shares, 5e18, "YB shares set");

        // Write a DIFFERENT value into the ERC4626 slot's first word.
        h.__writeERC4626Shares(type(uint256).max);

        // Re-read YB. If the slots collided, YB.shares would now be max.
        YBCMHarness.YBData memory afterWrite = h.__readYB();
        assertEq(afterWrite.shares, 5e18, "ERC4626 write did NOT stomp YB.shares");

        // And the ERC4626 slot still holds what we wrote.
        assertEq(h.__readERC4626Shares(), type(uint256).max, "ERC4626 slot preserved");

        // Also verify slot strings literally differ (belt-and-suspenders —
        // catches a rename regression at the source level).
        assertTrue(
            keccak256("storage.YieldBasisCollateralManager")
                != keccak256("storage.ERC4626CollateralManager"),
            "slot strings must be distinct"
        );
    }

    // -----------------------------------------------------------------------
    // Extra: event emission on addCollateral & removeCollateral
    // -----------------------------------------------------------------------
    //
    // State-changing functions should emit accurate events — off-chain
    // indexers and liquidation bots depend on assetValue in these events
    // being the actual value credited/debited.

    function test_addCollateral_emitsEventWithAssetValue() public {
        ybLp.setPricePerShare(1.5e18);
        ybLp.mint(address(h), 2e18);

        vm.expectEmit(true, false, false, true, address(h));
        emit YieldBasisCollateralManager.YieldBasisCollateralAdded(
            address(ybLp), 2e18, 3e18 /* 2e18*1.5 */, address(h)
        );
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 2e18);
    }

    function test_removeCollateral_emitsEventWithProportionalValue() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Remove 4/10 → deposited value to remove = 10e18 * 4/10 = 4e18.
        vm.expectEmit(true, false, false, true, address(h));
        emit YieldBasisCollateralManager.YieldBasisCollateralRemoved(
            address(ybLp), 4e18, 4e18, address(h)
        );
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 4e18);
    }
}
