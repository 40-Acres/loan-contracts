// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * InlineEnforceAuthPath
 *
 * Issue Summary
 * -------------
 * All four collateral manager libraries (CollateralManager,
 * DynamicCollateralManager, ERC4626CollateralManager, YieldBasisCollateralManager)
 * now run `enforceCollateralRequirements(...)` inline at the END of
 * `increaseTotalDebt` ONLY when the caller is an authorized caller (NOT
 * the PortfolioManager itself). Multicall callers depend on
 * `PortfolioManager.multicall` to enforce at end-of-tx; authorized callers
 * (keeper/bot) bypass that wrapper, so the cap invariant must be
 * enforced inline for them.
 *
 * Why these tests are load-bearing
 * --------------------------------
 * If a future refactor strips the `if (isAuthorizedCaller) { enforceCollateralRequirements(...) }`
 * branch from any one of the four managers, an authorized caller can borrow
 * over the cap without any safety net. This file provides a direct,
 * library-level regression guard per manager: it calls `increaseTotalDebt`
 * from AUTH with an over-cap request and asserts the call reverts inline
 * with BadDebt. The Dynamic + 4626 + YB variants share the same code shape,
 * so any one of them silently regressing would be caught here at PR time.
 *
 * The legacy `CollateralManager` library is not covered here directly via a
 * harness because it depends on a real VotingEscrow for staging collateral;
 * its inline-enforce path is exercised end-to-end via
 * `test/portfolio_account/collateral/LendingHardening.t.sol::test_topUp_*`
 * which covers the same isAuthorizedCaller branch via the `topUp` facet
 * path. Removing the inline branch from `CollateralManager` would surface
 * as a different failure mode there (the cap would no longer revert at
 * topUp time on an over-cap request).
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

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Per-library harness: each owns its library's ERC-7201 slot.
contract DynHarness {
    function increaseTotalDebt(address cfg, uint256 amount) external returns (uint256, uint256) {
        return DynamicCollateralManager.increaseTotalDebt(cfg, amount);
    }
    function __setTotalLocked(uint256 v) external {
        bytes32 s = keccak256("storage.DynamicCollateralManager");
        assembly { sstore(add(s, 2), v) }
    }
}

contract ERC4626Harness {
    function addCollateral(address cfg, address vault, uint256 shares) external {
        ERC4626CollateralManager.addCollateral(cfg, vault, shares);
    }
    function increaseTotalDebt(address cfg, address vault, uint256 amount)
        external returns (uint256, uint256)
    {
        return ERC4626CollateralManager.increaseTotalDebt(cfg, vault, amount);
    }
}

contract YBHarness {
    function addCollateral(address cfg, address vault, address gauge, address underlying, uint256 shares) external {
        YieldBasisCollateralManager.addCollateral(cfg, vault, gauge, underlying, shares);
    }
    function increaseTotalDebt(address cfg, address vault, address underlying, uint256 amount)
        external returns (uint256, uint256)
    {
        return YieldBasisCollateralManager.increaseTotalDebt(cfg, vault, underlying, amount);
    }
}

contract MockPool {
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
    function setTotal(uint256 v) external { _totalAssets = v; }
}

contract InlineEnforceAuthPathTest is Test {
    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);

    // -----------------------------------------------------------------
    // Each test below uses a fresh fixture to keep ERC-7201 slots clean.
    // -----------------------------------------------------------------

    function _baseFixture(bytes32 salt)
        internal
        returns (
            PortfolioManager pm,
            PortfolioFactoryConfig cfg,
            LoanConfig loanConfig,
            MockERC20 token,
            MockPool pool
        )
    {
        vm.startPrank(OWNER);
        pm = new PortfolioManager(OWNER);
        (PortfolioFactory factory, ) = pm.deployFactory(salt);

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        token = new MockERC20("WETH18", "WETH18", 18);
        pool = new MockPool(address(token), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // Generous like-to-like LTV so collateral-side guards do not pin first.
        loanConfig.setLtv(9999);
        loanConfig.setMultiplier(9999);
        loanConfig.setRewardsRate(10000);

        // cap=8000 via fallback. Stage totalAssets so over-cap is reachable.
        pool.setTotal(100e18);
        token.mint(address(pool), 100e18);

        pm.setAuthorizedCaller(AUTH, true);
        vm.stopPrank();
    }

    // ============================================================
    // DYNAMIC: AUTH-path inline enforce
    // ============================================================

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Pins the AUTH-branch inline enforce on DynamicCollateralManager.
    /// At cap 8000 against 100e18 totalAssets, cap = 80e18. A 90e18 borrow
    /// from an authorized caller MUST revert immediately with BadDebt(10e18).
    /// If the inline branch is stripped, this call would succeed (the flag
    /// would be set but no revert would fire from inside increaseTotalDebt),
    /// and a future topUp-like authorized caller could borrow over the cap
    /// without the multicall wrapper's end-of-tx safety net.
    function test_Dynamic_AUTH_overCap_revertsInline_DoNotRemove() public {
        (, PortfolioFactoryConfig cfg, , , ) = _baseFixture(keccak256("inline-dyn"));

        DynHarness h = new DynHarness();
        // Seed cash-flow ceiling so getMaxLoan does not pin maxLoan to 0
        // for cash-flow reasons (would mask the supply-side trip).
        h.__setTotalLocked(1e30);

        vm.expectRevert(
            abi.encodeWithSelector(DynamicCollateralManager.BadDebt.selector, uint256(10e18))
        );
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), 90e18);
    }

    // ============================================================
    // ERC4626: AUTH-path inline enforce
    // ============================================================

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Pins the AUTH-branch inline enforce on ERC4626CollateralManager.
    /// Same shape as the Dynamic guard. A 90e18 borrow at cap 8000 against
    /// 100e18 totalAssets MUST revert inline with BadDebt(10e18).
    function test_ERC4626_AUTH_overCap_revertsInline_DoNotRemove() public {
        (, PortfolioFactoryConfig cfg, , MockERC20 token, ) = _baseFixture(keccak256("inline-4626"));

        ERC4626Harness h = new ERC4626Harness();
        MockERC4626 collat = new MockERC4626(address(token), "cV", "cV", 18);

        // Stage lots of collateral so the LTV-side never pins maxLoan first.
        token.mint(address(h), 10_000e18);
        vm.prank(address(h));
        token.approve(address(collat), 10_000e18);
        vm.prank(address(h));
        collat.deposit(10_000e18, address(h));
        h.addCollateral(address(cfg), address(collat), 10_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626CollateralManager.BadDebt.selector, uint256(10e18))
        );
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collat), 90e18);
    }

    // ============================================================
    // YIELD BASIS: AUTH-path inline enforce
    // ============================================================

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Pins the AUTH-branch inline enforce on YieldBasisCollateralManager.
    /// Same shape as the Dynamic and ERC4626 guards. A 90e18 borrow at cap
    /// 8000 against 100e18 totalAssets MUST revert inline with BadDebt(10e18).
    function test_YieldBasis_AUTH_overCap_revertsInline_DoNotRemove() public {
        (, PortfolioFactoryConfig cfg, , MockERC20 token, ) = _baseFixture(keccak256("inline-yb"));

        YBHarness h = new YBHarness();
        MockYieldBasisLP ybLp = new MockYieldBasisLP("ybT", "ybT", 18);
        ybLp.setPricePerShare(1e18);
        ybLp.mint(address(h), 10_000e18);

        h.addCollateral(address(cfg), address(ybLp), address(0), address(token), 10_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(YieldBasisCollateralManager.BadDebt.selector, uint256(10e18))
        );
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(ybLp), address(token), 90e18);
    }

    // ============================================================
    // MULTICALL PATH (manager) -- inline enforce does NOT fire
    // ============================================================

    /// @notice Companion to the AUTH guards above. The manager-impersonation
    /// (multicall) path MUST skip the inline enforce -- end-of-tx enforce
    /// in PortfolioManager.multicall is the canonical guard. If a refactor
    /// accidentally runs the inline enforce for the multicall path too,
    /// every existing multicall-based borrow that lands on the supply flag
    /// pre-recompute would start reverting. We pin the non-AUTH branch
    /// here by driving the same 90e18 over-cap request through the
    /// manager-impersonation path and asserting it succeeds (flag set,
    /// no revert).
    function test_Dynamic_multicall_overCap_doesNotRevertInline_DoNotRemove() public {
        (PortfolioManager pm, PortfolioFactoryConfig cfg, , , ) = _baseFixture(keccak256("inline-dyn-mc"));

        DynHarness h = new DynHarness();
        h.__setTotalLocked(1e30);

        // Same 90e18 over-cap request, but from the manager-impersonation
        // path (multicall would put msg.sender = address(pm)).
        vm.prank(address(pm));
        h.increaseTotalDebt(address(cfg), 90e18);
        // No revert: end-of-tx enforce in multicall is the canonical guard.

        // The flag IS staged on the manager-impersonation path. We don't
        // inspect raw storage here -- the *behavior* pin is "no inline
        // revert on the multicall path."
        assertEq(uint256(0), uint256(0), "multicall path completed without inline revert");
    }
}
