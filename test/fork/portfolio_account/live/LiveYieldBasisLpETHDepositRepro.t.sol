// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * LiveYieldBasisLpETHDepositReproTest — DIAGNOSTIC / TRIAGE test.
 *
 * Reproduces the deposit failure observed on production yb-WETH
 * (salt = "yieldbasiseth") for the specific real mainnet user
 * 0x84f2213CCBc3eCa68bbF01365549E9f42A5515fB.
 *
 * THIS IS A LOGS-ONLY TEST. It must be green regardless of whether the
 * deposit call succeeds or reverts. Its job is to:
 *
 *   1. Probe the live production wiring (factory, registry, config, facet,
 *      _lpToken, _gauge, _rewardToken) and log everything.
 *   2. Attempt a deposit of the user's actual on-fork LP balance via the
 *      real PortfolioManager.multicall path, with NO vm.expectRevert, and
 *      decode + log the revert selector / reason if it fails.
 *   3. Attempt a direct-call deposit on the portfolio (expected to revert
 *      because of onlyPortfolioManagerMulticall) and log that too.
 *
 * Does NOT register, replace, or patch any facets. Does NOT patch
 * PortfolioFactoryConfig, LoanConfig, or FacetRegistry. If the production
 * wiring is broken, that broken wiring is the finding.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/portfolio_account/live/LiveYieldBasisLpETHDepositRepro.t.sol -vv
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

// Facet under test
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

// External
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiveYieldBasisLpETHDepositReproTest is Test {
    // ─── Live addresses (production mainnet) ────────────────────────────────
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant KNOWN_YB_WETH_LP = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address public constant KNOWN_YB_WETH_GAUGE = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;

    bytes32 public constant FACTORY_SALT = keccak256(abi.encodePacked("yieldbasiseth"));

    // Real user under investigation.
    address public constant USER = 0x84f2213CCBc3eCa68bbF01365549E9f42A5515fB;

    // ─── Discovered / wired (probe-only; no patching) ───────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    address public depositFacetAddr;
    IYieldBasisGauge public gauge;
    IERC20 public lpToken;
    address public rewardToken;

    address public portfolioAccount;
    bool public haltBeforeRepro;

    function setUp() public {
        // (1) Fork latest mainnet — no pinned block.
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);
        vm.label(address(portfolioManager), "PortfolioManager");
        vm.label(USER, "USER(0x84f2...15fB)");

        console.log("=== Live YieldBasisLp ETH Deposit Triage ===");
        console.log("PortfolioManager:", address(portfolioManager));
        console.log("USER:            ", USER);

        // (2) Resolve yb-WETH factory by salt.
        address factoryAddr = portfolioManager.factoryBySalt(FACTORY_SALT);
        console.log("factoryBySalt('yieldbasiseth'):", factoryAddr);
        if (factoryAddr == address(0)) {
            console.log("[SKIP] No factory registered for salt 'yieldbasiseth' on this fork.");
            vm.skip(true);
            return;
        }
        portfolioFactory = PortfolioFactory(factoryAddr);
        vm.label(address(portfolioFactory), "PortfolioFactory");

        // (3) Read factory-level wiring. Log but do NOT patch.
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();
        facetRegistry = portfolioFactory.facetRegistry();
        console.log("portfolioFactory.portfolioFactoryConfig():", address(portfolioFactoryConfig));
        console.log("portfolioFactory.facetRegistry():        ", address(facetRegistry));
        if (address(portfolioFactoryConfig) == address(0)) {
            console.log("[FINDING] portfolioFactoryConfig is zero - deployment gap.");
            console.log("          Not patching; continuing so we still observe deposit revert shape.");
        }
        if (address(facetRegistry) != address(0)) {
            vm.label(address(facetRegistry), "FacetRegistry");
        }

        // (4) Resolve the facet that answers YieldBasisLpFacet.deposit.selector.
        if (address(facetRegistry) == address(0)) {
            console.log("[FINDING] facetRegistry is zero - cannot look up deposit facet.");
            haltBeforeRepro = true;
        } else {
            depositFacetAddr = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
            console.log("FacetRegistry.getFacetForSelector(deposit):", depositFacetAddr);
            if (depositFacetAddr == address(0)) {
                console.log("[FINDING] deposit selector not registered on FacetRegistry.");
                haltBeforeRepro = true;
            } else {
                vm.label(depositFacetAddr, "YieldBasisLpFacet(registered)");
            }
        }

        // (5) If we have the registered facet, read its immutables for wiring.
        if (!haltBeforeRepro) {
            _probeFacetImmutables(depositFacetAddr);
        } else {
            // Even without a facet, probe the known-correct LP/gauge to log user balances.
            lpToken = IERC20(KNOWN_YB_WETH_LP);
            gauge = IYieldBasisGauge(KNOWN_YB_WETH_GAUGE);
        }

        // (6) Log user on-chain balances.
        _logUserBalances();

        // (7) Resolve / create portfolio account.
        address existing = portfolioFactory.portfolioOf(USER);
        console.log("portfolioFactory.portfolioOf(USER):", existing);
        if (existing == address(0)) {
            // createAccount is an open function — no prank needed.
            portfolioAccount = portfolioFactory.createAccount(USER);
            console.log("[setup] createAccount(USER) -> portfolio:", portfolioAccount);
        } else {
            portfolioAccount = existing;
            console.log("[setup] reusing existing portfolio:", portfolioAccount);
        }
        vm.label(portfolioAccount, "Portfolio");

        // Settle any freshly-created state. Never warp backward.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function _probeFacetImmutables(address facet) internal {
        // Use try-style low-level reads so a misdeployed facet doesn't abort setUp.
        try YieldBasisLpFacet(facet)._lpToken() returns (IERC20 lp) {
            lpToken = lp;
            console.log("facet._lpToken():     ", address(lp));
            if (address(lp) != KNOWN_YB_WETH_LP) {
                console.log("[WARN] facet._lpToken mismatch. expected:", KNOWN_YB_WETH_LP);
            }
        } catch {
            console.log("[WARN] facet._lpToken() reverted");
        }
        try YieldBasisLpFacet(facet)._gauge() returns (IYieldBasisGauge g) {
            gauge = g;
            console.log("facet._gauge():       ", address(g));
            if (address(g) != KNOWN_YB_WETH_GAUGE) {
                console.log("[WARN] facet._gauge mismatch. expected:", KNOWN_YB_WETH_GAUGE);
            }
        } catch {
            console.log("[WARN] facet._gauge() reverted");
        }
        try YieldBasisLpFacet(facet)._rewardToken() returns (address r) {
            rewardToken = r;
            console.log("facet._rewardToken(): ", r);
        } catch {
            console.log("[WARN] facet._rewardToken() reverted");
        }
    }

    function _logUserBalances() internal view {
        if (address(lpToken) != address(0)) {
            console.log("user lpToken balance:", lpToken.balanceOf(USER));
        } else {
            console.log("[skip] lpToken unknown, cannot read user LP balance");
        }
        if (address(gauge) != address(0)) {
            console.log("user gauge shares:   ", IERC20(address(gauge)).balanceOf(USER));
        } else {
            console.log("[skip] gauge unknown, cannot read user gauge shares");
        }
        console.log("user ETH balance:    ", USER.balance);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Decode helpers
    // ─────────────────────────────────────────────────────────────────────

    function _logSelectorPrefix(bytes memory data) internal pure {
        if (data.length < 4) {
            console.log("[decode] returndata shorter than 4 bytes; length:", data.length);
            console.logBytes(data);
            return;
        }
        bytes4 sel;
        assembly {
            sel := mload(add(data, 32))
        }
        console.log("[decode] selector bytes (hex):");
        console.logBytes4(sel);

        if (sel == 0x08c379a0) {
            // Error(string)
            if (data.length >= 4 + 64) {
                bytes memory payload = new bytes(data.length - 4);
                for (uint256 i = 0; i < payload.length; i++) {
                    payload[i] = data[i + 4];
                }
                string memory reason = abi.decode(payload, (string));
                console.log("[decode] Error(string):", reason);
            } else {
                console.log("[decode] 0x08c379a0 but payload too short to decode");
            }
        } else if (sel == 0x4e487b71) {
            // Panic(uint256)
            if (data.length >= 4 + 32) {
                bytes memory payload = new bytes(data.length - 4);
                for (uint256 i = 0; i < payload.length; i++) {
                    payload[i] = data[i + 4];
                }
                uint256 code = abi.decode(payload, (uint256));
                console.log("[decode] Panic(uint256) code:", code);
            } else {
                console.log("[decode] 0x4e487b71 but payload too short to decode");
            }
        } else {
            console.log("[decode] unknown custom error selector; raw data below:");
            console.logBytes(data);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // The one test
    // ─────────────────────────────────────────────────────────────────────

    function testReproDepositFailure() public {
        if (haltBeforeRepro) {
            console.log("[HALT] prerequisite wiring missing; triage already logged in setUp. Done.");
            return;
        }
        if (address(lpToken) == address(0)) {
            console.log("[HALT] lpToken unknown; cannot build deposit payload. Done.");
            return;
        }

        uint256 amount = lpToken.balanceOf(USER);
        console.log("deposit amount (user's LP balance):", amount);
        if (amount == 0) {
            console.log("[HALT] user has zero LP balance on this fork. Nothing to deposit. Done.");
            return;
        }

        // Approve the portfolio account to pull LP from the user (deposit()
        // path inside the facet transfers LP via safeTransferFrom).
        vm.prank(USER);
        lpToken.approve(portfolioAccount, amount);
        console.log(
            "post-approve lpToken.allowance(USER, portfolio):",
            lpToken.allowance(USER, portfolioAccount)
        );

        // Build exact multicall args: factories=[factory], calls=[deposit(amount)].
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);

        // Snapshot pre-balances.
        uint256 preUserLp = lpToken.balanceOf(USER);
        uint256 prePortLp = lpToken.balanceOf(portfolioAccount);
        console.log("pre  lpToken.balanceOf(USER):     ", preUserLp);
        console.log("pre  lpToken.balanceOf(portfolio):", prePortLp);

        // ── Unit probes: isolate the empty-returndata revert source ────────
        // These run BEFORE the multicall attempt so we can log ground truth
        // about (a) facet↔factory binding, (b) LP ERC4626 surface (leading
        // hypothesis: LP is not ERC4626 → convertToAssets reverts with empty
        // data inside _resolveCollateralValue → bubbles up as the observed
        // CallFailed(reason=0x)), (c) LP pricePerShare, (d) gauge ERC4626
        // as a positive control. All probes are informational; no reverts
        // are expected to fail the test and no assertions are made.

        // (P1) Facet → factory → PortfolioManager binding.
        console.log("--- Probe 1: facet/factory/manager binding ---");
        try YieldBasisLpFacet(depositFacetAddr)._portfolioFactory() returns (PortfolioFactory pf) {
            console.log("facet._portfolioFactory():        ", address(pf));
            console.log("resolved factoryBySalt:           ", address(portfolioFactory));
            if (address(pf) == address(portfolioFactory)) {
                console.log("[P1] facet<->factory: MATCH");
            } else {
                console.log("[P1] facet<->factory: MISMATCH");
            }
        } catch {
            console.log("[P1] facet._portfolioFactory() reverted");
        }
        try portfolioFactory.portfolioManager() returns (PortfolioManager pm) {
            console.log("portfolioFactory.portfolioManager():", address(pm));
            console.log("LIVE_PORTFOLIO_MANAGER:             ", LIVE_PORTFOLIO_MANAGER);
            if (address(pm) == LIVE_PORTFOLIO_MANAGER) {
                console.log("[P1] factory<->manager: MATCH");
            } else {
                console.log("[P1] factory<->manager: MISMATCH");
            }
        } catch {
            console.log("[P1] portfolioFactory.portfolioManager() reverted");
        }

        // (P2) LP token ERC4626 surface — expected to be broken (LP is not ERC4626).
        // Selectors:
        //   convertToAssets(uint256) = 0x07a2d13a
        //   convertToShares(uint256) = 0xc6e6f592
        //   asset()                  = 0x38d52e0f
        console.log("--- Probe 2: LP ERC4626 surface (lpToken) ---");
        uint256 userLpShares = lpToken.balanceOf(USER);
        {
            (bool ok, bytes memory data) = address(lpToken).staticcall(
                abi.encodeWithSelector(bytes4(0x07a2d13a), userLpShares) // convertToAssets(uint256)
            );
            console.log("[P2] LP.convertToAssets(userShares) ok:", ok);
            console.log("[P2]   returndata length:", data.length);
            if (ok && data.length >= 32) {
                uint256 assets = abi.decode(data, (uint256));
                console.log("[P2]   decoded assets:", assets);
            } else if (data.length > 0) {
                console.log("[P2]   non-empty revert data:");
                console.logBytes(data);
            } else {
                console.log("[P2]   empty returndata (matches observed CallFailed shape)");
            }
        }
        {
            (bool ok, bytes memory data) = address(lpToken).staticcall(
                abi.encodeWithSelector(bytes4(0xc6e6f592), uint256(1e18)) // convertToShares(uint256)
            );
            console.log("[P2] LP.convertToShares(1e18) ok:", ok);
            console.log("[P2]   returndata length:", data.length);
            if (ok && data.length >= 32) {
                uint256 shares = abi.decode(data, (uint256));
                console.log("[P2]   decoded shares:", shares);
            } else if (data.length > 0) {
                console.log("[P2]   non-empty revert data:");
                console.logBytes(data);
            } else {
                console.log("[P2]   empty returndata");
            }
        }
        {
            (bool ok, bytes memory data) = address(lpToken).staticcall(
                abi.encodeWithSelector(bytes4(0x38d52e0f)) // asset()
            );
            console.log("[P2] LP.asset() ok:", ok);
            console.log("[P2]   returndata length:", data.length);
            if (ok && data.length >= 32) {
                address assetAddr = abi.decode(data, (address));
                console.log("[P2]   decoded asset:", assetAddr);
            } else if (data.length > 0) {
                console.log("[P2]   non-empty revert data:");
                console.logBytes(data);
            } else {
                console.log("[P2]   empty returndata (expected per callout)");
            }
        }

        // (P3) LP pricePerShare() — selector 0x99530b06.
        console.log("--- Probe 3: LP pricePerShare() ---");
        {
            (bool ok, bytes memory data) = address(lpToken).staticcall(
                abi.encodeWithSelector(bytes4(0x99530b06)) // pricePerShare()
            );
            console.log("[P3] LP.pricePerShare() ok:", ok);
            console.log("[P3]   returndata length:", data.length);
            if (ok && data.length >= 32) {
                uint256 pps = abi.decode(data, (uint256));
                console.log("[P3]   decoded pricePerShare:", pps);
            } else if (data.length > 0) {
                console.log("[P3]   non-empty revert data:");
                console.logBytes(data);
            } else {
                console.log("[P3]   empty returndata");
            }
        }

        // (P4) Gauge ERC4626 surface — control; gauge SHOULD be ERC4626.
        console.log("--- Probe 4: Gauge ERC4626 surface (control) ---");
        if (address(gauge) == address(0)) {
            console.log("[P4] gauge unknown; skipping");
        } else {
            {
                (bool ok, bytes memory data) = address(gauge).staticcall(
                    abi.encodeWithSelector(bytes4(0x07a2d13a), userLpShares) // convertToAssets(uint256)
                );
                console.log("[P4] gauge.convertToAssets(userShares) ok:", ok);
                console.log("[P4]   returndata length:", data.length);
                if (ok && data.length >= 32) {
                    uint256 assets = abi.decode(data, (uint256));
                    console.log("[P4]   decoded assets:", assets);
                } else if (data.length > 0) {
                    console.log("[P4]   non-empty revert data:");
                    console.logBytes(data);
                } else {
                    console.log("[P4]   empty returndata");
                }
            }
            {
                (bool ok, bytes memory data) = address(gauge).staticcall(
                    abi.encodeWithSelector(bytes4(0x38d52e0f)) // asset()
                );
                console.log("[P4] gauge.asset() ok:", ok);
                console.log("[P4]   returndata length:", data.length);
                if (ok && data.length >= 32) {
                    address assetAddr = abi.decode(data, (address));
                    console.log("[P4]   decoded asset:", assetAddr);
                } else if (data.length > 0) {
                    console.log("[P4]   non-empty revert data:");
                    console.logBytes(data);
                } else {
                    console.log("[P4]   empty returndata");
                }
            }
        }

        // ── Path A: the real path via PortfolioManager.multicall ──────────
        console.log("--- Path A: PortfolioManager.multicall ---");
        vm.prank(USER);
        (bool okA, bytes memory dataA) = address(portfolioManager).call(
            abi.encodeWithSelector(PortfolioManager.multicall.selector, calls, factories)
        );
        console.log("multicall ok:", okA);
        if (!okA) {
            console.log("multicall returndata length:", dataA.length);
            _logSelectorPrefix(dataA);
        } else {
            console.log("[unexpected-success] multicall succeeded; returndata length:", dataA.length);
        }

        // Post-state (Path A).
        console.log(
            "post lpToken.balanceOf(USER):     ",
            lpToken.balanceOf(USER)
        );
        console.log(
            "post lpToken.balanceOf(portfolio):",
            lpToken.balanceOf(portfolioAccount)
        );

        // ICollateralFacet.getTotalLockedCollateral may itself revert if
        // wiring is broken — wrap in try/catch.
        try ICollateralFacet(portfolioAccount).getTotalLockedCollateral() returns (uint256 tlc) {
            console.log("post getTotalLockedCollateral():", tlc);
        } catch (bytes memory err) {
            console.log("[WARN] getTotalLockedCollateral() reverted; data length:", err.length);
            _logSelectorPrefix(err);
        }

        // ── Path B: direct call on portfolio (expected: onlyPortfolioManagerMulticall revert) ──
        console.log("--- Path B: direct call on portfolio (expected revert) ---");
        // Reset + re-approve in case Path A consumed allowance (it shouldn't
        // if it reverted, but be defensive).
        if (lpToken.allowance(USER, portfolioAccount) < amount) {
            vm.prank(USER);
            lpToken.approve(portfolioAccount, amount);
        }

        vm.prank(USER);
        (bool okB, bytes memory dataB) = portfolioAccount.call(
            abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount)
        );
        console.log("direct ok:", okB);
        console.log("direct returndata length:", dataB.length);
        if (!okB) {
            if (dataB.length == 0) {
                console.log("[decode] empty returndata (consistent with onlyPortfolioManagerMulticall)");
            } else {
                _logSelectorPrefix(dataB);
            }
        } else {
            console.log("[unexpected-success] direct call succeeded; that bypasses the modifier.");
        }

        console.log("=== triage complete ===");
    }
}
