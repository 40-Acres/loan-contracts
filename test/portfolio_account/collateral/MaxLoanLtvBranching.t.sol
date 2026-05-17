// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * MaxLoanLtvBranching — pins the new ltv-branching contract on getMaxLoan
 * for BOTH ERC4626CollateralManager and YieldBasisCollateralManager.
 *
 * Spec under test (identical in both libraries, post-change):
 *
 *   if (ltv == 0) {
 *       maxLoanIgnoreSupply = (((value * rewardsRate) / 1e6) * multiplier) / 1e12;
 *   } else {
 *       maxLoanIgnoreSupply = (value * ltv) / 10_000;
 *   }
 *
 * What we are guarding against:
 *
 *   1. The shadowing bug. A previous version of getMaxLoan declared a fresh
 *      `uint256 maxLoanIgnoreSupply` INSIDE the if-block, so the outer
 *      named-return stayed at 0 and the function silently reported zero
 *      max loan. This is hard to spot in review and would only surface as
 *      "every borrow attempt fails." A test that drives the ltv==0 path
 *      with non-trivial inputs and asserts a NON-ZERO result catches it.
 *
 *   2. Branch order / negation flip. If the conditional is ever inverted
 *      (`ltv != 0` swapped) the formulas pick the wrong inputs.
 *
 *   3. Formula drift. If somebody "tidies" the cash-flow expression and
 *      changes a divisor (1e6 → 1e18, multiplier scaling, etc.), pricing
 *      regresses. We pin the EXACT shape: the cash-flow result should
 *      collapse to value * rewardsRate * multiplier / 1e18 in canonical
 *      terms.
 *
 *   4. Boundary correctness. ltv=1 must yield a tiny non-zero loan;
 *      ltv=10000 must yield exactly the collateral value.
 *
 * Strategy:
 *   - Two harness contracts (one per library) expose the library at the
 *     same delegate-storage layout the real diamond uses. Each test
 *     instantiates a fresh harness so the ERC-7201 slot starts clean.
 *   - We DO NOT reuse the legacy YBCMHarness or the ERC4626 facet test —
 *     those tests embed the legacy multiplier-as-LTV assumption that this
 *     file is explicitly contradicting, and re-using them would obscure
 *     the regression we want to catch.
 *   - We mock the lending pool so vault-supply clamps don't pin maxLoan
 *     down (the supply clamp is covered separately in the existing files).
 *     This file's only job is to pin the maxLoanIgnoreSupply formula.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* -----------------------------------------------------------------------------
 * Lending-pool mock that satisfies the slice the managers call:
 *   activeAssets / lendingVault / asset / lendingAsset / getDebtBalance
 *
 * It is wired as both the loan contract AND the lending vault (returns itself
 * from lendingVault()), so an arbitrary `vaultBalance` can be staged via
 * IERC20(asset).balanceOf(lendingVault) — we mint USDC into the mock.
 *
 * setActiveAssets/setVaultBalance let each test express the supply ceiling
 * cleanly without juggling DynamicFeesVault state.
 * ---------------------------------------------------------------------------*/
contract MaxLoanMockPool {
    address public immutable _asset;
    address public immutable _self;
    address public immutable _portfolioFactory;
    uint256 public _activeAssets;
    uint256 public _debt;

    constructor(address asset_, address pf) {
        _asset = asset_;
        _self = address(this);
        _portfolioFactory = pf;
    }
    function setActiveAssets(uint256 v) external { _activeAssets = v; }
    function setDebt(uint256 v) external { _debt = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return _self; }
    function asset() external view returns (address) { return _asset; }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    function getDebtBalance(address) external view returns (uint256) { return _debt; }

    // totalAssets() shim -- managers call ILendingVault(lendingPool.lendingVault()).totalAssets()
    // from getMaxLoan. Mock plays both pool and vault, so report idle + active.
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssets;
    }
}

/* -----------------------------------------------------------------------------
 * Harnesses. Each library reads/writes its own ERC-7201 slot on `address(this)`,
 * so we expose the relevant functions through a thin contract per library.
 * ---------------------------------------------------------------------------*/
contract ERC4626Harness {
    function addCollateral(address cfg, address vault, uint256 shares) external {
        ERC4626CollateralManager.addCollateral(cfg, vault, shares);
    }
    function getMaxLoan(address cfg, address vault) external view returns (uint256, uint256) {
        return ERC4626CollateralManager.getMaxLoan(cfg, vault);
    }
}

contract YBHarness {
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }
    function getMaxLoan(address cfg, address vault, address underlying)
        external
        view
        returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.getMaxLoan(cfg, vault, underlying);
    }
}

/* ===========================================================================
 * Shared base — sets up factory/registry/config/mock pool common to both
 * library suites. Subclasses pick which manager to exercise.
 * =========================================================================*/
abstract contract MaxLoanBranchingBase is Test {
    PortfolioManager pm;
    PortfolioFactory factory;
    FacetRegistry registry;
    PortfolioFactoryConfig cfg;
    LoanConfig loanConfig;
    MaxLoanMockPool pool;
    MockERC20 lendingAsset;

    address constant OWNER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    function setUp() public virtual {
        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256(abi.encodePacked("ltv-branching-", address(this))));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        lendingAsset = new MockERC20("USDC", "USDC", 6);
        pool = new MaxLoanMockPool(address(lendingAsset), address(factory));

        // Mint enough USDC into the pool that supply-clamps don't dominate
        // — every test in this file is about the maxLoanIgnoreSupply formula,
        // not the supply clamp.
        lendingAsset.mint(address(pool), 1_000_000_000e6);

        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));
        vm.stopPrank();
    }
}

/* ===========================================================================
 * ERC4626 manager — getMaxLoan branching
 * =========================================================================*/
contract ERC4626MaxLoanLtvBranchingTest is MaxLoanBranchingBase {
    ERC4626Harness h;
    MockERC20 underlyingAsset;
    MockERC4626 vault;

    function setUp() public override {
        super.setUp();
        h = new ERC4626Harness();
        underlyingAsset = new MockERC20("UNDER", "UND", 18);
        vault = new MockERC4626(address(underlyingAsset), "Mock 4626", "M4626", 18);

        // Seed the harness with vault shares 1:1 with assets. With totalSupply==0
        // and totalAssets==0, deposit-shares conversion is the identity — so we
        // can mint exact share amounts and keep value math simple.
        // We bypass deposit() by minting both sides via the underlying token
        // (vault shares are minted normally, underlying gets dropped in to back them).
        underlyingAsset.mint(address(this), 1_000_000e18);
        underlyingAsset.approve(address(vault), 1_000_000e18);
        vault.deposit(1_000_000e18, address(h));
    }

    function _seedCollateral(uint256 shares) internal {
        // Shares already on the harness via setUp; just record them.
        h.addCollateral(address(cfg), address(vault), shares);
    }

    /* ---------- ltv == 0 path ---------- */

    /// @notice ltv==0 with non-trivial rewardsRate/multiplier MUST yield a
    ///         non-zero result. This is the regression test for the
    ///         shadowing bug — if `maxLoanIgnoreSupply` is shadowed inside
    ///         the if-block, the outer return stays 0.
    function test_erc4626_ltv0_cashFlowFormula_isNonZero() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(1_000_000); // 1e6 — clean scaling
        loanConfig.setMultiplier(1e12);       // 1e12 — clean scaling
        // ltv left at 0
        vm.stopPrank();

        _seedCollateral(100e18);

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        // Cash-flow shape: (((100e18 * 1e6)/1e6) * 1e12)/1e12 = 100e18.
        assertEq(maxLoanIgnoreSupply, 100e18, "cash-flow formula collapse to identity");
        assertGt(maxLoanIgnoreSupply, 0, "regression: shadowing bug would return 0 here");
    }

    /// @notice Concrete realistic numbers — pins the EXACT formula shape so
    ///         a future divisor swap would surface.
    function test_erc4626_ltv0_cashFlowFormula_concreteScaling() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(2_000_000);   // 2e6
        loanConfig.setMultiplier(5e11);         // 5e11
        vm.stopPrank();

        _seedCollateral(10e18); // value = 10e18

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        // (((10e18 * 2e6)/1e6) * 5e11) / 1e12
        //   = (10e18 * 2 * 5e11) / 1e12
        //   = 10e18 * 1 = 10e18
        assertEq(maxLoanIgnoreSupply, 10e18, "exact cash-flow scaling");
    }

    /* ---------- ltv != 0 path ---------- */

    function test_erc4626_ltv70pct_appliesLtvOnCollateralValue() public {
        vm.startPrank(OWNER);
        loanConfig.setLtv(7000); // 70%
        vm.stopPrank();

        _seedCollateral(1e18);

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        assertEq(maxLoanIgnoreSupply, 0.7e18, "70% of 1e18 = 0.7e18");
    }

    function test_erc4626_ltv1_yieldsTinyNonZeroLoan() public {
        vm.startPrank(OWNER);
        loanConfig.setLtv(1); // 0.01%
        vm.stopPrank();

        _seedCollateral(10_000e18);

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        // 10_000e18 * 1 / 10_000 = 1e18
        assertEq(maxLoanIgnoreSupply, 1e18, "ltv=1 / 10_000 = 0.01% of value");
        assertGt(maxLoanIgnoreSupply, 0, "ltv=1 must produce non-zero loan");
    }

    function test_erc4626_ltvMaxBps_yieldsFullCollateralValue() public {
        vm.startPrank(OWNER);
        loanConfig.setLtv(10_000); // 100%
        vm.stopPrank();

        _seedCollateral(3.14159e18);

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        assertEq(maxLoanIgnoreSupply, 3.14159e18, "ltv=10000 returns full collateral value");
    }

    /// @notice Once ltv is set, rewardsRate/multiplier MUST be ignored. If a
    ///         refactor accidentally added them back, this test fails.
    function test_erc4626_ltvSet_ignoresRewardsRateAndMultiplier() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(50_000_000); // big nonsense to detect leakage
        loanConfig.setMultiplier(7e15);
        loanConfig.setLtv(5000);
        vm.stopPrank();

        _seedCollateral(2e18);

        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(vault));
        // Pure 50% of 2e18 — no contribution from rewardsRate/multiplier.
        assertEq(maxLoanIgnoreSupply, 1e18, "ltv set: rewardsRate/multiplier ignored");
    }

    /// @notice Switching from ltv=0 (cash-flow) to ltv != 0 must change the
    ///         result via the documented formula. Pins the BRANCH semantic
    ///         end-to-end (not just one side of it).
    function test_erc4626_ltv_branchSwitch_changesFormula() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(1_000_000);
        loanConfig.setMultiplier(1e12);
        vm.stopPrank();

        _seedCollateral(10e18);

        (, uint256 cashFlow) = h.getMaxLoan(address(cfg), address(vault));
        assertEq(cashFlow, 10e18);

        vm.prank(OWNER);
        loanConfig.setLtv(5000); // flip to LTV branch

        (, uint256 ltvResult) = h.getMaxLoan(address(cfg), address(vault));
        assertEq(ltvResult, 5e18, "post-switch: 50% of 10e18 = 5e18");
    }
}

/* ===========================================================================
 * YieldBasis manager — getMaxLoan branching
 * =========================================================================*/
contract YieldBasisMaxLoanLtvBranchingTest is MaxLoanBranchingBase {
    YBHarness h;
    MockYieldBasisLP ybLp;
    MockERC20 underlyingAsset;

    function setUp() public override {
        // Override the base's USDC-6dec lending asset with an 18-dec lending asset so
        // the YB like-to-like LTV branch's rescale collapses to identity and all the
        // 18-dec expected values below stay valid post-refactor. Then point
        // `underlyingAsset` at the same token so getMaxLoan's
        // `lendingAsset != underlying` check is satisfied.
        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256(abi.encodePacked("ltv-branching-yb-", address(this))));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        lendingAsset = new MockERC20("UNDER18", "UND18", 18);
        pool = new MaxLoanMockPool(address(lendingAsset), address(factory));
        lendingAsset.mint(address(pool), 1_000_000_000e18);

        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));
        vm.stopPrank();

        h = new YBHarness();
        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        underlyingAsset = lendingAsset; // like-to-like: underlying == lendingAsset
        // pps=1 makes "shares == value" trivially.
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 1_000_000e18);
    }

    function _seedCollateral(uint256 shares) internal {
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlyingAsset), shares);
    }

    function test_yb_ltv0_cashFlowFormula_isNonZero() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(1_000_000);
        loanConfig.setMultiplier(1e12);
        vm.stopPrank();

        _seedCollateral(100e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 100e18, "cash-flow formula collapse to identity");
        assertGt(maxLoanIgnoreSupply, 0, "regression: shadowing bug would return 0");
    }

    function test_yb_ltv0_cashFlowFormula_concreteScaling() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(2_000_000);
        loanConfig.setMultiplier(5e11);
        vm.stopPrank();

        _seedCollateral(10e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 10e18);
    }

    function test_yb_ltv70pct_appliesLtvOnCollateralValue() public {
        vm.prank(OWNER);
        loanConfig.setLtv(7000);

        _seedCollateral(1e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 0.7e18);
    }

    function test_yb_ltv1_yieldsTinyNonZeroLoan() public {
        vm.prank(OWNER);
        loanConfig.setLtv(1);

        _seedCollateral(10_000e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 1e18);
        assertGt(maxLoanIgnoreSupply, 0);
    }

    function test_yb_ltvMaxBps_yieldsFullCollateralValue() public {
        vm.prank(OWNER);
        loanConfig.setLtv(10_000);

        _seedCollateral(3.14159e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 3.14159e18);
    }

    function test_yb_ltvSet_ignoresRewardsRateAndMultiplier() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(50_000_000);
        loanConfig.setMultiplier(7e15);
        loanConfig.setLtv(5000);
        vm.stopPrank();

        _seedCollateral(2e18);
        (, uint256 maxLoanIgnoreSupply) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(maxLoanIgnoreSupply, 1e18);
    }

    function test_yb_ltv_branchSwitch_changesFormula() public {
        vm.startPrank(OWNER);
        loanConfig.setRewardsRate(1_000_000);
        loanConfig.setMultiplier(1e12);
        vm.stopPrank();

        _seedCollateral(10e18);
        (, uint256 cashFlow) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(cashFlow, 10e18);

        vm.prank(OWNER);
        loanConfig.setLtv(5000);

        (, uint256 ltvResult) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(ltvResult, 5e18);
    }

    /// @notice Pricing pivot — collateral value is shares * pps / 1e18.
    ///         When ltv path is active and pps moves, the result must move
    ///         linearly. Locks the pricing-then-branch composition.
    function test_yb_ltv_respondsToPricePerShareChanges() public {
        vm.prank(OWNER);
        loanConfig.setLtv(7000);

        _seedCollateral(10e18);
        (, uint256 m1) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(m1, 7e18, "pps=1: 70% of 10e18");

        ybLp.setPricePerShare(2e18); // collateral value doubles

        (, uint256 m2) = h.getMaxLoan(address(cfg), address(ybLp), address(underlyingAsset));
        assertEq(m2, 14e18, "pps=2: 70% of 20e18");
    }
}
