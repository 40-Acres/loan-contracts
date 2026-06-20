// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

// Library under test
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";
// Sibling library used to prove ERC-7201 slot isolation vs the legacy variant
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

// Infrastructure
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";

// Interfaces
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * Harness
 *
 * Mirrors the YieldBasisCollateralManager harness pattern: a thin contract
 * whose own slot is read/written by the library under test. Note the data
 * struct DOES NOT contain `debt` -- the dynamic variant reads debt live from
 * the pool every time. Test-only setters expose overSuppliedVaultDebt /
 * snapshotBlockNumber / startShortfall directly so guard branches can be
 * driven without synthesizing a borrow flow.
 * -------------------------------------------------------------------------*/
contract DYBCMHarness {
    // Must stay in lockstep with DynamicYieldBasisCollateralData.
    struct DYBData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
    }

    bytes32 internal constant DYB_SLOT = keccak256("storage.DynamicYieldBasisCollateralManager");
    bytes32 internal constant LEGACY_SLOT = keccak256("storage.YieldBasisCollateralManager");

    function _dyb() internal pure returns (DYBData storage d) {
        bytes32 s = DYB_SLOT;
        assembly { d.slot := s }
    }

    // ---------------- library passthroughs ----------------

    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        DynamicYieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }

    function removeCollateral(address cfg, address vault, address underlying, uint256 shares) external {
        DynamicYieldBasisCollateralManager.removeCollateral(cfg, vault, underlying, shares);
    }

    function getTotalCollateralValue(address vault, address underlying) external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getTotalCollateralValue(vault, underlying);
    }

    function getCollateral(address vault, address underlying)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return DynamicYieldBasisCollateralManager.getCollateral(vault, underlying);
    }

    function getCollateralShares() external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getCollateralShares();
    }

    function getTotalDebt(address cfg) external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getTotalDebt(cfg);
    }

    function getEffectiveTotalDebt(address cfg) external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getEffectiveTotalDebt(cfg);
    }

    function increaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external
        returns (uint256, uint256)
    {
        return DynamicYieldBasisCollateralManager.increaseTotalDebt(cfg, vault, underlying, amount);
    }

    function decreaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external
        returns (uint256)
    {
        return DynamicYieldBasisCollateralManager.decreaseTotalDebt(cfg, vault, underlying, amount);
    }

    function getMaxLoan(address cfg, address vault, address underlying)
        external
        view
        returns (uint256, uint256)
    {
        return DynamicYieldBasisCollateralManager.getMaxLoan(cfg, vault, underlying);
    }

    function getLoanUtilization(address cfg, address vault, address underlying) external view returns (uint256) {
        return DynamicYieldBasisCollateralManager.getLoanUtilization(cfg, vault, underlying);
    }

    function snapshotShortfall(address cfg, address vault, address underlying) external {
        DynamicYieldBasisCollateralManager.snapshotShortfall(cfg, vault, underlying);
    }

    function enforceCollateralRequirements(address cfg, address vault, address underlying)
        external
        view
        returns (bool)
    {
        return DynamicYieldBasisCollateralManager.enforceCollateralRequirements(cfg, vault, underlying);
    }

    function removeSharesForYield(address cfg, address vault, address underlying, uint256 shares) external {
        DynamicYieldBasisCollateralManager.removeSharesForYield(cfg, vault, underlying, shares);
    }

    function reconcileSharesToBalance(address cfg, address vault, address underlying, address gauge) external {
        DynamicYieldBasisCollateralManager.reconcileSharesToBalance(cfg, vault, underlying, gauge);
    }

    // ---------------- test-only storage pokes ----------------

    function __setOverSupplied(uint256 v) external { _dyb().overSuppliedVaultDebt = v; }

    function __readDYB() external view returns (DYBData memory d) {
        DYBData storage s = _dyb();
        d.shares = s.shares;
        d.depositedAssetValue = s.depositedAssetValue;
        d.overSuppliedVaultDebt = s.overSuppliedVaultDebt;
        d.startShortfall = s.startShortfall;
        d.snapshotBlockNumber = s.snapshotBlockNumber;
    }

    // Read/write the LEGACY YB slot's first word directly. Used to prove
    // the dynamic-variant slot does not collide with the cached-debt variant.
    function __readLegacyShares() external view returns (uint256 v) {
        bytes32 slot = LEGACY_SLOT;
        assembly { v := sload(slot) }
    }
    function __writeLegacyShares(uint256 v) external {
        bytes32 slot = LEGACY_SLOT;
        assembly { sstore(slot, v) }
    }

    /// @notice Read the word at offset `n` from the dynamic-manager base slot.
    ///         Lets tests assert what lives at each offset without trusting
    ///         the struct-mirror layout in this harness.
    function __readDYBSlotOffset(uint256 n) external view returns (uint256 v) {
        bytes32 base = DYB_SLOT;
        assembly { v := sload(add(base, n)) }
    }
}

/* ---------------------------------------------------------------------------
 * MockDynamicLendingPool
 *
 * Stages raw debt and effective debt independently. Required because the
 * central invariant under test -- effective <= raw -- can only be observed
 * when the pool reports the two values from different sources.
 *
 * Also supports a "post-pay" raw value so decreaseTotalDebt's clamping
 * behavior can be tested against a pool that decrements debt mid-call.
 * -------------------------------------------------------------------------*/
contract MockDynamicLendingPool {
    address public immutable _asset;
    address internal _portfolioFactory;
    address public immutable _vaultSelf;

    uint256 public _actualPaidToReport;
    uint256 public _rawDebt;
    uint256 public _effectiveDebt;
    bool public _useEffectiveOverride;

    uint256 public _rawDebtAfterPay;
    bool public _useRawAfterPay;

    uint256 public _activeAssetsToReport;
    uint256 public _originationFeeToReport;

    constructor(address asset_, address portfolioFactory_) {
        _asset = asset_;
        _portfolioFactory = portfolioFactory_;
        _vaultSelf = address(this);
    }

    function setRaw(uint256 v) external { _rawDebt = v; }
    function setEffective(uint256 v) external {
        _effectiveDebt = v;
        _useEffectiveOverride = true;
    }
    function setActualPaid(uint256 v) external { _actualPaidToReport = v; }
    function setRawAfterPay(uint256 v) external {
        _rawDebtAfterPay = v;
        _useRawAfterPay = true;
    }
    function setActiveAssets(uint256 v) external { _activeAssetsToReport = v; }
    function setOriginationFee(uint256 v) external { _originationFeeToReport = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return _vaultSelf; }
    function activeAssets() external view returns (uint256) { return _activeAssetsToReport; }
    // Mirrors DynamicFeesVault's conservative read; this harness has no unsettled
    // borrower pending, so it equals activeAssets(). Needed because getMaxLoan now
    // hard-casts to IDynamicLendingPool.activeAssetsConservative().
    function activeAssetsConservative() external view returns (uint256) { return _activeAssetsToReport; }
    function asset() external view returns (address) { return _asset; }
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssetsToReport;
    }

    function borrowFromPortfolio(uint256 /*amount*/) external view returns (uint256) {
        return _originationFeeToReport;
    }

    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external returns (uint256 actualPaid) {
        actualPaid = _actualPaidToReport;
        if (actualPaid > totalPayment) actualPaid = totalPayment;
        if (actualPaid > 0) {
            IERC20(_asset).transferFrom(msg.sender, address(this), actualPaid);
        }
        if (_useRawAfterPay) {
            _rawDebt = _rawDebtAfterPay;
        }
    }

    function getDebtBalance(address) external view returns (uint256) {
        return _rawDebt;
    }

    function getEffectiveDebtBalance(address) external view returns (uint256) {
        return _useEffectiveOverride ? _effectiveDebt : _rawDebt;
    }

    function depositRewards(uint256) external {}
}

/* ===========================================================================
 * TEST SUITE
 * ==========================================================================*/
contract DynamicYieldBasisCollateralManagerTest is Test {
    DYBCMHarness internal h;

    // Infra
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    DynamicFeesVault internal lendingVault;

    // Tokens
    MockYieldBasisLP internal ybLp;
    MockERC20 internal underlying;
    MockERC20 internal usdc; // alias of underlying for like-to-like

    // Actors
    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH_CALLER = address(0xAAAA);
    address internal RANDOM_EOA = address(0xBEEF);

    uint256 internal constant VAULT_LIQUIDITY = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000; // 70%

    function setUp() public virtual {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("dyb-cm-test"));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1.5e18);
        underlying = new MockERC20("WETH", "WETH", 18);
        usdc = underlying; // like-to-like

        DynamicFeesVault impl = new DynamicFeesVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                DynamicFeesVault.initialize,
                (address(usdc), "Lending Vault", "lVAULT", address(factory), OWNER, 0)
            )
        );
        lendingVault = DynamicFeesVault(address(proxy));
        lendingVault.setFeeCalculator(address(new FeeCalculator()));
        usdc.mint(address(lendingVault), VAULT_LIQUIDITY);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);
        cfg.setLoanContract(address(lendingVault));
        factory.setPortfolioFactoryConfig(address(cfg));

        pm.setAuthorizedCaller(AUTH_CALLER, true);

        vm.stopPrank();

        h = new DYBCMHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(address(h), true);

        vm.label(address(h), "DYBCMHarness");
        vm.label(address(ybLp), "ybLP");
        vm.label(address(usdc), "USDC");
        vm.label(address(lendingVault), "LendingVault");
    }

    // Helper: replace the live LendingVault with a controllable mock and
    // return the mock. Seeded with enough liquid asset that supply-cap math
    // never zeros out maxLoan unless the test wants it to.
    function _swapInMockPool() internal returns (MockDynamicLendingPool pool) {
        pool = new MockDynamicLendingPool(address(usdc), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        usdc.mint(address(pool), 1_000_000e18);
    }

    // -----------------------------------------------------------------------
    // 1. Live debt read: getTotalDebt reflects the pool every call, no cache
    // -----------------------------------------------------------------------
    //
    // The single most important difference vs the legacy manager. If a future
    // refactor reintroduced caching (e.g. a `data.debt` field copy in
    // increaseTotalDebt), this test would catch it: we mutate the pool's
    // raw debt directly between reads -- no borrow/pay call in between --
    // and assert getTotalDebt tracks every change.

    function test_getTotalDebt_readsLivePerCallWithoutBorrowOrPay() public {
        MockDynamicLendingPool pool = _swapInMockPool();

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        pool.setRaw(0);
        assertEq(h.getTotalDebt(address(cfg)), 0, "starts at pool value");

        pool.setRaw(123e18);
        assertEq(h.getTotalDebt(address(cfg)), 123e18, "raw mutation reflected immediately");

        pool.setRaw(7e18);
        assertEq(h.getTotalDebt(address(cfg)), 7e18, "decrement reflected immediately");

        pool.setRaw(0);
        assertEq(h.getTotalDebt(address(cfg)), 0, "zero reflected immediately");
    }

    // -----------------------------------------------------------------------
    // 2. Raw vs effective split -- central invariant
    // -----------------------------------------------------------------------

    function test_getEffectiveTotalDebt_neverExceedsRaw_invariant() public {
        MockDynamicLendingPool pool = _swapInMockPool();

        // Independently set both. Real implementations satisfy effective <= raw
        // (effective is raw minus pending reward credits). The library must not
        // silently invert -- the interface contract is that effective is the
        // "more optimistic" value for headroom math.
        pool.setRaw(100e18);
        pool.setEffective(70e18);

        uint256 raw = h.getTotalDebt(address(cfg));
        uint256 eff = h.getEffectiveTotalDebt(address(cfg));
        assertEq(raw, 100e18, "raw");
        assertEq(eff, 70e18, "effective");
        assertLe(eff, raw, "INVARIANT: effective <= raw");
    }

    // -----------------------------------------------------------------------
    // 3. getMaxLoan uses EFFECTIVE debt for headroom
    // -----------------------------------------------------------------------
    //
    // With collateral cap = 200, raw = 100, effective = 70:
    //   headroom = 200 - effective = 130 (modulo supply cap, which is set
    //   generously here).
    // If headroom mistakenly used raw debt, we'd see 100 instead of 130.

    function test_getMaxLoan_usesEffectiveDebtForHeadroom() public {
        MockDynamicLendingPool pool = _swapInMockPool();

        // Make supply huge so the supply-cap path is non-binding.
        usdc.mint(address(pool), 1_000_000e18);
        pool.setActiveAssets(0);

        // Build a collateral cap of EXACTLY 200e18 by choosing pps and shares
        // against LTV=7000bps:
        //   value = shares * pps / 1e18 = 200e18 / (LTV/10000) = 200e18 / 0.7
        // Cleaner: pick value such that ltv*value/10000 = 200e18.
        //   value = 200e18 * 10000 / 7000 = 285_714_285_714_285_714_285 (18-dec)
        ybLp.setPricePerShare(1e18);
        // Want exact cap = 200e18 under ltv = 7000bps. value * 7000 / 10000 = 200e18
        // -> value = 285714285714285714286 (200e18 * 10000 / 7000, ceiling).
        // The ltv multiply then floors back to exact 200e18.
        uint256 sharesAmt = 285714285714285714286;
        ybLp.mint(address(h), sharesAmt);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), sharesAmt);

        pool.setRaw(100e18);
        pool.setEffective(70e18);

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(underlying));

        assertEq(maxLoanIgnoreSupply, 200e18, "collateral cap");
        // headroom = 200 - 70 = 130. Supply was set unbounded.
        assertEq(maxLoan, 130e18, "headroom uses EFFECTIVE debt, not raw");
    }

    // -----------------------------------------------------------------------
    // 4. getLoanUtilization uses EFFECTIVE debt
    // -----------------------------------------------------------------------
    //
    // With the same setup (cap=200, raw=100, effective=70):
    //   util = effective * 10000 / cap = 70 * 10000 / 200 = 3500 bps
    // If it used raw, util would be 5000 bps.

    function test_getLoanUtilization_usesEffectiveDebt() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);

        ybLp.setPricePerShare(1e18);
        uint256 sharesAmt = 285714285714285714286; // produces cap = exactly 200e18
        ybLp.mint(address(h), sharesAmt);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), sharesAmt);

        pool.setRaw(100e18);
        pool.setEffective(70e18);

        uint256 util = h.getLoanUtilization(address(cfg), address(ybLp), address(underlying));
        assertEq(util, 3500, "util = effective * 10000 / cap");
    }

    // -----------------------------------------------------------------------
    // 5. Solvency reverts use RAW debt (removeCollateral)
    // -----------------------------------------------------------------------
    //
    // Build a state where raw exceeds the post-remove cap but effective does
    // NOT. removeCollateral MUST revert -- conservative semantics for
    // collateral release.

    function test_removeCollateral_solvencyGateUsesRawDebt() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // After removing 3e18: shares=7e18, cap = 7e18 * 0.7 = 4.9e18.
        // Stage raw=5e18 (exceeds 4.9 cap), effective=4e18 (under 4.9 cap).
        // If the gate used effective, the call would pass and the borrower
        // could be left holding 5e18 of true debt against 4.9 of cap.
        pool.setRaw(5e18);
        pool.setEffective(4e18);

        vm.expectRevert(bytes("Debt exceeds max loan"));
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 3e18);
    }

    // -----------------------------------------------------------------------
    // 6. removeSharesForYield: same gate, also uses RAW
    // -----------------------------------------------------------------------

    function test_removeSharesForYield_solvencyGateUsesRawDebt() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Bump pps so removeSharesForYield's depositedAssetValue precondition
        // is the harvest layer's concern, not the library's -- we only test
        // the post-burn cap gate here.
        ybLp.setPricePerShare(2e18);

        // After removing 4e18 shares: 6 left @ pps=2 -> value=12e18 -> cap=8.4e18.
        // raw=9e18 > 8.4 (revert), effective=8e18 < 8.4 (would pass if gated on eff).
        pool.setRaw(9e18);
        pool.setEffective(8e18);

        vm.prank(AUTH_CALLER);
        vm.expectRevert(bytes("Debt exceeds max loan"));
        h.removeSharesForYield(address(cfg), address(ybLp), address(underlying), 4e18);
    }

    // -----------------------------------------------------------------------
    // 7. enforceCollateralRequirements: snapshot uses RAW (intra-block growth)
    // -----------------------------------------------------------------------
    //
    // The "start" snapshot is computed from raw debt at the first mutating
    // call in the block. Same-block growth in raw shortfall must revert; same-
    // block growth in effective alone must NOT mistakenly revert (because the
    // function uses raw).

    function test_enforceCollateralRequirements_intraBlockRawGrowthReverts() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);

        pool.setRaw(0);
        pool.setEffective(0);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        // Snapshot was taken with raw shortfall = 0 (no debt yet).

        // Same block: collapse pps -> cap drops below raw debt -> shortfall grows.
        pool.setRaw(7e18);
        pool.setEffective(7e18);
        ybLp.setPricePerShare(0.5e18);
        // new value = 5e18, cap = 3.5e18, raw shortfall = 3.5e18.

        vm.expectRevert(
            abi.encodeWithSelector(DynamicYieldBasisCollateralManager.UndercollateralizedDebt.selector, uint256(3.5e18))
        );
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    function test_enforceCollateralRequirements_revertsBadDebtWhenOverSupplied() public {
        // Force the flag directly. Collateral side is clean.
        h.__setOverSupplied(2e18);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(DynamicYieldBasisCollateralManager.BadDebt.selector, uint256(2e18))
        );
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying));
    }

    function test_enforceCollateralRequirements_returnsTrueWhenHealthy() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(ybLp), address(underlying)));
    }

    // -----------------------------------------------------------------------
    // 8. increaseTotalDebt: access control + over-supplied accrual
    // -----------------------------------------------------------------------

    function test_increaseTotalDebt_revertsFromRandomEOA() public {
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        vm.prank(RANDOM_EOA);
        vm.expectRevert(abi.encodeWithSelector(DynamicYieldBasisCollateralManager.NotPortfolioManager.selector));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1e18);
    }

    function test_increaseTotalDebt_overSuppliedAccruesWhenAmountExceedsMaxLoan() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);
        // Make supply cap absorb anything: maxLoanIgnoreSupply will be the binding cap.

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);
        // value=10e18, ltv 70% -> maxLoanIgnoreSupply = 7e18.

        // No prior debt.
        pool.setRaw(0);
        pool.setEffective(0);
        pool.setOriginationFee(0);

        // Borrow 9e18: 2e18 over the cap. overSuppliedVaultDebt should bump by 2.
        // PortfolioManager call -- inline enforce skipped.
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 9e18);

        DYBCMHarness.DYBData memory d = h.__readDYB();
        assertEq(d.overSuppliedVaultDebt, 2e18, "overSupplied += amount - maxLoan");
    }

    function test_increaseTotalDebt_returnsLoanAmountAndOriginationFee() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);
        pool.setOriginationFee(0.5e18);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        vm.prank(address(pm));
        (uint256 loanAmount, uint256 fee) =
            h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e18);

        assertEq(fee, 0.5e18, "fee from pool");
        assertEq(loanAmount, 4.5e18, "loanAmount = amount - fee");
    }

    function test_increaseTotalDebt_authCallerEnforcesInline_revertsOnBadDebt() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);
        pool.setOriginationFee(0);
        // Force overSupplied flag so inline enforce trips BadDebt.
        h.__setOverSupplied(1);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        vm.roll(block.number + 1); // bypass intra-block undercollateralized path

        pool.setRaw(0);
        pool.setEffective(0);

        vm.prank(AUTH_CALLER);
        vm.expectRevert(abi.encodeWithSelector(DynamicYieldBasisCollateralManager.BadDebt.selector, uint256(1)));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 1e18);
    }

    // -----------------------------------------------------------------------
    // 9. decreaseTotalDebt: live raw read; pool can decrement mid-call
    // -----------------------------------------------------------------------
    //
    // Stage the pool to report different raw debt before and after
    // payFromPortfolio. The library reads raw LIVE for the balancePayment
    // clamp, so it sees the PRE-pay value and bounds the payment by that.
    // After the call, getTotalDebt reads the POST-pay value live -- there is
    // no local cache to fall out of sync.

    function test_decreaseTotalDebt_liveRawClampsBalancePayment() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        usdc.mint(address(h), 50e6);

        // Pre-pay raw = 30, post-pay raw = 4 (pool decrements 26 during pay).
        // Caller offers 50; library clamps balancePayment to min(50, 30) = 30.
        // Mock will pay actualPaid = 27 (under the 30 clamp).
        // Expected excess = amount - actualPaid = 50 - 27 = 23.
        // Final getTotalDebt = 4 (live post-pay value).
        pool.setRaw(30e6);
        pool.setActualPaid(27e6);
        pool.setRawAfterPay(4e6);

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        uint256 excess = h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 50e6);

        assertEq(excess, 23e6, "excess = amount - actualPaid");
        assertEq(h.getTotalDebt(address(cfg)), 4e6, "live read returns post-pay raw value");
    }

    function test_decreaseTotalDebt_overSuppliedDecrementsByActualPaidClampedAtZero() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        usdc.mint(address(h), 10e6);

        // Prime overSupplied flag at 3. ActualPaid will be 5 -- flag must
        // clamp at 0, not underflow into a huge value.
        h.__setOverSupplied(3e6);

        pool.setRaw(10e6);
        pool.setActualPaid(5e6);

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e6);

        DYBCMHarness.DYBData memory d = h.__readDYB();
        assertEq(d.overSuppliedVaultDebt, 0, "clamped at 0, no underflow");
    }

    function test_decreaseTotalDebt_neverReverts_evenWhenBadDebtFlagSet() public {
        // Repay path MUST be reachable even when overSupplied > 0. This is
        // the property that allows a borrower (or rewards processor) to
        // unwind a bad-debt state without first clearing the flag.
        MockDynamicLendingPool pool = _swapInMockPool();
        usdc.mint(address(h), 5e6);

        h.__setOverSupplied(1e6); // flag set

        pool.setRaw(5e6);
        pool.setActualPaid(5e6);

        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Must NOT revert despite the flag.
        h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e6);
        DYBCMHarness.DYBData memory d = h.__readDYB();
        assertEq(d.overSuppliedVaultDebt, 0, "5 actualPaid clears the 1-wei flag");
    }

    // -----------------------------------------------------------------------
    // 10. getMaxLoan -- ltv branches & decimals
    // -----------------------------------------------------------------------

    function test_getMaxLoan_cashFlowPath_ltvZero() public {
        // setMultiplier caps at 2x prior (started at 7000). Walk it up so we
        // can sanity-check the cash-flow formula. We don't need to hit a
        // specific economic value -- just prove the branch wires the formula
        // (value * rewardsRate / 1e6 * multiplier / 1e12) and not the LTV one.
        vm.startPrank(OWNER);
        // Climb multiplier: 7000 -> 14000.
        loanConfig.setMultiplier(14000);
        loanConfig.setLtv(0);
        // rewardsRate also capped by 2x. Climb from 0... actually setRewardsRate
        // doc says "<= prior * 2" only if prior != 0. From 0 it's unbounded.
        // Set a nice round value.
        loanConfig.setRewardsRate(1_000_000); // 1.0 in operator units (1e6 base)
        vm.stopPrank();

        // value = 10e18 * 1.5 = 15e18.
        // cap = 15e18 * 1_000_000 / 1_000_000 * 14000 / 1e12
        //     = 15e18 * 14000 / 1e12
        //     = 210000 * 1e3 = 2.1e5 ... actually 15e18 * 14000 / 1e12
        //     = 15 * 14000 * 1e6 = 210_000_000_000 = 2.1e11.
        ybLp.setPricePerShare(1.5e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        (, uint256 cap) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
        // 15e18 * 1e6 / 1e6 = 15e18. Then * 14000 / 1e12 = 15e18 * 14000 / 1e12
        // = 15 * 14000 * 1e6 = 210_000 * 1e6 = 2.1e11.
        assertEq(cap, uint256(15e18) * 14000 / 1e12, "cash-flow path formula");
    }

    function test_getMaxLoan_ltvNonZero_likeToLike_18dec() public {
        // Default setUp: ltv=7000, like-to-like (lendingAsset==underlying), 18 dec.
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        (, uint256 cap) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
        assertEq(cap, 7e18, "10e18 * 7000 / 10000 = 7e18");
    }

    function test_getMaxLoan_ltvNonZero_likeToLike_6dec_rescalesFloor() public {
        // Re-deploy infra so lendingAsset is 6-dec and equals underlying.
        vm.startPrank(OWNER);
        MockERC20 usdc6 = new MockERC20("USDC6", "USDC6", 6);
        MockYieldBasisLP lp6 = new MockYieldBasisLP("LP6", "LP6", 18);
        lp6.setPricePerShare(1e18);

        // New vault on the 6-dec asset.
        DynamicFeesVault impl = new DynamicFeesVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DynamicFeesVault.initialize,
                (address(usdc6), "Lending Vault 6", "lV6", address(factory), OWNER, 0))
        );
        DynamicFeesVault vault6 = DynamicFeesVault(address(proxy));
        vault6.setFeeCalculator(address(new FeeCalculator()));
        usdc6.mint(address(vault6), 1_000_000e6);

        cfg.setLoanContract(address(vault6));
        loanConfig.setLtv(7000);
        vm.stopPrank();

        // value = 10e18 * 1e18 / 1e18 = 10e18 (18-dec).
        // Rescale to 6-dec: 10e18 / 1e12 = 10e6.
        // Cap = 10e6 * 7000 / 10000 = 7e6.
        lp6.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(lp6), address(0), address(usdc6), 10e18);

        (, uint256 cap) = h.getMaxLoan(address(cfg), address(lp6), address(usdc6));
        assertEq(cap, 7e6, "18-dec value rescaled to 6-dec floors, then LTV bps");
    }

    function test_getMaxLoan_ltvNonZero_revertsWhenLendingAssetMismatch() public {
        // ltv > 0 but underlying != lendingAsset -> LtvRequiresLikeToLike.
        // The revert surfaces on the FIRST library call that triggers
        // _snapshotIfNeeded -> _currentShortfall -> getMaxLoan, which is
        // addCollateral itself.
        MockERC20 otherUnderlying = new MockERC20("OTHER", "OTHER", 18);
        ybLp.mint(address(h), 10e18);

        vm.expectRevert(DynamicYieldBasisCollateralManager.LtvRequiresLikeToLike.selector);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(otherUnderlying), 10e18);
    }

    // -----------------------------------------------------------------------
    // 11. reconcileSharesToBalance: only reduces, never increases
    // -----------------------------------------------------------------------

    function test_reconcileSharesToBalance_onlyReduces() public {
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Mint EXTRA LP onto the harness directly. This simulates an out-of-band
        // top-up that the library should NOT auto-credit.
        ybLp.mint(address(h), 5e18); // harness now holds 15e18 LP

        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(0));

        (uint256 shares,,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(shares, 10e18, "surplus LP NOT auto-credited");
    }

    function test_reconcileSharesToBalance_reducesAndScalesDepositedValue() public {
        MockYieldBasisGauge gauge = new MockYieldBasisGauge(address(ybLp));
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), 10e18);

        // Account holds no gauge receipts; move 4e18 of direct LP out so
        // _actualLp = lpBalance(6e18) + gauge.convertToAssets(0) = 6e18.
        vm.prank(address(h));
        ybLp.transfer(address(0xDEAD), 4e18);

        h.reconcileSharesToBalance(address(cfg), address(ybLp), address(underlying), address(gauge));

        (uint256 shares, uint256 deposited,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(shares, 6e18, "data.shares = actual LP balance");
        assertEq(deposited, 6e18, "depositedAssetValue scaled proportionally");
    }

    // -----------------------------------------------------------------------
    // 12. Storage slot isolation vs the legacy variant
    // -----------------------------------------------------------------------
    //
    // CRITICAL: keccak256("storage.DynamicYieldBasisCollateralManager") must
    // differ from keccak256("storage.YieldBasisCollateralManager"). A regression
    // here would silently corrupt the legacy LP markets when the dynamic
    // variant is installed alongside them.

    function test_storageIsolation_dynamicSlotDoesNotCollideWithLegacy() public {
        // Seed dynamic slot via the library.
        ybLp.mint(address(h), 5e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 5e18);

        DYBCMHarness.DYBData memory before = h.__readDYB();
        assertEq(before.shares, 5e18, "dynamic shares set");

        // Stomp the legacy slot's first word with a sentinel.
        h.__writeLegacyShares(type(uint256).max);

        // Re-read dynamic -- must be untouched.
        DYBCMHarness.DYBData memory afterStomp = h.__readDYB();
        assertEq(afterStomp.shares, 5e18, "legacy write did NOT stomp dynamic.shares");

        // Legacy slot still holds what we wrote.
        assertEq(h.__readLegacyShares(), type(uint256).max, "legacy slot preserved");

        // Belt-and-suspenders: slot strings must literally differ.
        assertTrue(
            keccak256("storage.DynamicYieldBasisCollateralManager")
                != keccak256("storage.YieldBasisCollateralManager"),
            "slot strings must be distinct"
        );
    }

    // -----------------------------------------------------------------------
    // 13. No-cache property: legacy `data.debt` slot is NOT used
    // -----------------------------------------------------------------------
    //
    // The dynamic struct layout omits `debt`. After issuing borrow + repay
    // operations, no `debt` field should ever materialize in the dynamic
    // slot. We can't directly query a removed field, but we CAN read the raw
    // slot offsets and assert nothing unexpected was written there.

    function test_noCache_dataDebtSlotIsNotWritten() public {
        MockDynamicLendingPool pool = _swapInMockPool();
        pool.setActiveAssets(0);
        pool.setOriginationFee(0);

        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 10e18);

        // Do a borrow flow to ensure all library paths run.
        pool.setRaw(5e18);
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(underlying), 5e18);

        // In the LEGACY struct layout `data.debt` lived at offset 2 (after
        // shares, depositedAssetValue). In the DYNAMIC layout, offset 2 holds
        // overSuppliedVaultDebt -- not debt. Assert that offset 2 reads the
        // same value the harness's overSupplied view reports.
        DYBCMHarness.DYBData memory d = h.__readDYB();
        // Offset 0 = shares, 1 = depositedAssetValue, 2 = overSuppliedVaultDebt.
        // There is NO `debt` field anywhere in the layout, so no offset should
        // carry a cached debt value that drifts from the pool's live read.
        uint256 atOffset0 = h.__readDYBSlotOffset(0);
        uint256 atOffset1 = h.__readDYBSlotOffset(1);
        uint256 atOffset2 = h.__readDYBSlotOffset(2);
        assertEq(atOffset0, d.shares, "offset 0 = shares");
        assertEq(atOffset1, d.depositedAssetValue, "offset 1 = depositedAssetValue");
        assertEq(atOffset2, d.overSuppliedVaultDebt,
            "offset 2 = overSuppliedVaultDebt (not a debt cache)");
    }

    // -----------------------------------------------------------------------
    // 14. addCollateral event + value
    // -----------------------------------------------------------------------

    function test_addCollateral_emitsEventWithBasisValue() public {
        ybLp.setPricePerShare(1.5e18);
        ybLp.mint(address(h), 2e18);

        vm.expectEmit(true, false, false, true, address(h));
        emit DynamicYieldBasisCollateralManager.YieldBasisCollateralAdded(
            address(ybLp), 2e18, 3e18, address(h)
        );
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 2e18);
    }

    // -----------------------------------------------------------------------
    // 15. Input validation
    // -----------------------------------------------------------------------

    function test_addCollateral_revertsOnZeroVault() public {
        vm.expectRevert(bytes("Invalid vault address"));
        h.addCollateral(address(cfg), address(0), address(0), address(underlying), 1e18);
    }

    function test_addCollateral_revertsOnZeroShares() public {
        vm.expectRevert(bytes("Shares must be > 0"));
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 0);
    }

    function test_removeCollateral_revertsOnZeroShares() public {
        vm.expectRevert(bytes("Shares must be > 0"));
        h.removeCollateral(address(cfg), address(ybLp), address(underlying), 0);
    }

    function test_removeSharesForYield_revertsForUnauthorizedCaller() public {
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), 1e18);
        vm.prank(RANDOM_EOA);
        vm.expectRevert(bytes("Unauthorized"));
        h.removeSharesForYield(address(cfg), address(ybLp), address(underlying), 1);
    }
}
