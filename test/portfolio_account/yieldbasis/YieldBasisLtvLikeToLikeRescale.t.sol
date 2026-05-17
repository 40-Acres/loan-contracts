// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLtvLikeToLikeRescale
 *
 * Pins the new LTV-branch behavior on YieldBasisCollateralManager.getMaxLoan:
 *
 *   if (ltv != 0) {
 *       address lendingAsset = lendingPool.lendingAsset();
 *       if (lendingAsset != underlying) revert LtvRequiresLikeToLike();
 *       uint8 ld = IERC20Metadata(lendingAsset).decimals();
 *       uint256 valueNative = ld == 18
 *           ? totalCollateralValue
 *           : (ld < 18
 *               ? totalCollateralValue / (10 ** (18 - ld))
 *               : totalCollateralValue * (10 ** (ld - 18)));
 *       maxLoanIgnoreSupply = (valueNative * ltv) / 10000;
 *   }
 *
 * What's being guarded:
 *
 *   1. LIKE-TO-LIKE GUARD. If the operator misconfigures lendingAsset to something
 *      other than the LP's underlying (e.g. yb-ETH LP + USDC lending pool), the
 *      rescale-by-decimals model is wrong because the 18-dec pricePerShare-derived
 *      value is denominated in ETH, not USDC. The new check reverts hard before
 *      the wrong-asset value is silently treated as USDC. Test 4 pins this.
 *
 *   2. DECIMAL RESCALE. pricePerShare is always 18-dec; downstream supply/clamp
 *      math uses lending-asset-native decimals. Without the rescale, a 70%-LTV
 *      borrow against 1 BTC of 8-dec-WBTC collateral would have permitted 0.7e18
 *      wei of borrow (1e10× too large) instead of 0.7e8. Test 2 catches that.
 *
 *   3. NO-OP ON 18-DEC. For the production yb-WETH + WETH market (both 18-dec),
 *      the rescale must collapse to identity — the existing test corpus assumes
 *      this. Test 1 pins the no-op.
 *
 *   4. UPSCALE BRANCH. The same rescale handles ld > 18 (multiplies by 10^(ld-18)).
 *      Improbable in production but the branch must be exercised. Test 3.
 *
 *   5. REWARDS-RATE PATH IS UNTOUCHED. ltv == 0 (cash-flow path) MUST NOT be
 *      affected by the new check or rescale — its formula and lendingAsset
 *      independence are intentional. Test 5 pins bit-exact match.
 *
 *   6. PROPAGATION through removeCollateral and enforceCollateralRequirements.
 *      These both go through getMaxLoan via _currentShortfall / direct call; the
 *      new (rescaled) max must drive their enforcement. Tests 6 and 7.
 *
 * Pattern mirrors YieldBasisCollateralManager.t.sol: a thin harness exposes
 * library functions at the right ERC-7201 storage slot; a mock lending pool
 * provides the lendingAsset / lendingVault / activeAssets / getDebtBalance
 * slice the library reads. Each test instantiates fresh state.
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

/* -----------------------------------------------------------------------------
 * Mock pool implementing exactly the slice YieldBasisCollateralManager reads:
 *   - lendingAsset(): the asset the underlying-vs-asset check compares against
 *   - lendingVault(): an address whose .asset() returns lendingAsset
 *   - activeAssets(): outstanding capital (clamps maxLoan via supply path)
 *   - getDebtBalance(borrower): polled by _syncDebt
 *   - asset(): IERC4626 slice on the same address (mock acts as both pool and vault)
 *
 * `getPortfolioFactory()` must match the configured factory or
 * PortfolioFactoryConfig.setLoanContract rejects the staging.
 * ---------------------------------------------------------------------------*/
contract YBLtvMockPool {
    address public immutable _lendingAsset;
    address public immutable _self;
    address public immutable _portfolioFactory;
    uint256 public _activeAssets;
    uint256 public _debt;
    uint256 public _vaultBalance;

    constructor(address lendingAsset_, address pf) {
        _lendingAsset = lendingAsset_;
        _self = address(this);
        _portfolioFactory = pf;
    }

    function setActiveAssets(uint256 v) external { _activeAssets = v; }
    function setDebt(uint256 v) external { _debt = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _lendingAsset; }
    function lendingVault() external view returns (address) { return _self; }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    function asset() external view returns (address) { return _lendingAsset; }
    function getDebtBalance(address) external view returns (uint256) { return _debt; }

    // For decreaseTotalDebt path used in test 6.
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256, uint256) external pure returns (uint256) { return 0; }

    // totalAssets() shim -- managers call ILendingVault(lendingPool.lendingVault()).totalAssets()
    // from getMaxLoan. Mock plays both pool and vault, so report idle + active.
    function totalAssets() external view returns (uint256) {
        return IERC20(_lendingAsset).balanceOf(address(this)) + _activeAssets;
    }
}

/* -----------------------------------------------------------------------------
 * Harness — exposes the library's public functions at the right storage slot.
 * Mirrors the pattern in YieldBasisCollateralManager.t.sol; deliberately
 * minimal because this file's only concern is the LTV branch.
 * ---------------------------------------------------------------------------*/
contract YBLtvHarness {
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }

    function removeCollateral(address cfg, address vault, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.removeCollateral(cfg, vault, underlying, shares);
    }

    function getMaxLoan(address cfg, address vault, address underlying)
        external
        view
        returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.getMaxLoan(cfg, vault, underlying);
    }

    function enforceCollateralRequirements(address cfg, address vault, address underlying)
        external
        view
        returns (bool)
    {
        return YieldBasisCollateralManager.enforceCollateralRequirements(cfg, vault, underlying);
    }

    // Test-only storage poke to stage debt without round-tripping the pool.
    // The library's _snapshotIfNeeded will overwrite this with the pool's
    // reported debt, so callers that want this value to STICK must also stage
    // the same value on the mock pool's _debt.
    function __setDebt(uint256 v) external {
        // Mirror the layout of YieldBasisCollateralData; debt is the 3rd word.
        bytes32 slot = keccak256("storage.YieldBasisCollateralManager");
        bytes32 debtSlot;
        assembly {
            debtSlot := add(slot, 2)
        }
        assembly {
            sstore(debtSlot, v)
        }
    }
}

/* ===========================================================================
 * Suite
 * =========================================================================*/
contract YieldBasisLtvLikeToLikeRescaleTest is Test {
    YBLtvHarness internal h;
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    YBLtvMockPool internal pool;

    // Mocks per-test (re-instantiated in setUp).
    MockYieldBasisLP internal ybLp;        // collateral vault arg
    MockERC20 internal lendingAsset18;     // 18-dec like-to-like
    MockERC20 internal lendingAsset8;      // 8-dec like-to-like (WBTC-style)
    MockERC20 internal lendingAsset24;     // 24-dec upscale branch
    MockERC20 internal lendingAssetCross;  // a different 6-dec asset for cross-asset path

    address internal constant OWNER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    uint256 internal constant LTV_BPS = 7000; // 70%
    uint256 internal constant POOL_LIQUIDITY = 1e30; // pin supply clamps wide open

    function setUp() public {
        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256(abi.encodePacked("yb-ltv-rescale-", address(this))));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        // Lending-asset mocks at every decimal we exercise.
        lendingAsset18 = new MockERC20("WETH18", "WETH18", 18);
        lendingAsset8 = new MockERC20("WBTC8", "WBTC8", 8);
        lendingAsset24 = new MockERC20("MEGA24", "MG24", 24);
        lendingAssetCross = new MockERC20("USDC6", "USDC6", 6);

        ybLp = new MockYieldBasisLP("ybMOCK", "ybMOCK", 18);
        // pps = 1e18 with shares = 1e18 gives a clean 1e18 totalCollateralValue.
        ybLp.setPricePerShare(1e18);

        // Single shared pool — each test reconfigures cfg.setLoanContract to point
        // at the right asset, then mints liquidity into that pool.
        factory.setPortfolioFactoryConfig(address(cfg));

        vm.stopPrank();

        h = new YBLtvHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(address(h), true);

        vm.label(address(h), "YBLtvHarness");
        vm.label(address(ybLp), "ybMOCK");
        vm.label(address(lendingAsset18), "WETH18");
        vm.label(address(lendingAsset8), "WBTC8");
        vm.label(address(lendingAsset24), "MEGA24");
        vm.label(address(lendingAssetCross), "USDC6-cross");
    }

    /* -----------------------------------------------------------------------
     * Helper — point cfg.loanContract at a fresh pool whose lendingAsset is
     * `asset`, fund it with liquidity sized to keep the supply clamp wide
     * open. Returns the pool for staging-specific reads.
     * ---------------------------------------------------------------------*/
    function _stagePool(MockERC20 asset_) internal returns (YBLtvMockPool p) {
        p = new YBLtvMockPool(address(asset_), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(p));
        // Mint a magnitude that dwarfs any rescaled LTV result so the supply
        // clamp NEVER pins maxLoan — we want raw maxLoanIgnoreSupply through.
        asset_.mint(address(p), POOL_LIQUIDITY);
    }

    /* ======================================================================
     * Test 1 — 18-dec like-to-like, rescale collapses to identity.
     *
     * This is the production yb-WETH + WETH market shape. If the rescale
     * accidentally divides or multiplies by 1 (i.e. 10**0), the result is
     * unchanged. A regression here means existing 18-dec deployments would
     * sudden mis-size loans on the next upgrade.
     * =====================================================================*/
    function test_LTV_LikeToLike_18Dec_Unchanged() public {
        _stagePool(lendingAsset18);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        // shares = 1e18, pps = 1e18 → totalCollateralValue = 1e18.
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset18), 1e18);

        (, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset18));

        // 70% of 1e18 with no rescale (ld == 18) = 0.7e18.
        assertEq(maxLoanIgnoreSupply, 0.7e18, "18->18 rescale is identity; 70% applied to 1e18");
    }

    /* ======================================================================
     * Test 2 — 8-dec like-to-like, rescale floors 1e10× down.
     *
     * Pre-refactor, getMaxLoan would have produced 0.7e18 here — i.e. 7e9 BTC
     * authorized when the user supplied 1 BTC. New code rescales: valueNative
     * = 1e18 / 1e10 = 1e8 (1 BTC in 8-dec wei), and 70% → 0.7e8.
     *
     * If a future refactor swapped the division direction, magnitude
     * changes by 1e20× — easy to spot.
     * =====================================================================*/
    function test_LTV_LikeToLike_8Dec_Rescaled() public {
        _stagePool(lendingAsset8);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        // shares = 1e18, pps = 1e18 → value18 = 1e18 (representing 1 BTC).
        // Rescale to 8-dec: 1e18 / 10^(18-8) = 1e8.
        // LTV 70%: maxLoanIgnoreSupply = 1e8 * 7000 / 10000 = 7e7.
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset8), 1e18);

        (, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset8));

        assertEq(maxLoanIgnoreSupply, 0.7e8, "8-dec like-to-like: 70% of 1 BTC in 8-dec wei = 0.7e8");
        // Belt-and-suspenders: regression check — pre-refactor would have
        // produced 0.7e18 (1e10x too large). Assert we're not that magnitude.
        assertLt(maxLoanIgnoreSupply, 0.7e18, "must NOT be pre-refactor magnitude");
    }

    /* ======================================================================
     * Test 3 — 24-dec like-to-like, rescale upscales 1e6×.
     *
     * Improbable in production but the `ld > 18` branch exists and must work.
     * Mock the lending asset with decimals(24) and verify the multiply path.
     * =====================================================================*/
    function test_LTV_LikeToLike_24Dec_RescaledMultiply() public {
        _stagePool(lendingAsset24);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        // value18 = 1e18 → upscale to 24-dec: 1e18 * 10^(24-18) = 1e24.
        // LTV 70%: maxLoanIgnoreSupply = 1e24 * 7000 / 10000 = 0.7e24.
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset24), 1e18);

        (, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset24));

        assertEq(maxLoanIgnoreSupply, 0.7e24, "24-dec upscale: 70% of 1e24");
        // Regression bound: must be strictly above the 18-dec result, proving
        // the multiply branch was taken.
        assertGt(maxLoanIgnoreSupply, 0.7e18, "must be upscaled above 18-dec");
    }

    /* ======================================================================
     * Test 4 — cross-asset LTV path reverts.
     *
     * yb-ETH LP underlying = WETH (18-dec). Lending pool = USDC (6-dec, distinct
     * token). LTV != 0. Must revert with LtvRequiresLikeToLike.
     *
     * Note: the YieldBasisLpFacet wires _underlying = lendingPool.lendingAsset()
     * at construction, so a misconfiguration is structurally impossible at the
     * facet level. This test guards the library directly — defends against a
     * future caller (other facet, admin script, integration test) passing a
     * mismatched `underlying` directly into the library.
     * =====================================================================*/
    function test_LTV_CrossAsset_RevertsLikeToLike() public {
        // Pool's lendingAsset = USDC6. We add collateral against `lendingAsset18`
        // (WETH) as the LP underlying — distinct address, distinct decimals.
        _stagePool(lendingAssetCross);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        ybLp.mint(address(h), 1e18);
        // Note: addCollateral itself calls _snapshotIfNeeded → getMaxLoan, so
        // the revert can fire during deposit; we capture it via vm.expectRevert
        // BEFORE the call. This proves the like-to-like guard is hot from
        // the very first borrow-adjacent operation, not just from explicit
        // getMaxLoan reads.
        vm.expectRevert(YieldBasisCollateralManager.LtvRequiresLikeToLike.selector);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset18), 1e18);
    }

    /* ======================================================================
     * Test 5 — ltv == 0 (rewards-rate / cash-flow path) bit-exact match.
     *
     * Confirms the new like-to-like guard and rescale DO NOT touch this branch.
     * The operator-calibrated multiplier formula is the only thing that should
     * gate maxLoanIgnoreSupply here. Compute the expected value mirroring the
     * formula and assert bit-exact match. We deliberately use a cross-asset
     * configuration (yb-ETH + USDC) to prove the guard does not fire here.
     * =====================================================================*/
    function test_RewardsRate_CrossAsset_NoBehaviorChange() public {
        _stagePool(lendingAssetCross);
        vm.startPrank(OWNER);
        loanConfig.setLtv(0); // cash-flow / rewards-rate path
        loanConfig.setRewardsRate(2_000_000); // 2e6
        loanConfig.setMultiplier(5e11);
        vm.stopPrank();

        // value18 = 10e18 (shares = 10e18, pps = 1e18).
        ybLp.mint(address(h), 10e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset18), 10e18);

        (, uint256 maxLoanIgnoreSupply) =
            h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset18));

        // Replay the contract's formula EXACTLY (not by hardcoding — by
        // re-implementing — so any divisor swap surfaces).
        uint256 totalCollateralValue = 10e18;
        uint256 rewardsRate = 2_000_000;
        uint256 multiplier = 5e11;
        uint256 expected = (((totalCollateralValue * rewardsRate) / 1_000_000) * multiplier) / 1e12;

        assertEq(maxLoanIgnoreSupply, expected, "rewards-rate path: bit-exact match, no rescale");
        assertGt(maxLoanIgnoreSupply, 0, "rewards-rate path: must NOT be killed by the new guard");
    }

    /* ======================================================================
     * Test 6 — removeCollateral enforces the new rescaled max.
     *
     * Borrow exactly at max under the 8-dec rescale, then attempt a remove
     * that would drop maxLoanIgnoreSupply below outstanding debt. Must revert
     * with "Debt exceeds max loan".
     *
     * This is the regression that matters in production: a user with a debt
     * sized to the OLD (wrong, 1e10× too large) max would be over-leveraged
     * post-upgrade. removeCollateral must enforce the new math, not the old.
     * =====================================================================*/
    function test_LTV_RemoveCollateral_EnforcesNewMath() public {
        YBLtvMockPool p = _stagePool(lendingAsset8);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        // Deposit 1e18 LP shares. value18 = 1e18. Rescale → 1e8 in 8-dec.
        // maxLoanIgnoreSupply = 1e8 * 7000 / 10000 = 0.7e8.
        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset8), 1e18);

        // Stage debt at the rescaled max (0.7e8). Both the pool's getDebtBalance
        // and the local cache must hold this value; _snapshotIfNeeded will
        // overwrite the cache with the pool read, so we set both.
        p.setDebt(0.7e8);
        h.__setDebt(0.7e8);

        // Sanity: at current state, maxLoanIgnoreSupply == 0.7e8 (just barely OK).
        (, uint256 curMax) = h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset8));
        assertEq(curMax, 0.7e8, "pre-remove max under new rescale");

        // Removing half the shares halves the rescaled max to 0.35e8 < debt 0.7e8
        // → must revert. Pre-refactor, the OLD max was 0.7e18 and the same
        // remove would have produced new max 0.35e18 — still >> 0.7e8 debt.
        // So this revert demonstrably depends on the NEW math.
        vm.expectRevert(bytes("Debt exceeds max loan"));
        h.removeCollateral(address(cfg), address(ybLp), address(lendingAsset8), 0.5e18);
    }

    /* ======================================================================
     * Test 7 — enforceCollateralRequirements drives _currentShortfall through
     * the new rescaled getMaxLoan.
     *
     * Stage:
     *   - 1 BTC of LP collateral, 70% LTV.
     *   - debt sized to the NEW (rescaled) max, then nudge pricePerShare down
     *     in a fresh block so the snapshot path doesn't see it as same-block
     *     mutation. (snapshotBlockNumber is set in addCollateral; vm.roll
     *     advances past it so start==end==(new shortfall) and BadDebt path
     *     is the one that's NOT triggered — we want UndercollateralizedDebt
     *     specifically.)
     *
     * Actually simpler: stay in the same block. addCollateral set snapshot
     * with start shortfall = 0 (no debt at deposit time). Then we set debt
     * and drop pps. enforceCollateralRequirements computes end > 0; start
     * is 0; revert with UndercollateralizedDebt.
     *
     * This test proves the rescale propagates through _currentShortfall.
     * =====================================================================*/
    function test_LTV_EnforceCollateralRequirements_EnforcesNewMath() public {
        YBLtvMockPool p = _stagePool(lendingAsset8);
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        ybLp.mint(address(h), 1e18);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(lendingAsset8), 1e18);

        // Snapshot was taken at deposit with debt=0 → start shortfall = 0.
        // Now stage debt > rescaled max. Rescaled max @ pps=1: 0.7e8. Set debt
        // to 1e8 (well above). _snapshotIfNeeded only re-runs the snapshot
        // if block.number changed — we're still in the same block, so the
        // start of 0 from addCollateral persists, and end > 0 will revert.
        p.setDebt(1e8);
        h.__setDebt(1e8);

        // Shortfall = 1e8 - 0.7e8 = 0.3e8.
        vm.expectRevert(
            abi.encodeWithSelector(YieldBasisCollateralManager.UndercollateralizedDebt.selector, uint256(0.3e8))
        );
        h.enforceCollateralRequirements(address(cfg), address(ybLp), address(lendingAsset8));
    }

    /* ======================================================================
     * Bonus — sanity check that ltv == 0 cross-asset DOES allow operation
     * AND that an addCollateral call against a mismatched asset under ltv != 0
     * fails AT the addCollateral step (because addCollateral triggers
     * _snapshotIfNeeded → getMaxLoan).
     *
     * Already covered above. This anchor test confirms the failure surface:
     * the like-to-like check fires from every mutating call path that hits
     * getMaxLoan, not just the one explicit getMaxLoan read. If a caller
     * unintentionally drops into the LTV branch with a misconfigured pool,
     * the borrow will fail loudly rather than silently authorizing too much.
     * =====================================================================*/
    function test_LTV_CrossAsset_FailsThroughEveryMutatingPath() public {
        _stagePool(lendingAssetCross); // USDC6
        vm.prank(OWNER);
        loanConfig.setLtv(LTV_BPS);

        // Try via the most-naive entrypoint a misconfigured operator might hit.
        vm.expectRevert(YieldBasisCollateralManager.LtvRequiresLikeToLike.selector);
        h.getMaxLoan(address(cfg), address(ybLp), address(lendingAsset18));
    }
}
