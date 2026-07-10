// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicYieldBasisCollateralManager -- addCollateral drift regression suite
 * ===========================================================================
 *
 * Mirrors YieldBasisDriftRegression.t.sol for the dynamic-debt variant. Only
 * structural difference: no `_syncDebt` is called in `_snapshotIfNeeded`
 * (debt is read live every call). The drift bug shape is identical.
 *
 * In addition to the mirrored cases, this file adds:
 *   test_DynamicAddCollateral_DriftLessThanDeposit_EffectiveVsRawDebtInvariants_RegressionDrift_
 *   -- verifies that AFTER the ratchet, headroom math uses effective debt
 *      and solvency math uses raw debt, exactly as the legacy split spec.
 * =========================================================================*/

import {Test, console2} from "forge-std/Test.sol";

// Library under test
import {DynamicYieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisCollateralManager.sol";

// Infra
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
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ---------------------------------------------------------------------------
 * Dynamic harness. Same shape as the legacy harness but with the dynamic
 * library's `getTotalDebt(cfg)` signature, no `data.debt` field, and the
 * effective-debt reader.
 * -------------------------------------------------------------------------*/
contract DYBDriftHarness {
    struct DYBData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
        address gauge;
    }

    bytes32 internal constant DYB_SLOT = keccak256("storage.DynamicYieldBasisCollateralManager");

    function _dyb() internal pure returns (DYBData storage d) {
        bytes32 s = DYB_SLOT;
        assembly { d.slot := s }
    }

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

    function snapshotShortfall(address cfg, address vault, address underlying) external {
        DynamicYieldBasisCollateralManager.snapshotShortfall(cfg, vault, underlying);
    }

    function reconcileSharesToBalance(address cfg, address vault, address underlying, address gauge) external {
        DynamicYieldBasisCollateralManager.reconcileSharesToBalance(cfg, vault, underlying, gauge);
    }

    function __stakeInto(address gauge, address lp, uint256 amount) external {
        IERC20(lp).approve(gauge, amount);
        MockTunableYieldBasisGauge(gauge).deposit(amount, address(this));
    }

    function __readDYB() external view returns (DYBData memory d) {
        DYBData storage s = _dyb();
        d.shares = s.shares;
        d.depositedAssetValue = s.depositedAssetValue;
        d.overSuppliedVaultDebt = s.overSuppliedVaultDebt;
        d.startShortfall = s.startShortfall;
        d.snapshotBlockNumber = s.snapshotBlockNumber;
        d.gauge = s.gauge;
    }
}

/* ---------------------------------------------------------------------------
 * Mock dynamic lending pool. Stages raw + effective debt independently and
 * supports a post-pay raw override (mirrors the existing
 * MockDynamicLendingPool from DynamicYieldBasisCollateralManager.t.sol).
 * -------------------------------------------------------------------------*/
contract MockDynPool {
    address public immutable _asset;
    address internal _portfolioFactory;

    uint256 public _actualPaidToReport;
    uint256 public _rawDebt;
    uint256 public _effectiveDebt;
    bool public _useEffectiveOverride;
    uint256 public _activeAssetsToReport;

    constructor(address asset_, address portfolioFactory_) {
        _asset = asset_;
        _portfolioFactory = portfolioFactory_;
    }

    function setRaw(uint256 v) external { _rawDebt = v; }
    function setEffective(uint256 v) external {
        _effectiveDebt = v;
        _useEffectiveOverride = true;
    }
    function setActualPaid(uint256 v) external { _actualPaidToReport = v; }
    function setActiveAssets(uint256 v) external { _activeAssetsToReport = v; }

    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function lendingAsset() external view returns (address) { return _asset; }
    function lendingVault() external view returns (address) { return address(this); }
    function activeAssets() external view returns (uint256) { return _activeAssetsToReport; }
    function asset() external view returns (address) { return _asset; }
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this)) + _activeAssetsToReport;
    }

    function borrowFromPortfolio(uint256 /*amount*/) external pure returns (uint256) { return 0; }

    function payFromPortfolio(uint256 totalPayment, uint256 /*feesToPay*/) external returns (uint256 actualPaid) {
        actualPaid = _actualPaidToReport;
        if (actualPaid > totalPayment) actualPaid = totalPayment;
        if (actualPaid > 0) {
            IERC20(_asset).transferFrom(msg.sender, address(this), actualPaid);
        }
    }

    function getDebtBalance(address) external view returns (uint256) { return _rawDebt; }
    function getEffectiveDebtBalance(address) external view returns (uint256) {
        return _useEffectiveOverride ? _effectiveDebt : _rawDebt;
    }

    function depositRewards(uint256) external {}
}

/* ===========================================================================
 * TEST SUITE
 * ==========================================================================*/
contract DynamicYieldBasisDriftRegressionTest is Test {
    DYBDriftHarness internal h;

    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    FacetRegistry internal registry;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    DynamicFeesVault internal lendingVault;

    MockYieldBasisLP internal ybLp;
    MockTunableYieldBasisGauge internal gauge;
    MockERC20 internal underlying;

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH_CALLER = address(0xAAAA);

    uint256 internal constant VAULT_LIQUIDITY = 1_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, FacetRegistry r) = pm.deployFactory(keccak256("dyb-drift-regression"));
        factory = f;
        registry = r;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        ybLp = new MockYieldBasisLP("ybETH", "ybETH", 18);
        ybLp.setPricePerShare(1e18);
        underlying = new MockERC20("WETH", "WETH", 18);
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        DynamicFeesVault impl = new DynamicFeesVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                DynamicFeesVault.initialize,
                (address(underlying), "Lending Vault", "lVAULT", address(factory), OWNER, 0)
            )
        );
        lendingVault = DynamicFeesVault(address(proxy));
        lendingVault.setFeeCalculator(address(new FeeCalculator()));
        underlying.mint(address(lendingVault), VAULT_LIQUIDITY);

        loanConfig.setMultiplier(LTV_BPS);
        loanConfig.setLtv(LTV_BPS);
        cfg.setLoanContract(address(lendingVault));
        factory.setPortfolioFactoryConfig(address(cfg));

        pm.setAuthorizedCaller(AUTH_CALLER, true);

        vm.stopPrank();

        h = new DYBDriftHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(address(h), true);

        vm.label(address(h), "DYBDriftHarness");
        vm.label(address(ybLp), "ybLP");
        vm.label(address(gauge), "MockTunableGauge");
        vm.label(address(underlying), "WETH");
        vm.label(address(lendingVault), "LendingVault");
    }

    function _seedTrackedSharesWithDrift(uint256 trackedT, uint256 driftDelta) internal {
        require(driftDelta < trackedT, "driftDelta must be < trackedT");
        ybLp.mint(address(h), trackedT);
        h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), trackedT);
        h.__stakeInto(address(gauge), address(ybLp), trackedT);
        uint256 ratio = ((trackedT - driftDelta) * 10_000) / trackedT;
        gauge.setConvertRatioBps(ratio);
    }

    // ============ TEST 1 (CANARY) ==========================================

    function test_DynamicAddCollateral_DriftLessThanDeposit_Succeeds_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 1e15;
        uint256 incoming = 1e18;

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        (uint256 sharesPre, uint256 depPre,) = h.getCollateral(address(ybLp), address(underlying));
        assertEq(sharesPre, T, "pre: data.shares == T");
        uint256 basisPerSharePre = (depPre * 1e18) / sharesPre;

        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            (uint256 sharesPost, uint256 depPost,) = h.getCollateral(address(ybLp), address(underlying));
            assertApproxEqAbs(sharesPost, (T - delta) + incoming, 2, "post-fix: data.shares == (T-delta) + incoming");
            uint256 basisPerSharePost = (depPost * 1e18) / sharesPost;
            assertApproxEqAbs(basisPerSharePost, basisPerSharePre, 2, "post-fix: per-share basis preserved");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == DynamicYieldBasisCollateralManager.InsufficientShareBalance.selector) {
                (uint256 req, uint256 actual) = abi.decode(_slice(err, 4), (uint256, uint256));
                emit log_named_uint("BUG REPRO (dynamic): required", req);
                emit log_named_uint("BUG REPRO (dynamic): actual", actual);
                emit log_named_uint("BUG REPRO (dynamic): drift  ", req - actual);
                assertTrue(false, "CANARY FAIL (expected on broken main)");
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 6 (CANARY) ==========================================

    function test_DynamicAddCollateral_GaugeUnset_DirectLpDrift_RatchetsCorrectly_RegressionDrift_() public {
        uint256 T = 10e18;
        uint256 delta = 1e18;
        ybLp.mint(address(h), T);
        h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), T);

        DYBDriftHarness.DYBData memory s = h.__readDYB();
        assertEq(s.gauge, address(0), "gauge unset");

        ybLp.burn(address(h), delta);
        vm.roll(block.number + 1);

        uint256 incoming = 2e18;
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(0), address(underlying), incoming) {
            (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
            assertApproxEqAbs(sharesPost, (T - delta) + incoming, 2,
                "post-fix (stricter): gauge-less ratchet fires");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == DynamicYieldBasisCollateralManager.InsufficientShareBalance.selector) {
                assertTrue(false, "CANARY FAIL (expected on broken main, dynamic): gauge-less drift");
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 7 (CANARY) ==========================================

    function test_DynamicAddCollateral_InBlockBorrowThenDrift_StaleBaselineCannotMaskShortfall_RegressionDrift_() public {
        MockDynPool pool = new MockDynPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        uint256 delta = 1e18;
        _seedTrackedSharesWithDrift(T, delta);

        // No pre-snapshot: a pre-call snapshotShortfall would itself trigger
        // the no-incoming-shares reconcile and ratchet data.shares before the
        // bug condition can be set up.
        vm.roll(block.number + 1);
        pool.setRaw(6e18);
        pool.setEffective(6e18);

        uint256 incoming = 2e18;
        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            (uint256 maxLoanA, uint256 capA) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
            assertApproxEqAbs(capA, 7.7e18, 1e6, "cap reflects ratcheted shares (dynamic)");
            assertGt(maxLoanA, 0, "headroom available");
            assertLt(capA, (T + incoming) * LTV_BPS / 10_000, "cap < pre-drift inflated cap");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == DynamicYieldBasisCollateralManager.InsufficientShareBalance.selector) {
                assertTrue(false, "CANARY FAIL (expected on broken main, dynamic): in-block deposit reverts");
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 8 (CANARY) ==========================================

    function test_DynamicDecreaseTotalDebt_DuringDriftWipe_RepaySucceeds_RegressionDrift_() public {
        MockDynPool pool = new MockDynPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        _seedTrackedSharesWithDrift(T, 1e18);
        gauge.setConvertRatioBps(1);

        vm.roll(block.number + 1);

        uint256 debtAmt = 1e18;
        pool.setRaw(debtAmt);
        pool.setEffective(debtAmt);
        pool.setActualPaid(debtAmt);
        underlying.mint(address(h), debtAmt);

        uint256 excess = h.decreaseTotalDebt(address(cfg), address(ybLp), address(underlying), debtAmt);
        assertEq(excess, 0, "no excess on exact repay");
        (uint256 sharesPost,,) = h.getCollateral(address(ybLp), address(underlying));
        assertApproxEqAbs(sharesPost, T / 10_000, 2, "ratchet ran during repay (dynamic)");
    }

    // ============ TEST 11 (CANARY) =========================================

    function test_DynamicIncreaseTotalDebt_AfterDriftDeposit_MaxLoanFromRatchetedShares_RegressionDrift_() public {
        MockDynPool pool = new MockDynPool(address(underlying), address(factory));
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
            (uint256 maxLoanA, uint256 capA) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
            assertApproxEqAbs(capA, 7.7e18, 1e6, "cap reflects ratcheted shares");
            assertLt(capA, (T + incoming) * LTV_BPS / 10_000, "cap < pre-drift inflated cap");
            assertGt(maxLoanA, 0, "headroom available");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == DynamicYieldBasisCollateralManager.InsufficientShareBalance.selector) {
                assertTrue(false, "CANARY FAIL (expected on broken main, dynamic): cap-from-ratcheted-shares unreachable");
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ TEST 12 (DYNAMIC-ONLY) ===================================
    //
    // After the ratchet+add, headroom must come from EFFECTIVE debt and the
    // solvency cap (via _currentShortfall) must come from RAW debt.

    function test_DynamicAddCollateral_DriftLessThanDeposit_EffectiveVsRawDebtInvariants_RegressionDrift_() public {
        MockDynPool pool = new MockDynPool(address(underlying), address(factory));
        vm.prank(OWNER);
        cfg.setLoanContract(address(pool));
        underlying.mint(address(pool), 100e18);

        uint256 T = 10e18;
        uint256 delta = 5e17;
        uint256 incoming = 2e18;

        _seedTrackedSharesWithDrift(T, delta);
        vm.roll(block.number + 1);

        // Stage non-trivial raw and effective debt.
        // raw = 4e18, effective = 3e18.
        pool.setRaw(4e18);
        pool.setEffective(3e18);

        ybLp.mint(address(h), incoming);

        try h.addCollateral(address(cfg), address(ybLp), address(gauge), address(underlying), incoming) {
            // Post-fix: shares = (T-delta) + incoming = 9.5e18 + 2e18 = 11.5e18.
            // collateralValue = 11.5e18, cap = 11.5e18 * 0.7 = 8.05e18.
            (uint256 maxLoan, uint256 cap) = h.getMaxLoan(address(cfg), address(ybLp), address(underlying));
            assertApproxEqAbs(cap, 8.05e18, 1e6, "cap from ratcheted+added shares");

            // Headroom uses EFFECTIVE (3e18): cap - effective = 5.05e18.
            // (Supply path is unbounded -- pool has 100e18 liquid.)
            assertApproxEqAbs(maxLoan, 5.05e18, 1e6, "headroom uses effective debt, NOT raw");
            // If headroom were (mistakenly) computed off raw it would be 4.05e18.
            assertTrue(maxLoan > (cap - 4e18) - 1e3, "headroom strictly > cap - raw (confirms effective in use)");

            // Solvency: enforceCollateralRequirements uses raw via _currentShortfall.
            // cap = 8.05 > raw = 4 -> no shortfall -> no revert.
            assertTrue(
                DynamicYieldBasisCollateralManager.enforceCollateralRequirements(
                    address(cfg), address(ybLp), address(underlying)
                ),
                "enforceCollateralRequirements OK -- raw < cap"
            );
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == DynamicYieldBasisCollateralManager.InsufficientShareBalance.selector) {
                assertTrue(false, "CANARY FAIL (expected on broken main, dynamic): cap-from-ratcheted-shares unreachable");
            } else {
                emit log_named_bytes("UNEXPECTED revert", err);
                assertTrue(false, "wrong revert shape");
            }
        }
    }

    // ============ util ====================================================

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        require(data.length >= start, "slice bounds");
        uint256 len = data.length - start;
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
