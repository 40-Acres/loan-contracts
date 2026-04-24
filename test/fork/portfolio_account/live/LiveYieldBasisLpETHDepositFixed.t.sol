// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * LiveYieldBasisLpETHDepositFixedTest — verification that the YieldBasis refactor
 * fixes the production yb-WETH deposit failure for real user
 * 0x84f2213CCBc3eCa68bbF01365549E9f42A5515fB.
 *
 * Background:
 *   Deposits previously failed with PortfolioManager.CallFailed(portfolio, reason=0x)
 *   because YieldBasisLpFacet.deposit routed through ERC4626CollateralManager, whose
 *   _resolveCollateralValue called IERC4626(LP).convertToAssets(...). The yb-WETH LP
 *   is NOT ERC4626 and that call reverts with empty data. (See
 *   LiveYieldBasisLpETHDepositRepro.t.sol for the triage logs — that file stays
 *   intact as a regression signal and is NOT reused here.)
 *
 * Fix under test:
 *   - New library YieldBasisCollateralManager prices collateral via
 *     IYieldBasisLP(vault).pricePerShare() — no ERC4626 calls.
 *   - New ERC-7201 slot storage.YieldBasisCollateralManager.
 *   - YieldBasisLpFacet constructor is now
 *       (portfolioFactory, gauge, rewardToken, underlying).
 *   - deposit now passes (_lpToken, _underlying) to
 *     YieldBasisCollateralManager.addCollateral.
 *
 * What this test proves:
 *   1. A freshly compiled YieldBasisLpFacet (new constructor, new manager) installed
 *      on the live factoryBySalt("yieldbasiseth") factory successfully deposits the
 *      real user's actual LP balance via the real PortfolioManager.multicall path.
 *   2. Collateral is tracked correctly at amount * pricePerShare / 1e18.
 *   3. The Deposited event is emitted by the portfolio account.
 *   4. A deposit-then-withdraw round trip restores LP balance and collateral.
 *
 * Verification discipline:
 *   - Uses the REAL user, not a synthesized one. If on-fork LP balance is zero,
 *     the test skips loudly — it does NOT deal tokens to the user.
 *   - Uses real assertEq/assertGt. This is a verification test, not a triage test.
 *   - Patches are scoped to the test: facet register/replace + G2 PFC wiring.
 *     No production contract is modified.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/portfolio_account/live/LiveYieldBasisLpETHDepositFixed.t.sol -vv
 *
 * Requires: ETH_RPC_URL env var (latest mainnet block, no pin).
 */

import {Test, console} from "forge-std/Test.sol";

// Core
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";

// Facet under test + collateral surface
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

// External
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal inline interface for pricePerShare — do not widen.
interface IYieldBasisLPPps {
    function pricePerShare() external view returns (uint256);
}

contract LiveYieldBasisLpETHDepositFixedTest is Test {
    // ─── Live addresses (production mainnet) ────────────────────────────────
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant LIVE_GAUGE            = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address public constant YB_WETH_LP            = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address public constant WETH                  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant YB                    = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant ASSUMED_PFC           = 0x8706FD061241266959e6A6E9e084f34935087012;

    bytes32 public constant FACTORY_SALT = keccak256(abi.encodePacked("yieldbasiseth"));

    // Real user under investigation — do not synthesize.
    address public constant USER = 0x84f2213CCBc3eCa68bbF01365549E9f42A5515fB;

    // ─── Discovered / wired ─────────────────────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    IYieldBasisGauge public gauge;
    IERC20 public lpToken;

    address public portfolioAccount;
    uint256 public userLpAtSetup;

    // Mirror of Deposited(address,uint256) for vm.expectEmit
    event Deposited(address indexed from, uint256 amount);

    function setUp() public {
        // (1) Fork latest mainnet — no pinned block.
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);
        vm.label(address(portfolioManager), "PortfolioManager");
        vm.label(USER, "USER(0x84f2...15fB)");

        console.log("=== Live YieldBasisLp ETH Deposit -- FIX VERIFICATION ===");
        console.log("PortfolioManager:", address(portfolioManager));
        console.log("USER:            ", USER);

        // (2) Discover yb-WETH factory by salt.
        address factoryAddr = portfolioManager.factoryBySalt(FACTORY_SALT);
        console.log("factoryBySalt('yieldbasiseth'):", factoryAddr);
        if (factoryAddr == address(0)) {
            console.log("[SKIP] No factory registered for salt 'yieldbasiseth' on this fork.");
            vm.skip(true);
            return;
        }
        portfolioFactory = PortfolioFactory(factoryAddr);
        facetRegistry = portfolioFactory.facetRegistry();

        vm.label(address(portfolioFactory), "PortfolioFactory");
        vm.label(address(facetRegistry), "FacetRegistry");
        vm.label(LIVE_GAUGE, "YB-ETH-Gauge");
        vm.label(YB_WETH_LP, "YB-ETH-LP");
        vm.label(WETH, "WETH");
        vm.label(YB, "YB");

        gauge = IYieldBasisGauge(LIVE_GAUGE);
        lpToken = IERC20(YB_WETH_LP);

        // (3) [G2] Wire PortfolioFactoryConfig onto the factory if not already.
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();
        if (address(portfolioFactoryConfig) == address(0)) {
            console.log("[PATCH G2] PortfolioFactoryConfig not wired; using ASSUMED_PFC:", ASSUMED_PFC);
            require(ASSUMED_PFC.code.length > 0, "ASSUMED_PFC has no code on this fork");
            address pmOwner = portfolioManager.owner();
            vm.prank(pmOwner);
            portfolioFactory.setPortfolioFactoryConfig(ASSUMED_PFC);
            portfolioFactoryConfig = PortfolioFactoryConfig(ASSUMED_PFC);
        }
        console.log("portfolioFactory.portfolioFactoryConfig():", address(portfolioFactoryConfig));

        // (4) Register / replace YieldBasisLpFacet with the NEW constructor shape.
        //     This is the core of the verification — we want the freshly compiled
        //     facet, routed through YieldBasisCollateralManager + pricePerShare.
        if (facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector) == address(0)) {
            console.log("[PATCH G0] Registering YieldBasisLpFacet (fresh bytecode, new ctor).");
            _registerYieldBasisLpFacet();
        } else {
            console.log("[PATCH G0] Replacing YieldBasisLpFacet (fresh bytecode, new ctor).");
            _replaceYieldBasisLpFacet();
        }

        // (5) Sanity: facet immutables must point at live LP/gauge/underlying.
        address facetAddr = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
        require(facetAddr != address(0), "deposit selector not registered after patch");
        assertEq(
            address(YieldBasisLpFacet(facetAddr)._lpToken()),
            YB_WETH_LP,
            "facet _lpToken bound incorrectly"
        );
        assertEq(
            address(YieldBasisLpFacet(facetAddr)._gauge()),
            LIVE_GAUGE,
            "facet _gauge bound incorrectly"
        );
        assertEq(
            YieldBasisLpFacet(facetAddr)._underlying(),
            WETH,
            "facet _underlying bound incorrectly"
        );

        // (6) Resolve or create USER's portfolio account.
        address existing = portfolioFactory.portfolioOf(USER);
        if (existing == address(0)) {
            portfolioAccount = portfolioFactory.createAccount(USER);
            console.log("[setup] createAccount(USER) -> portfolio:", portfolioAccount);
        } else {
            portfolioAccount = existing;
            console.log("[setup] reusing existing portfolio:", portfolioAccount);
        }
        vm.label(portfolioAccount, "Portfolio(USER)");

        // (7) Read user's actual LP balance. Do NOT deal. Skip loudly if zero.
        userLpAtSetup = lpToken.balanceOf(USER);
        console.log("user LP balance on fork:", userLpAtSetup);
        if (userLpAtSetup == 0) {
            console.log("[SKIP] USER has zero yb-WETH LP on this fork. Not dealing -- skipping.");
            vm.skip(true);
            return;
        }

        // Settle any freshly-created state. Never warp backward.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _lpFacetSelectors() internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](10);
        sel[0] = YieldBasisLpFacet.deposit.selector;
        sel[1] = YieldBasisLpFacet.withdraw.selector;
        sel[2] = YieldBasisLpFacet.unstake.selector;
        sel[3] = YieldBasisLpFacet.stake.selector;
        sel[4] = YieldBasisLpFacet.getStakingState.selector;
        sel[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        sel[6] = ICollateralFacet.getTotalDebt.selector;
        sel[7] = ICollateralFacet.getMaxLoan.selector;
        sel[8] = ICollateralFacet.enforceCollateralRequirements.selector;
        sel[9] = ICollateralFacet.getLTVRatio.selector;
    }

    function _registerYieldBasisLpFacet() internal {
        YieldBasisLpFacet lpFacet =
            new YieldBasisLpFacet(address(portfolioFactory), address(gauge), YB, WETH);
        address registryOwner = facetRegistry.owner();
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(lpFacet), _lpFacetSelectors(), "YieldBasisLpFacet");
    }

    function _replaceYieldBasisLpFacet() internal {
        address oldFacet = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
        YieldBasisLpFacet newFacet =
            new YieldBasisLpFacet(address(portfolioFactory), address(gauge), YB, WETH);
        vm.prank(facetRegistry.owner());
        facetRegistry.replaceFacet(oldFacet, address(newFacet), _lpFacetSelectors(), "YieldBasisLpFacet");
    }

    function _depositAsUser(uint256 amount) internal {
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        vm.prank(USER);
        portfolioManager.multicall(calls, factories);
    }

    function _withdrawAsUser(uint256 amount) internal {
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        vm.prank(USER);
        portfolioManager.multicall(calls, factories);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────

    /// Primary verification: the fix lets the real user deposit their real LP.
    /// Asserts:
    ///   - multicall succeeds (no CallFailed(reason=0x) from the old ERC4626 path)
    ///   - user LP debited by `amount`
    ///   - portfolio LP credited by `amount`
    ///   - getTotalLockedCollateral > 0 and equals amount * pricePerShare / 1e18
    ///   - Deposited(USER, amount) emitted from the portfolio account
    function testRealUserDepositSucceedsAfterFix() public {
        uint256 amount = userLpAtSetup; // deposit the user's full balance
        console.log("deposit amount:", amount);

        // Approve the portfolio account to pull LP from the user (deposit()
        // transfers via safeTransferFrom from the owner).
        vm.prank(USER);
        lpToken.approve(portfolioAccount, amount);
        assertEq(
            lpToken.allowance(USER, portfolioAccount),
            amount,
            "LP allowance(USER, portfolio) not set"
        );

        // Snapshot pre-state deltas — pre-existing balances on the fork must
        // not poison the assertions.
        uint256 preUserLp = lpToken.balanceOf(USER);
        uint256 prePortLp = lpToken.balanceOf(portfolioAccount);
        uint256 preCollat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Read pricePerShare right before the deposit so the expected-collateral
        // math uses a value consistent with what the facet will observe.
        uint256 pps = IYieldBasisLPPps(YB_WETH_LP).pricePerShare();
        console.log("LP pricePerShare:", pps);
        uint256 expectedCollatDelta = (amount * pps) / 1e18;
        console.log("expected collateral delta:", expectedCollatDelta);

        // Expect the Deposited event from the portfolio account.
        vm.expectEmit(true, false, false, true, portfolioAccount);
        emit Deposited(USER, amount);

        // Execute the deposit — this is the call that used to revert
        // CallFailed(reason=0x) through the ERC4626 path.
        _depositAsUser(amount);

        // Post-state
        uint256 postUserLp = lpToken.balanceOf(USER);
        uint256 postPortLp = lpToken.balanceOf(portfolioAccount);
        uint256 postCollat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        assertEq(preUserLp - postUserLp, amount, "user LP debit != amount");
        assertEq(postPortLp - prePortLp, amount, "portfolio LP credit != amount");
        assertGt(postCollat, preCollat, "collateral did not increase after deposit");
        assertEq(
            postCollat - preCollat,
            expectedCollatDelta,
            "collateral delta != amount * pricePerShare / 1e18"
        );

        console.log("[OK] deposit succeeded");
        console.log("[OK] collateral delta:", postCollat - preCollat);
    }

    /// Round trip: deposit then withdraw via multicall. Verifies the new
    /// YieldBasisCollateralManager.removeCollateral path works too.
    /// Asserts:
    ///   - After withdraw, user LP balance is restored to the pre-deposit value.
    ///   - After withdraw, collateral on the account is back to its pre-deposit value.
    function testDepositThenWithdrawRoundTrip() public {
        uint256 amount = userLpAtSetup;
        console.log("round-trip amount:", amount);

        // Approve for deposit.
        vm.prank(USER);
        lpToken.approve(portfolioAccount, amount);

        uint256 preUserLp = lpToken.balanceOf(USER);
        uint256 prePortLp = lpToken.balanceOf(portfolioAccount);
        uint256 preCollat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        _depositAsUser(amount);

        uint256 midUserLp = lpToken.balanceOf(USER);
        uint256 midPortLp = lpToken.balanceOf(portfolioAccount);
        uint256 midCollat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(preUserLp - midUserLp, amount, "mid: user LP debit != amount");
        assertEq(midPortLp - prePortLp, amount, "mid: portfolio LP credit != amount");
        assertGt(midCollat, preCollat, "mid: collateral did not increase after deposit");

        // Withdraw the same amount back to USER.
        _withdrawAsUser(amount);

        uint256 postUserLp = lpToken.balanceOf(USER);
        uint256 postPortLp = lpToken.balanceOf(portfolioAccount);
        uint256 postCollat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // User LP fully restored.
        assertEq(postUserLp, preUserLp, "user LP not fully restored after withdraw");
        // Portfolio LP back to pre-deposit state.
        assertEq(postPortLp, prePortLp, "portfolio LP did not return to pre-deposit level");
        // Collateral returned to pre-deposit level (may be 0 if this portfolio
        // had no prior collateral).
        assertEq(postCollat, preCollat, "collateral did not return to pre-deposit level");

        console.log("[OK] round trip complete");
    }
}
