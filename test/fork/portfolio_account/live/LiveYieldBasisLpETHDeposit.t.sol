// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * LiveYieldBasisLpETHDepositTest — deposit-only validation of the production
 * yb-WETH YieldBasisLpFacet on Ethereum mainnet (salt = "yieldbasiseth").
 *
 * This test exercises the CURRENT deposit semantics in
 * src/facets/account/yieldbasislp/YieldBasisLpFacet.sol: the user brings
 * **LP tokens**. deposit() pulls LP from the owner via
 * `IERC20(_lpToken).safeTransferFrom(...)` and tracks them as collateral.
 * No gauge staking happens inside deposit() — LP sits unstaked on the
 * portfolio account until stake() is explicitly called by the authorized
 * caller.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/portfolio_account/live/LiveYieldBasisLpETHDeposit.t.sol -vv
 *
 * Requires: ETH_RPC_URL env var.
 *
 * --------------------------------------------------------------------------
 * GAP HANDLING (scoped to deposit only)
 *
 * [G0] Facet registry may lack YieldBasisLp selectors; register/replace with
 *      a freshly compiled YieldBasisLpFacet so the test exercises current code.
 * [G2] PortfolioFactoryConfig not wired onto the factory; patch as PM-owner.
 * [G5] gauge.asset() on mainnet may revert if the gauge env var points at the
 *      LP token. Probe and vm.skip with a loud log if so.
 *
 * Skipped gaps (deposit() does not exercise these code paths):
 *   [G1] LoanConfig — deposit does not call getMultiplier / getMaxLoan.
 *   [G3] authorized caller — deposit goes through multicall, not onlyAuthorizedCaller.
 *   [G4] RewardsConfigFacet / rewards token.
 *
 * Because G1 is NOT patched here, DO NOT call `getMaxLoan()` inside this test
 * — it reads `loanConfig.getMultiplier()` and will revert with "multiplier=0"
 * (or an empty revert if loanConfig is the zero address).
 */

import {Test, console} from "forge-std/Test.sol";

// Core
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";

// Facet under test
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {AccessControl} from "../../../../src/facets/account/utils/AccessControl.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

// External
import {LendingVault} from "../../../../src/facets/account/vault/LendingVault.sol";
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiveYieldBasisLpETHDepositTest is Test {
    // ─── Live addresses (hardcoded — the production deployment) ─────────────
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant LIVE_VAULT = 0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3;
    address public constant LIVE_GAUGE = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address public constant YB_WETH_LP = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant ASSUMED_PFC = 0x8706FD061241266959e6A6E9e084f34935087012;

    bytes32 public constant FACTORY_SALT = keccak256(abi.encodePacked("yieldbasiseth"));

    // ─── Discovered / wired ─────────────────────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LendingVault public vault;
    IYieldBasisGauge public gauge;
    IERC20 public lpToken;

    // ─── Test actors ────────────────────────────────────────────────────────
    address public user = address(uint160(uint256(keccak256("live-ybeth-deposit-user"))));
    address public portfolioAccount;

    // Mirror of Deposited(address,uint256) for vm.expectEmit
    event Deposited(address indexed from, uint256 amount);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);

        // Discover the yb-WETH factory by salt.
        address factoryAddr = portfolioManager.factoryBySalt(FACTORY_SALT);
        if (factoryAddr == address(0)) {
            console.log("[SKIP] No factory for salt 'yieldbasiseth' on this fork.");
            vm.skip(true);
            return;
        }
        portfolioFactory = PortfolioFactory(factoryAddr);
        facetRegistry = portfolioFactory.facetRegistry();

        vm.label(address(portfolioManager), "PortfolioManager");
        vm.label(address(portfolioFactory), "PortfolioFactory");
        vm.label(address(facetRegistry), "FacetRegistry");
        vm.label(LIVE_VAULT, "LendingVault");
        vm.label(WETH, "WETH");
        vm.label(YB, "YB");

        vault = LendingVault(LIVE_VAULT);
        gauge = IYieldBasisGauge(LIVE_GAUGE);
        vm.label(LIVE_GAUGE, "YB-ETH-Gauge");

        // [G5] Probe gauge.asset(). If it reverts, the configured gauge
        //      address is actually the LP token and the deploy is broken.
        //      Skip loudly rather than fail obscurely.
        try gauge.asset() returns (address lpAddr) {
            lpToken = IERC20(lpAddr);
            vm.label(address(lpToken), "YB-ETH-LP");
        } catch {
            console.log("[G5 FINDING] gauge.asset() reverted for address:", LIVE_GAUGE);
            console.log("             Likely the gauge address is actually the LP token.");
            vm.skip(true);
            return;
        }

        // [G2] Wire PortfolioFactoryConfig onto the factory if not already.
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();
        if (address(portfolioFactoryConfig) == address(0)) {
            console.log("[PATCH G2] PortfolioFactoryConfig not wired; using ASSUMED_PFC:", ASSUMED_PFC);
            require(ASSUMED_PFC.code.length > 0, "ASSUMED_PFC has no code on this fork");
            address pmOwner = portfolioManager.owner();
            vm.prank(pmOwner);
            portfolioFactory.setPortfolioFactoryConfig(ASSUMED_PFC);
            portfolioFactoryConfig = PortfolioFactoryConfig(ASSUMED_PFC);
        }

        // Intentionally NOT patching LoanConfig (gap G1). deposit() does not
        // touch LoanConfig — but getMaxLoan() does, so the test never calls it.

        // [G0] Register / replace YieldBasisLpFacet with freshly compiled
        //      bytecode so we exercise the current source. Register all 10
        //      selectors so getTotalLockedCollateral routes correctly.
        if (facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector) == address(0)) {
            console.log("[PATCH G0] Registering YieldBasisLpFacet (fresh bytecode).");
            _registerYieldBasisLpFacet();
        } else {
            _replaceYieldBasisLpFacet();
        }

        // Create or fetch portfolio for test user
        portfolioAccount = portfolioFactory.portfolioOf(user);
        if (portfolioAccount == address(0)) {
            portfolioAccount = portfolioFactory.createAccount(user);
        }
        vm.label(portfolioAccount, "Portfolio");

        // Never warp backwards; a +1/+1 settles any freshly-created state.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _multicallAsUser(bytes memory data) internal {
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = data;
        vm.prank(user);
        portfolioManager.multicall(calls, factories);
    }

    function _dealLp(address to, uint256 amount) internal {
        // yb-WETH LP uses custom storage; forge-std `deal` produces a
        // balance the transferFrom path refuses to honor. Impersonate the
        // gauge (top LP holder) and transfer LP into `to` instead.
        address holder = address(gauge);
        require(lpToken.balanceOf(holder) >= amount, "gauge LP balance too low to deal");
        vm.prank(holder);
        lpToken.transfer(to, amount);
        require(lpToken.balanceOf(to) >= amount, "LP deal failed");
    }

    /// Deal gauge shares to `to` by funding LP and staking through the gauge.
    /// Returns the exact shares minted (pricePerShare != 1, so not equal to lpAmount).
    function _dealGaugeShares(address to, uint256 lpAmount) internal returns (uint256 shares) {
        _dealLp(to, lpAmount);
        vm.startPrank(to);
        lpToken.approve(address(gauge), lpAmount);
        shares = gauge.deposit(lpAmount, to);
        vm.stopPrank();
        require(shares > 0, "gauge minted 0 shares");
        require(IERC20(address(gauge)).balanceOf(to) >= shares, "gauge share deal failed");
    }

    function _lpFacetSelectors() internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](9);
        sel[0] = YieldBasisLpFacet.deposit.selector;
        sel[1] = YieldBasisLpFacet.withdraw.selector;
        sel[2] = YieldBasisLpFacet.setStakedMode.selector;
        sel[3] = YieldBasisLpFacet.getStakingState.selector;
        sel[4] = ICollateralFacet.getTotalLockedCollateral.selector;
        sel[5] = ICollateralFacet.getTotalDebt.selector;
        sel[6] = ICollateralFacet.getMaxLoan.selector;
        sel[7] = ICollateralFacet.enforceCollateralRequirements.selector;
        sel[8] = ICollateralFacet.getLoanUtilization.selector;
    }

    function _registerYieldBasisLpFacet() internal {
        address registryOwner = facetRegistry.owner();
        YieldBasisLpFacet lpFacet = new YieldBasisLpFacet(
            address(portfolioFactory), address(gauge), YB, LIVE_VAULT
        );
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(lpFacet), _lpFacetSelectors(), "YieldBasisLpFacet");
    }

    function _replaceYieldBasisLpFacet() internal {
        address oldFacet = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
        YieldBasisLpFacet newFacet = new YieldBasisLpFacet(
            address(portfolioFactory), address(gauge), YB, LIVE_VAULT
        );
        vm.prank(facetRegistry.owner());
        facetRegistry.replaceFacet(oldFacet, address(newFacet), _lpFacetSelectors(), "YieldBasisLpFacet");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────

    /// Primary happy-path: user deposits **LP tokens** (current semantics).
    /// deposit() pulls LP from the owner onto the portfolio account and tracks
    /// it as collateral. No gauge staking happens inside deposit().
    ///
    /// Renamed from the prior "DepositPullsGaugeShares..." name which described
    /// the old (no longer implemented) semantics. Intent preserved: validate the
    /// deposit happy path end-to-end with event emission, balance deltas, and
    /// collateral tracking, against the live wiring.
    function testDepositPullsLpAndTracksCollateral() public {
        // [G6 GAP] The live YieldBasisPortfolioFactoryConfig may predate the
        // setStakedGaugeMode method that the new deposit() path reads via
        // getStakedMode(). Skip BEFORE any state-changing call when the probe
        // reverts so CI flags the upgrade dependency rather than failing
        // mid-deposit.
        try YieldBasisPortfolioFactoryConfig(address(portfolioFactoryConfig)).getStakedGaugeMode() returns (bool) {
            // proceed
        } catch {
            console.log("[SKIP G6] live YieldBasisPortfolioFactoryConfig predates getStakedGaugeMode; awaiting production upgrade");
            vm.skip(true);
            return;
        }

        uint256 depositAmount = 1 ether;
        _dealLp(user, depositAmount);

        // Approve the portfolio account to pull LP tokens (NOT gauge shares).
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        assertEq(
            lpToken.allowance(user, portfolioAccount),
            depositAmount,
            "LP allowance(user, portfolio) not set"
        );

        // Sanity: the registered facet binds gauge + LP correctly.
        address facetAddr = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
        assertEq(
            address(YieldBasisLpFacet(facetAddr)._lpToken()),
            address(lpToken),
            "facet _lpToken bound incorrectly"
        );
        assertEq(
            address(YieldBasisLpFacet(facetAddr)._gauge()),
            address(gauge),
            "facet _gauge bound incorrectly"
        );

        // Pre-state (use deltas so any pre-existing balances don't poison the test)
        IERC20 gaugeTok = IERC20(address(gauge));
        uint256 lpBeforeUser = lpToken.balanceOf(user);
        uint256 lpBeforeAccount = lpToken.balanceOf(portfolioAccount);
        uint256 gaugeBeforeAccount = gaugeTok.balanceOf(portfolioAccount);
        (uint256 stakedBefore, uint256 unstakedBefore) =
            YieldBasisLpFacet(portfolioAccount).getStakingState();
        uint256 collatBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Event: Deposited(owner=user, amount=depositAmount)
        vm.expectEmit(true, false, false, true, portfolioAccount);
        emit Deposited(user, depositAmount);

        _multicallAsUser(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount));

        // Post-state
        uint256 lpAfterUser = lpToken.balanceOf(user);
        uint256 lpAfterAccount = lpToken.balanceOf(portfolioAccount);
        uint256 gaugeAfterAccount = gaugeTok.balanceOf(portfolioAccount);
        (uint256 stakedAfter, uint256 unstakedAfter) =
            YieldBasisLpFacet(portfolioAccount).getStakingState();
        uint256 collatAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // User's LP was pulled: -depositAmount
        assertEq(
            lpBeforeUser - lpAfterUser,
            depositAmount,
            "user LP debit != amount deposited"
        );

        // Portfolio account received the LP
        assertEq(
            lpAfterAccount - lpBeforeAccount,
            depositAmount,
            "portfolio LP credit != amount deposited"
        );

        // Gauge balance on the portfolio account must NOT change — deposit does
        // not stake into the gauge. Gauge shares only appear after explicit stake().
        assertEq(
            gaugeAfterAccount,
            gaugeBeforeAccount,
            "gauge share balance on portfolio must not change on LP deposit"
        );

        // getStakingState(): staked tracks gauge.balanceOf(account), so must be unchanged.
        // unstaked tracks lpToken.balanceOf(account), so must increase by exactly depositAmount.
        assertEq(
            stakedAfter,
            stakedBefore,
            "staked should not change on LP deposit (no auto-stake)"
        );
        assertEq(
            unstakedAfter - unstakedBefore,
            depositAmount,
            "unstaked delta must equal amount deposited"
        );

        // Collateral tracked — must strictly increase from deposit.
        assertGt(collatAfter, collatBefore, "collateral did not increase after deposit");

        console.log("[OK] LP pulled:", depositAmount);
        console.log("[OK] collateral delta:", collatAfter - collatBefore);
    }

    /// deposit(0) must revert (the facet guards "Zero amount"). The revert
    /// is raised inside the facet and bubbled up by PortfolioManager.multicall.
    /// We match on the raw "Zero amount" string being present in the returndata.
    function testDepositZeroReverts() public {
        // Build the multicall payload manually so we can vm.expectRevert
        // right before the external call.
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, uint256(0));

        vm.prank(user);
        vm.expectRevert(bytes("Zero amount"));
        portfolioManager.multicall(calls, factories);
    }

    /// deposit without **LP** approval must revert: SafeERC20 forwards whatever
    /// the LP token's transferFrom raises on insufficient allowance. We don't
    /// pin the selector — the yb-WETH LP's ERC20 impl is bespoke and its revert
    /// shape is not guaranteed to match OZ.
    function testDepositWithoutApprovalReverts() public {
        uint256 depositAmount = 1 ether;
        _dealLp(user, depositAmount);
        // Explicitly do NOT approve LP.

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);

        vm.prank(user);
        vm.expectRevert();
        portfolioManager.multicall(calls, factories);
    }

    /// Direct calls (bypassing PortfolioManager.multicall) must revert at the
    /// onlyPortfolioManagerMulticall modifier with NotPortfolioManagerMulticall().
    function testDepositDirectCallReverts() public {
        uint256 depositAmount = 1 ether;
        _dealLp(user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        vm.prank(user);
        vm.expectRevert(AccessControl.NotPortfolioManagerMulticall.selector);
        YieldBasisLpFacet(portfolioAccount).deposit(depositAmount);
    }
}
