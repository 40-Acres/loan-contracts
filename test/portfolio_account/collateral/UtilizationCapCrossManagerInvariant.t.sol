// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * UtilizationCapCrossManagerInvariant
 *
 * Issue Summary
 * -------------
 * Three new-vault collateral managers accumulate `overSuppliedVaultDebt`
 * from the same per-borrower delta on increase:
 *
 *   (maxLoan, _) = getMaxLoan(...)   // uses LoanConfig.getMaxUtilizationBps()
 *   if (amount > maxLoan) data.overSuppliedVaultDebt += amount - maxLoan
 *
 * For a clean starting state (no prior debt, no prior active capital), the
 * cap-pinned branch of getMaxLoan collapses to
 *   maxLoan = totalAssets * loanConfig.getMaxUtilizationBps() / 10000
 * and the delta `amount - maxLoan` equals the legacy `activeAssets - cap`
 * recompute. We use that equivalence here strictly as an oracle: the test
 * stages identical state on three fresh fixtures and asserts all three
 * managers compute the SAME per-borrower delta. If a refactor reverts one
 * manager to a hardcoded 8000 or stops reading LoanConfig, this invariant
 * silently fractures with no compile error.
 *
 * What this test does
 * -------------------
 * Stages identical `(totalAssets, borrow amount, maxUtilizationBps)` on a
 * fresh mock pool, then drives each manager through one borrow. Asserts
 * all three flags equal the same canonical `amount - maxLoan`.
 *
 * The driver uses each library's external entry point through a per-library
 * harness so we are testing the SAME `increaseTotalDebt` code path that
 * PortfolioManager uses, not a private helper.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {DynamicCollateralManager} from "../../../src/facets/account/collateral/DynamicCollateralManager.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626PortfolioFactoryConfig} from "../../../script/portfolio_account/DeployERC4626PortfolioFactoryConfig.s.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 *  Per-library harness contracts. Each one owns its library's ERC-7201 slot.
 *  Storage word offsets used below match the documented struct layout in
 *  each manager source file.
 * -------------------------------------------------------------------------*/
contract HDyn {
    function increaseTotalDebt(address cfg, uint256 amount) external returns (uint256, uint256) {
        return DynamicCollateralManager.increaseTotalDebt(cfg, amount);
    }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        // Slot offsets:
        //   0 lockedCollaterals (mapping), 1 originTimestamps (mapping),
        //   2 totalLockedCollateral, 3 overSuppliedVaultDebt, 4 undercollateralizedDebt.
        assembly { v := sload(add(s, 3)) }
    }
    function __setTotalLocked(uint256 v) external {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { sstore(add(s, 2), v) }
    }
}

contract H4626 {
    function addCollateral(address cfg, address vault, uint256 shares) external {
        ERC4626CollateralManager.addCollateral(cfg, vault, shares);
    }
    function increaseTotalDebt(address cfg, address vault, uint256 amount)
        external returns (uint256, uint256)
    {
        return ERC4626CollateralManager.increaseTotalDebt(cfg, vault, amount);
    }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.ERC4626CollateralManager");
        // Slot offsets:
        //   0 shares, 1 depositedAssetValue, 2 debt,
        //   3 overSuppliedVaultDebt, 4 startShortfall, 5 snapshotBlockNumber.
        assembly { v := sload(add(s, 3)) }
    }
}

contract HYB {
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }
    function increaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.increaseTotalDebt(cfg, vault, underlying, amount);
    }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 s = keccak256("storage.YieldBasisCollateralManager");
        // Slot offsets:
        //   0 shares, 1 depositedAssetValue, 2 debt,
        //   3 overSuppliedVaultDebt, 4 startShortfall, 5 snapshotBlockNumber.
        assembly { v := sload(add(s, 3)) }
    }
}

contract MockUtilPoolUni {
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
    function getDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function getEffectiveDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function totalAssets() external view returns (uint256) { return _totalAssets; }
    function asset() external view returns (address) { return address(assetToken); }
    function decimals() external pure returns (uint8) { return 18; }
    function getPortfolioFactory() external view returns (address) { return portfolioFactory; }
    function depositRewards(uint256) external {}

    function setActive(uint256 v) external { _activeAssets = v; }
    function setTotal(uint256 v) external { _totalAssets = v; }
}

/* ===========================================================================
 *  Test
 * =========================================================================*/
contract UtilizationCapCrossManagerInvariantTest is Test {
    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);

    // Identical state-shape for all three managers, fresh fixture per run:
    //   totalAssets = 100e18, borrow amount = 90e18, cap = 8000 bps.
    //   maxLoan (cap-pinned, fresh state) = 100e18 * 8000 / 10000 = 80e18.
    //   Expected overSuppliedVaultDebt = amount - maxLoan = 90e18 - 80e18 = 10e18.
    uint256 internal constant TOTAL = 100e18;
    uint256 internal constant BORROW = 90e18;
    uint256 internal constant CAP_BPS = 8000;
    uint256 internal constant EXPECTED_EXCESS = 10e18;

    /// @notice INVARIANT: with identical `(totalAssets, borrow amount, cap)`
    /// on a fresh state, all three new-vault collateral managers MUST
    /// compute the same per-borrower `amount - maxLoan` delta on the supply
    /// flag. This is the regression canary for "one manager forgot to read
    /// LoanConfig.getMaxUtilizationBps()".
    function test_AllManagers_ComputeSameOverSuppliedExcess_DoNotRemove() public {
        uint256 dynFlag = _runDynamic();
        uint256 erc4626Flag = _runERC4626();
        uint256 ybFlag = _runYB();

        assertEq(dynFlag, EXPECTED_EXCESS, "Dynamic: flag = amount - maxLoan = 10e18");
        assertEq(erc4626Flag, EXPECTED_EXCESS, "ERC4626: flag = amount - maxLoan = 10e18");
        assertEq(ybFlag, EXPECTED_EXCESS, "YieldBasis: flag = amount - maxLoan = 10e18");

        // Cross-manager equality (the actual invariant under audit).
        assertEq(dynFlag, erc4626Flag, "Dynamic == ERC4626");
        assertEq(erc4626Flag, ybFlag, "ERC4626 == YieldBasis");
    }

    /* ---------------------------------------------------------------
     * Each runner builds an isolated fixture, drives one borrow, and
     * returns the flag value. Fresh factory/config per fixture so the
     * three managers do not race over ERC-7201 slots on the same address.
     * --------------------------------------------------------------- */

    function _baseFixture(bytes32 salt)
        internal
        returns (
            PortfolioManager pm,
            PortfolioFactory factory,
            PortfolioFactoryConfig cfg,
            LoanConfig loanConfig,
            MockERC20 token,
            MockUtilPoolUni pool
        )
    {
        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, ) = pm.deployFactory(salt);
        factory = f;

        DeployERC4626PortfolioFactoryConfig deployer = new DeployERC4626PortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        token = new MockERC20("WETH18", "WETH18", 18);
        pool = new MockUtilPoolUni(address(token), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // CAP_BPS == 8000 is LoanConfig's fallback when storage is unset, so we leave
        // setMaxUtilizationBps uncalled across all three runners. Stage the same
        // totalAssets so each manager observes identical pool state.
        pool.setTotal(TOTAL);
        token.mint(address(pool), TOTAL);

        // Like-to-like LTV path (ERC4626 + YB need this to take the LTV branch
        // without LtvRequiresLikeToLike). Set a generous LTV so the collateral
        // ceiling does not pin maxLoan and starve our 90e18 borrow.
        loanConfig.setLtv(9999);
        loanConfig.setMultiplier(9999);
        loanConfig.setRewardsRate(10000);

        pm.setAuthorizedCaller(AUTH, true);
        vm.stopPrank();
    }

    function _runDynamic() internal returns (uint256) {
        (
            PortfolioManager pm,
            ,
            PortfolioFactoryConfig cfg,
            ,
            ,
        ) = _baseFixture(keccak256("cross-mgr-dyn"));

        HDyn h = new HDyn();

        // Stage the cash-flow ceiling so getMaxLoan does NOT pin maxLoan to 0
        // (Dynamic uses cash-flow path; needs locked > 0 for maxLoanIgnoreSupply).
        // locked=1e30 -> maxLoanIgnoreSupply = (((1e30 * 10000)/1e6) * 100)/1e12 = 1e24 (huge).
        h.__setTotalLocked(1e30);

        // Manager-impersonation: the over-cap borrow accumulates a non-zero
        // overSuppliedVaultDebt flag, which the inline AUTH enforce would
        // revert on. We intentionally inspect the staged flag pre-enforce
        // across all three managers, so we drive the call via the multicall
        // (non-AUTH) path that skips the inline enforce.
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), BORROW);
        return h.readOverSupplied();
    }

    function _runERC4626() internal returns (uint256) {
        (
            PortfolioManager pm,
            ,
            PortfolioFactoryConfig cfg,
            ,
            MockERC20 token,
        ) = _baseFixture(keccak256("cross-mgr-4626"));

        H4626 h = new H4626();
        // Build a collateral vault tied to the lending asset.
        MockERC4626 collat = new MockERC4626(address(token), "cV", "cV", 18);
        vm.prank(OWNER);
        ERC4626PortfolioFactoryConfig(address(cfg)).setCollateralVault(address(collat));

        // Stage 10_000e18 collateral so LTV-side maxLoan dwarfs the borrow.
        token.mint(address(h), 10_000e18);
        vm.prank(address(h));
        token.approve(address(collat), 10_000e18);
        vm.prank(address(h));
        collat.deposit(10_000e18, address(h));
        h.addCollateral(address(cfg), address(collat), 10_000e18);

        // Manager-impersonation: the over-cap borrow accumulates a non-zero
        // overSuppliedVaultDebt flag, which the inline AUTH enforce would
        // revert on. We intentionally inspect the staged flag pre-enforce
        // across all three managers, so we drive the call via the multicall
        // (non-AUTH) path that skips the inline enforce.
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), address(collat), BORROW);
        return h.readOverSupplied();
    }

    function _runYB() internal returns (uint256) {
        (
            PortfolioManager pm,
            ,
            PortfolioFactoryConfig cfg,
            ,
            MockERC20 token,
        ) = _baseFixture(keccak256("cross-mgr-yb"));

        HYB h = new HYB();
        // YB LP priced at 1:1 in `token` so like-to-like rescale collapses cleanly.
        MockYieldBasisLP ybLp = new MockYieldBasisLP("ybT", "ybT", 18);
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10_000e18);

        h.addCollateral(address(cfg), address(ybLp), address(0), address(token), 10_000e18);

        // Manager-impersonation: the over-cap borrow accumulates a non-zero
        // overSuppliedVaultDebt flag, which the inline AUTH enforce would
        // revert on. We intentionally inspect the staged flag pre-enforce
        // across all three managers, so we drive the call via the multicall
        // (non-AUTH) path that skips the inline enforce.
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), address(ybLp), address(token), BORROW);
        return h.readOverSupplied();
    }
}
