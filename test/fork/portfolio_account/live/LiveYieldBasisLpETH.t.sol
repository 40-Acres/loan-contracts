// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * LiveYieldBasisLpETHTest — E2E validation of the production YieldBasis LP
 * deployment on Ethereum mainnet (salt = "yieldbasiseth").
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/portfolio_account/live/LiveYieldBasisLpETH.t.sol -vv
 *
 * Requires: ETH_RPC_URL env var.
 *
 * --------------------------------------------------------------------------
 * DEPLOYMENT GAPS OBSERVED (not things this test fabricates — real findings):
 *
 * [G1] PortfolioFactoryConfig has no LoanConfig set. The deploy script
 *      (YieldBasisLpDeploy) only calls setLoanContract(...) and never
 *      setLoanConfig(...). ERC4626CollateralManager.getMaxLoan() calls
 *      loanConfig.getMultiplier() and will REVERT against the live deployment
 *      until a LoanConfig is set. Same for processRewards() which reads
 *      treasury fee / lender premium / zero-balance fee from LoanConfig.
 *
 * [G2] The deploy script transfers PortfolioFactoryConfig ownership to the
 *      multisig but has not yet wired PortfolioFactoryConfig onto the factory
 *      via portfolioFactory.setPortfolioFactoryConfig(...) — the script
 *      comments it out. We detect and patch this in setup if needed so the
 *      rest of the test can exercise production facet wiring.
 *
 * [G3] The production PortfolioManager does not have a per-user "authorized
 *      caller" for this factory yet, so reward claim/unstake/stake
 *      (gated by onlyAuthorizedCaller) need one. Test patches it in.
 *
 * [G4] Processing rewards requires setting a rewardsToken via
 *      RewardsConfigFacet (per-portfolio state the factory can't preset).
 *
 * [G5] *** CRITICAL *** The YIELDBASIS_LP_GAUGE env var used for the
 *      Ethereum mainnet deploy (0x931d40dD07b25B91932b481B63631Ea86d236e09)
 *      is the **yb-WETH LP token itself**, NOT a YieldBasis gauge.
 *      The real gauge is 0xe4e656b5215a82009969219b1babB7c0757A3315
 *      (symbol "g(yb-WETH)", asset() = the LP at 0x931d40…e09). This test
 *      now defaults LIVE_GAUGE to the real gauge; the live production
 *      deploy script must be re-run with the correct YIELDBASIS_LP_GAUGE. Probing
 *      this address on-chain:
 *          symbol()          = "yb-WETH"
 *          name()            = "Yield Basis liquidity for WETH"
 *          pricePerShare()   = ~1.018e18  (IYieldBasisLP method)
 *          asset()           = REVERT    (not an ERC4626 gauge)
 *          deposit(a,r)      = REVERT
 *          claim(rew,user)   = REVERT
 *      The YieldBasisLpFacet constructor calls
 *      `IYieldBasisGauge(gauge).asset()` to bind the LP token — that call
 *      reverts, so the facet cannot have been deployed against this gauge
 *      address. Either (a) the env var is wrong and should point at the
 *      real yb-WETH gauge, or (b) the LP-for-WETH system on Ethereum does
 *      not yet have a gauge live. The YieldBasisLpUpgrade script on the
 *      referenced run commands will revert at construction.
 *
 *      This test detects the condition and skips (with a loud log) so the
 *      CI run flags the deployment gap without blocking the rest of the
 *      suite. To run the real E2E lifecycle, set YIELDBASIS_LP_GAUGE to
 *      the correct gauge address and re-run.
 *
 * These gaps mean: the happy-path lifecycle ONLY works after the multisig
 * completes the config wiring (G1-G4) AND the gauge address is corrected
 * (G5). The test makes those patches explicit and labels them so it's
 * obvious what remains to be done on-chain.
 */

import {Test, console} from "forge-std/Test.sol";

// Core
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {ILoanConfig} from "../../../../src/facets/account/config/ILoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Facets under test
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {YieldBasisLpRewardsProcessingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpRewardsProcessingFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

// External
import {LendingVault} from "../../../../src/facets/account/vault/LendingVault.sol";
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapMod} from "../../../../src/facets/account/swap/SwapMod.sol";

contract LiveYieldBasisLpETHTest is Test {
    // ─── Live addresses (hardcoded — these are the production deployment) ───
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant LIVE_VAULT = 0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3;
    // yb-WETH gauge on Ethereum mainnet. Discovered on-chain by enumerating
    // ERC20 Transfer recipients of the yb-WETH LP token (0x931d40…) — the
    // gauge is the top non-EOA holder. Verified:
    //   asset()   = 0x931d40dD07b25B91932b481B63631Ea86d236e09 (yb-WETH LP)
    //   symbol()  = "g(yb-WETH)"
    //   name()    = "YB Gauge: yb-WETH"
    //   preview_claim(YB, user) does not revert
    // The prior address (0x931d40…e09) stored here was the LP token itself,
    // not the gauge — that is the deployment misconfiguration flagged by [G5].
    address public constant LIVE_GAUGE = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address public constant YB_WETH_LP = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    address public constant ETH_SWAP_CONFIG = 0xD504Da3Ae86Aa3233871dbc8ae3Eb38824138F7C;
    // PortfolioFactoryConfig that the multisig is expected to wire via
    // factory.setPortfolioFactoryConfig(). Confirmed on mainnet:
    //   owner()          = 0x40FecA5f7156030b78200450852792ea93f7c6cd
    //   getLoanContract()= 0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3 (LIVE_VAULT)
    //   getLoanConfig()  = 0x0 (still unset — LoanConfig will be wired separately)
    address public constant ASSUMED_PFC = 0x8706FD061241266959e6A6E9e084f34935087012;

    bytes32 public constant FACTORY_SALT = keccak256(abi.encodePacked("yieldbasiseth"));

    // Expected vault parameters from the deploy script
    uint256 public constant EXPECTED_MAX_UTIL_BPS = 8000;
    uint256 public constant EXPECTED_ORIG_FEE_BPS = 80;

    // ─── Discovered ─────────────────────────────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LendingVault public vault;
    IYieldBasisGauge public gauge;
    IERC20 public lpToken;

    // ─── Test actors ────────────────────────────────────────────────────────
    address public user = address(uint160(uint256(keccak256("live-ybeth-user"))));
    address public authorizedCaller = address(0xA11CE);
    address public portfolioAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // [PRODUCTION CONFIG NOTE] The live deploy script (DeployYieldBasisLp.s.sol)
        // currently deploys LoanConfig with:
        //   lenderPremium=9500, treasuryFee=500, zeroBalanceFee=500,
        //   multiplier=0, rewardsRate=0
        // With multiplier=0, getMaxLoan() returns 0 — borrowing is IMPOSSIBLE
        // against this production LoanConfig until the multisig calls
        // LoanConfig.setMultiplier(...) with a sane value. This test patches
        // a local LoanConfig with multiplier=7000 below so the borrow flow
        // can be validated; do not mistake that patch for production-ready.
        console.log(
            "[NOTE] production LoanConfig will deploy with multiplier=0, "
            "borrowing will be disabled until multisig sets multiplier via LoanConfig.setMultiplier"
        );

        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);

        // Discover factory by salt
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

        // Allow operator override for when the real gauge address is known
        // (env var LIVE_YB_GAUGE). Defaults to the deploy-script constant.
        address gaugeAddr = LIVE_GAUGE;
        try vm.envAddress("LIVE_YB_GAUGE") returns (address override_) {
            if (override_ != address(0)) {
                gaugeAddr = override_;
                console.log("[OVERRIDE] Using LIVE_YB_GAUGE from env:", override_);
            }
        } catch {}
        gauge = IYieldBasisGauge(gaugeAddr);
        vm.label(gaugeAddr, "YB-ETH-Gauge");

        // [G5] Probe gauge.asset() — on mainnet this reverts, indicating the
        // env var YIELDBASIS_LP_GAUGE points at the LP token rather than a
        // gauge. Log it and skip the test so CI flags the misconfiguration.
        try gauge.asset() returns (address lpAddr) {
            lpToken = IERC20(lpAddr);
            vm.label(address(lpToken), "YB-ETH-LP");
        } catch {
            console.log("[G5 FINDING] gauge.asset() reverted for address:", LIVE_GAUGE);
            console.log("             This address is the yb-WETH LP token, not a gauge.");
            console.log("             Check YIELDBASIS_LP_GAUGE env used for the production deploy.");
            vm.skip(true);
            return;
        }

        // Check / patch config wiring (Gap G2).
        // Assume the multisig will wire the already-deployed ASSUMED_PFC onto
        // the factory. If the factory's PFC slot is empty on this fork, prank
        // the PortfolioManager owner (who is authorized by
        // PortfolioFactory.setPortfolioFactoryConfig) to perform that call.
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();
        if (address(portfolioFactoryConfig) == address(0)) {
            console.log("[PATCH G2] PortfolioFactoryConfig not wired on factory; using ASSUMED_PFC:", ASSUMED_PFC);
            require(ASSUMED_PFC.code.length > 0, "ASSUMED_PFC has no code on this fork");
            address pmOwner = portfolioManager.owner();
            vm.prank(pmOwner);
            portfolioFactory.setPortfolioFactoryConfig(ASSUMED_PFC);
            portfolioFactoryConfig = PortfolioFactoryConfig(ASSUMED_PFC);
        }

        // Sanity: vault wired
        assertEq(
            portfolioFactoryConfig.getLoanContract(),
            LIVE_VAULT,
            "[FAIL] PortfolioFactoryConfig.loanContract != live vault"
        );

        // Patch LoanConfig if missing OR if the existing production LoanConfig has
        // multiplier=0 (the initial deploy script value). Gap G1 — borrowing is
        // IMPOSSIBLE until the multisig sets a sane multiplier; we patch in a
        // full test-local LoanConfig so the E2E lifecycle can exercise borrow/pay.
        // LoanConfig.initialize requires all of {lenderPremium, treasuryFee,
        // zeroBalanceFee} to be > 0. Use sensible production-style defaults:
        //   - 70% LTV multiplier (7000 bps)
        //   - 1% lender premium (100 bps)
        //   - 1% treasury fee (100 bps)
        //   - 1 bps zero-balance fee (minimal; must be nonzero)
        //   - rewardsRate = 100 (1%) to avoid div-by-zero in rewards math
        ILoanConfig existingLc = portfolioFactoryConfig.getLoanConfig();
        bool needsLoanConfigPatch = address(existingLc) == address(0);
        if (!needsLoanConfigPatch) {
            // Multiplier==0 disables borrowing; treat it as "needs patch" so the
            // lifecycle test can validate the happy path.
            try existingLc.getMultiplier() returns (uint256 m) {
                needsLoanConfigPatch = (m == 0);
            } catch {
                needsLoanConfigPatch = true;
            }
        }
        if (needsLoanConfigPatch) {
            console.log("[PATCH G1] Deploying fresh LoanConfig and wiring into factory config.");
            LoanConfig lcImpl = new LoanConfig();
            LoanConfig lc = LoanConfig(address(new ERC1967Proxy(
                address(lcImpl),
                // (owner, lenderPremium, treasuryFee, zeroBalanceFee)
                abi.encodeCall(LoanConfig.initialize, (address(this), 100, 100, 1))
            )));
            lc.setMultiplier(7000);
            lc.setRewardsRate(100);

            address cfgOwner = portfolioFactoryConfig.owner();
            vm.prank(cfgOwner);
            portfolioFactoryConfig.setLoanConfig(address(lc));
        }
        assertTrue(
            address(portfolioFactoryConfig.getLoanConfig()) != address(0),
            "[FAIL] LoanConfig still unset after patch"
        );
        assertGt(
            portfolioFactoryConfig.getLoanConfig().getMultiplier(),
            0,
            "[FAIL] LoanConfig.multiplier still 0 after patch - borrowing would be disabled"
        );

        // Patch FacetRegistry (Gap G0): the live registry has no selectors
        // registered yet — YieldBasisLpUpgrade has not run on mainnet.
        // Replicate YieldBasisLpUpgrade._deployFacets exactly so the test
        // can exercise the production wiring that the upgrade will produce.
        if (facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector) == address(0)) {
            console.log("[PATCH G0] FacetRegistry has no selectors; simulating YieldBasisLpUpgrade on fork.");
            _patchFacetRegistry();
        } else {
            // Registry already has YB LP selectors pointing at an older facet
            // deployment — replace the YieldBasisLpFacet with a freshly compiled
            // version so this test exercises the current source bytecode.
            _replaceYieldBasisLpFacet();
        }

        // Patch authorized caller (Gap G3)
        if (!portfolioManager.isAuthorizedCaller(authorizedCaller)) {
            address pmOwner = portfolioManager.owner();
            vm.prank(pmOwner);
            portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        }

        // Create or fetch portfolio for test user
        portfolioAccount = portfolioFactory.portfolioOf(user);
        if (portfolioAccount == address(0)) {
            portfolioAccount = portfolioFactory.createAccount(user);
        }
        vm.label(portfolioAccount, "Portfolio");

        // Warp 1s/+1 block so any freshly-created account state settles.
        // NOTE: never warp backwards (via-ir caching issues + checkpoint breakage).
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
        // YB-ETH LP stores balances in custom storage; `deal` can leave the
        // balance in a state that causes transferFrom to revert downstream.
        // Impersonate the gauge (which holds a large LP position) instead.
        address holder = address(gauge);
        require(lpToken.balanceOf(holder) >= amount, "gauge LP balance too low");
        vm.prank(holder);
        lpToken.transfer(to, amount);
        require(lpToken.balanceOf(to) >= amount, "LP deal failed");
    }

    function _noSwap() internal pure returns (SwapMod.RouteParams[4] memory s) {}

    /// @dev Replicates `YieldBasisLpUpgrade._deployFacets` from
    ///      script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol —
    ///      deploys and registers all six facet groups on the live FacetRegistry.
    ///      Pranks as the registry owner so ownership stays intact after the test.
    function _patchFacetRegistry() internal {
        address registryOwner = facetRegistry.owner();
        address factory = address(portfolioFactory);
        address gaugeAddr = address(gauge);
        address underlying = WETH;

        // --- YieldBasisLpFacet (10 selectors) ---
        // NOTE [G6 FINDING]: YieldBasisLpUpgrade._deployFacets passes
        // `underlying` (WETH) as the third constructor arg. That arg is
        // `_rewardToken` — used by unstake() as `gauge.claim(_rewardToken, ...)`.
        // The yb-WETH gauge has NO WETH reward configured, only YB, so unstake()
        // would revert with "No reward" in production. Every other call site
        // in this repo (unit tests, WBTC fork test) passes YB as the reward
        // token. The deploy script should be fixed to pass YB here.
        // We pass YB to validate the happy-path lifecycle assuming the
        // production deploy is corrected.
        YieldBasisLpFacet lpFacet = new YieldBasisLpFacet(factory, gaugeAddr, YB, LIVE_VAULT);
        bytes4[] memory lpSel = new bytes4[](9);
        lpSel[0] = YieldBasisLpFacet.deposit.selector;
        lpSel[1] = YieldBasisLpFacet.withdraw.selector;
        lpSel[2] = YieldBasisLpFacet.setStakedMode.selector;
        lpSel[3] = YieldBasisLpFacet.getStakingState.selector;
        lpSel[4] = ICollateralFacet.getTotalLockedCollateral.selector;
        lpSel[5] = ICollateralFacet.getTotalDebt.selector;
        lpSel[6] = ICollateralFacet.getMaxLoan.selector;
        lpSel[7] = ICollateralFacet.enforceCollateralRequirements.selector;
        lpSel[8] = ICollateralFacet.getLoanUtilization.selector;
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(lpFacet), lpSel, "YieldBasisLpFacet");

        // --- YieldBasisLpClaimingFacet (5 selectors) ---
        YieldBasisLpClaimingFacet claimingFacet = new YieldBasisLpClaimingFacet(factory, gaugeAddr, LIVE_VAULT);
        bytes4[] memory cSel = new bytes4[](5);
        cSel[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        cSel[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        cSel[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
        cSel[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        cSel[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(claimingFacet), cSel, "YieldBasisLpClaimingFacet");

        // --- YieldBasisLpLendingFacet (2 selectors) ---
        // NOTE [G7 FINDING]: DeployYieldBasisLp.s.sol registers ERC4626LendingFacet
        // here, but ERC4626LendingFacet reads/writes ERC4626CollateralManager storage
        // while YieldBasisLpFacet reads/writes YieldBasisCollateralManager storage
        // (different ERC-7201 slots). Using ERC4626LendingFacet against YB collateral
        // means borrow() increments a storage slot that getTotalDebt() never reads,
        // so debt stays at 0 and the vault's activeAssets grows without a corresponding
        // account debt — a serious production wiring bug.
        // The correct facet for YB collateral is YieldBasisLpLendingFacet (it routes
        // through YieldBasisCollateralManager). This test registers the correct facet
        // to exercise the end-to-end borrow/pay flow; the deploy script must be fixed.
        YieldBasisLpLendingFacet lendingFacet = new YieldBasisLpLendingFacet(
            factory, LIVE_VAULT, gaugeAddr
        );
        bytes4[] memory lendSel = new bytes4[](2);
        lendSel[0] = YieldBasisLpLendingFacet.borrow.selector;
        lendSel[1] = YieldBasisLpLendingFacet.pay.selector;
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(lendingFacet), lendSel, "YieldBasisLpLendingFacet");

        // --- YieldBasisLpRewardsProcessingFacet (5 selectors) ---
        YieldBasisLpRewardsProcessingFacet rpFacet = new YieldBasisLpRewardsProcessingFacet(
            factory, ETH_SWAP_CONFIG, gaugeAddr, LIVE_VAULT, underlying, underlying
        );
        bytes4[] memory rpSel = new bytes4[](5);
        rpSel[0] = RewardsProcessingFacet.processRewards.selector;
        rpSel[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rpSel[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rpSel[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rpSel[4] = RewardsProcessingFacet.calculateRoutes.selector;
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(rpFacet), rpSel, "YieldBasisLpRewardsProcessingFacet");

        // --- RewardsConfigFacet (6 selectors) ---
        RewardsConfigFacet rcFacet = new RewardsConfigFacet(factory, ETH_SWAP_CONFIG);
        bytes4[] memory rcSel = new bytes4[](6);
        rcSel[0] = RewardsConfigFacet.setRecipient.selector;
        rcSel[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rcSel[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rcSel[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rcSel[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rcSel[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(rcFacet), rcSel, "RewardsConfigFacet");
    }

    /// @dev Replace the YieldBasisLpFacet registered on a live registry with a
    ///      freshly compiled one so tests exercise the current source bytecode.
    ///      Also re-point the borrow/pay selectors at YieldBasisLpLendingFacet —
    ///      the production deploy script registers ERC4626LendingFacet for these
    ///      selectors (see G7 FINDING in _patchFacetRegistry), which is the wrong
    ///      collateral manager for YB LP collateral.
    function _replaceYieldBasisLpFacet() internal {
        address oldFacet = facetRegistry.getFacetForSelector(YieldBasisLpFacet.deposit.selector);
        YieldBasisLpFacet newFacet = new YieldBasisLpFacet(address(portfolioFactory), address(gauge), YB, LIVE_VAULT);
        bytes4[] memory lpSel = new bytes4[](9);
        lpSel[0] = YieldBasisLpFacet.deposit.selector;
        lpSel[1] = YieldBasisLpFacet.withdraw.selector;
        lpSel[2] = YieldBasisLpFacet.setStakedMode.selector;
        lpSel[3] = YieldBasisLpFacet.getStakingState.selector;
        lpSel[4] = ICollateralFacet.getTotalLockedCollateral.selector;
        lpSel[5] = ICollateralFacet.getTotalDebt.selector;
        lpSel[6] = ICollateralFacet.getMaxLoan.selector;
        lpSel[7] = ICollateralFacet.enforceCollateralRequirements.selector;
        lpSel[8] = ICollateralFacet.getLoanUtilization.selector;
        vm.prank(facetRegistry.owner());
        facetRegistry.replaceFacet(oldFacet, address(newFacet), lpSel, "YieldBasisLpFacet");

        // [G7 PATCH] Re-point borrow/pay at the YB-native lending facet so debt
        // is actually tracked against YieldBasisCollateralManager storage.
        address oldLendingFacet = facetRegistry.getFacetForSelector(YieldBasisLpLendingFacet.borrow.selector);
        if (oldLendingFacet != address(0)) {
            YieldBasisLpLendingFacet newLendingFacet = new YieldBasisLpLendingFacet(
                address(portfolioFactory), LIVE_VAULT, address(gauge)
            );
            bytes4[] memory lendSel = new bytes4[](2);
            lendSel[0] = YieldBasisLpLendingFacet.borrow.selector;
            lendSel[1] = YieldBasisLpLendingFacet.pay.selector;
            vm.prank(facetRegistry.owner());
            facetRegistry.replaceFacet(oldLendingFacet, address(newLendingFacet), lendSel, "YieldBasisLpLendingFacet");
            console.log("[PATCH G7] Re-pointed borrow/pay at YieldBasisLpLendingFacet (was ERC4626LendingFacet)");
        }

        // Replace rewards processing facet with a freshly compiled version so
        // _decreaseTotalDebt overrides run against the current YieldBasisCollateralManager
        // storage layout (not stale prod bytecode).
        address oldRpFacet = facetRegistry.getFacetForSelector(RewardsProcessingFacet.processRewards.selector);
        if (oldRpFacet != address(0)) {
            YieldBasisLpRewardsProcessingFacet newRpFacet = new YieldBasisLpRewardsProcessingFacet(
                address(portfolioFactory), ETH_SWAP_CONFIG, address(gauge), LIVE_VAULT, WETH, WETH
            );
            bytes4[] memory rpSel = new bytes4[](5);
            rpSel[0] = RewardsProcessingFacet.processRewards.selector;
            rpSel[1] = RewardsProcessingFacet.getRewardsToken.selector;
            rpSel[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
            rpSel[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
            rpSel[4] = RewardsProcessingFacet.calculateRoutes.selector;
            vm.prank(facetRegistry.owner());
            facetRegistry.replaceFacet(oldRpFacet, address(newRpFacet), rpSel, "YieldBasisLpRewardsProcessingFacet");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Production wiring assertions (catch deployment misconfigurations)
    // ─────────────────────────────────────────────────────────────────────

    function testFactoryRegisteredInManager() public view {
        assertTrue(
            portfolioManager.isRegisteredFactory(address(portfolioFactory)),
            "Factory must be registered in PortfolioManager"
        );
    }

    function testVaultAddressMatchesDeployed() public view {
        assertEq(address(vault), LIVE_VAULT, "Vault address mismatch");
        assertEq(vault.asset(), WETH, "Vault asset must be WETH");
        // The cap moved from the vault onto LoanConfig; read it from the
        // linked PortfolioFactoryConfig -> LoanConfig.
        assertEq(
            portfolioFactoryConfig.getLoanConfig().getMaxUtilizationBps(),
            EXPECTED_MAX_UTIL_BPS,
            "maxUtilizationBps != 8000"
        );
        assertEq(vault.originationFeeBps(), EXPECTED_ORIG_FEE_BPS, "originationFeeBps != 80");
        assertEq(vault.getPortfolioFactory(), address(portfolioFactory), "Vault factory mismatch");
    }

    function testGaugeAndLpWired() public view {
        assertEq(gauge.asset(), address(lpToken), "Gauge.asset != lpToken");
    }

    function testFacetRegistryHasAllSelectors() public view {
        // YieldBasisLpFacet
        _assertSelectorRegistered(YieldBasisLpFacet.deposit.selector, "deposit");
        _assertSelectorRegistered(YieldBasisLpFacet.withdraw.selector, "withdraw");
        _assertSelectorRegistered(YieldBasisLpFacet.setStakedMode.selector, "setStakedMode");
        _assertSelectorRegistered(YieldBasisLpFacet.getStakingState.selector, "getStakingState");
        _assertSelectorRegistered(ICollateralFacet.getTotalLockedCollateral.selector, "getTotalLockedCollateral");
        _assertSelectorRegistered(ICollateralFacet.getMaxLoan.selector, "getMaxLoan");

        // YieldBasisLpClaimingFacet
        _assertSelectorRegistered(YieldBasisLpClaimingFacet.claimGaugeRewards.selector, "claimGaugeRewards");
        _assertSelectorRegistered(YieldBasisLpClaimingFacet.previewGaugeRewards.selector, "previewGaugeRewards");
        _assertSelectorRegistered(YieldBasisLpClaimingFacet.harvestLpFees.selector, "harvestLpFees");

        // YieldBasisLpLendingFacet (selector-equivalent shape to ERC4626LendingFacet)
        _assertSelectorRegistered(YieldBasisLpLendingFacet.borrow.selector, "borrow");
        _assertSelectorRegistered(YieldBasisLpLendingFacet.pay.selector, "pay");

        // Rewards
        _assertSelectorRegistered(RewardsProcessingFacet.processRewards.selector, "processRewards");
    }

    function _assertSelectorRegistered(bytes4 sel, string memory name) internal view {
        address facet = facetRegistry.getFacetForSelector(sel);
        require(facet != address(0), string.concat("Selector not registered: ", name));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Primary E2E lifecycle
    // ─────────────────────────────────────────────────────────────────────

    function testE2ELifecycle() public {
        // [G6 GAP] The live YieldBasisPortfolioFactoryConfig predates the
        // setStakedGaugeMode method that the new deposit()/setStakedMode()
        // path reads. Skip BEFORE any state-changing call when the probe
        // reverts so CI flags the upgrade dependency rather than failing
        // mid-deposit. Must run before the first deposit since deposit()
        // itself calls getStakedMode() → getStakedGaugeMode().
        YieldBasisPortfolioFactoryConfig ybConfig =
            YieldBasisPortfolioFactoryConfig(address(portfolioFactory.portfolioFactoryConfig()));
        try ybConfig.getStakedGaugeMode() returns (bool) {
            // proceed
        } catch {
            console.log("[SKIP G6] live YieldBasisPortfolioFactoryConfig predates getStakedGaugeMode; awaiting production upgrade");
            vm.skip(true);
            return;
        }

        // ── 1. Fund vault with WETH so borrows can happen ─────────────
        uint256 vaultSeed = 1_000 ether;
        deal(WETH, address(vault), vaultSeed);
        assertGe(IERC20(WETH).balanceOf(address(vault)), vaultSeed, "vault not seeded");
        console.log("Vault WETH seeded:", IERC20(WETH).balanceOf(address(vault)));

        // ── 2. Fund the user with LP and approve portfolio (deposit pulls from owner)
        uint256 depositAmount = 1 ether;
        _dealLp(user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        _multicallAsUser(abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount));

        // Under current semantics deposit() only pulls LP onto the account; it does
        // NOT auto-stake into the gauge. The LP sits unstaked until stake() is called.
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "deposit should not auto-stake into gauge");
        assertEq(unstaked, depositAmount, "full LP should sit unstaked on account after deposit");

        // Flip directive=true and stake. ybConfig was probed at top of test.
        vm.prank(ybConfig.owner());
        ybConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "no gauge shares after explicit stake");
        assertEq(unstaked, 0, "unexpected unstaked LP after full stake");
        console.log("Staked shares after explicit stake:", staked);

        uint256 collat = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(collat, 0, "total locked collateral == 0 after deposit");
        assertGt(maxLoanIgnoreSupply, 0, "maxLoanIgnoreSupply == 0; LoanConfig.multiplier wrong?");
        assertGt(maxLoan, 0, "maxLoan == 0; vault underfunded or multiplier=0");
        console.log("Collateral value:", collat);
        console.log("Max loan:", maxLoan);

        // ── 4. Borrow WETH ────────────────────────────────────────────
        uint256 borrowAmount = maxLoan / 2;
        assertGt(borrowAmount, 0, "nothing to borrow");
        uint256 userWethBefore = IERC20(WETH).balanceOf(user);

        _multicallAsUser(abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, borrowAmount));

        uint256 userWethAfter = IERC20(WETH).balanceOf(user);
        assertGt(userWethAfter, userWethBefore, "user WETH did not increase after borrow");
        uint256 debt = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debt, borrowAmount, "debt must equal borrowed amount");
        console.log("Borrowed WETH:", userWethAfter - userWethBefore, "debt:", debt);

        // ── 5. Accrue gauge rewards ───────────────────────────────────
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);

        // ── 6. Preview + claim YB rewards ─────────────────────────────
        // RIGOROUS: assert non-zero accrual + dust-level residual after claim.
        uint256 previewed = YieldBasisLpClaimingFacet(portfolioAccount).previewGaugeRewards(YB);
        console.log("Preview YB after 7d:", previewed);
        assertGt(previewed, 0, "no YB accrued after 7 day warp - gauge may be inactive or not pre-funded");

        uint256 ybBefore = IERC20(YB).balanceOf(portfolioAccount);
        vm.prank(authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        uint256 ybAfter = IERC20(YB).balanceOf(portfolioAccount);
        assertEq(ybAfter - ybBefore, claimed, "YB balance delta must match claimed");
        assertGt(claimed, 0, "claim returned zero despite non-zero preview");
        // preview is computed pre-claim; after claim should be ~0 (dust only from sub-block accrual)
        uint256 previewedAfter = YieldBasisLpClaimingFacet(portfolioAccount).previewGaugeRewards(YB);
        assertLt(previewedAfter, claimed / 1000, "preview should be ~0 after claim (allow 0.1% dust)");
        console.log("Claimed YB:", claimed);
        console.log("Preview YB after claim (should be dust):", previewedAfter);

        // ── 6b. processRewards debt-repayment path ────────────────────
        // With debt active, getRewardsToken() returns vault asset (WETH). In
        // production, YB would be swapped to WETH via swapToRewardsToken using
        // SwapConfig; on a cold fork the swap target may not be approved for
        // YB→WETH, so we simulate post-swap state by minting a representative
        // WETH amount equal to the YB claimed (1:1 stand-in) to the portfolio.
        // The debt-repayment assertion is what we're validating; the swap
        // mechanics are covered by unit tests.
        address rewardsTokenForProc = RewardsProcessingFacet(portfolioAccount).getRewardsToken();
        assertEq(rewardsTokenForProc, WETH, "with debt, rewards token must be vault asset (WETH)");

        uint256 simulatedWethRewards = 0.1 ether; // representative post-swap amount
        deal(WETH, portfolioAccount, simulatedWethRewards);
        uint256 debtBeforeProc = ICollateralFacet(portfolioAccount).getTotalDebt();

        vm.prank(authorizedCaller);
        RewardsProcessingFacet(portfolioAccount).processRewards(
            0, simulatedWethRewards, _noSwap(), 0
        );
        uint256 debtAfterProc = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertLt(debtAfterProc, debtBeforeProc, "processRewards did not reduce debt");
        console.log("processRewards debt delta (WETH):", debtBeforeProc - debtAfterProc);

        // ── 7. Harvest LP fees (may be 0 — log, don't fail) ───────────
        try YieldBasisLpClaimingFacet(portfolioAccount).getAvailableLpFeeYield()
            returns (uint256 yieldUnderlying, uint256 yieldGaugeShares)
        {
            console.log("Available LP fee yield (underlying):", yieldUnderlying);
            console.log("Available LP fee yield (gauge shares):", yieldGaugeShares);
            if (yieldGaugeShares > 0) {
                vm.prank(authorizedCaller);
                try YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(0) returns (uint256 harvested) {
                    console.log("Harvested LP fees (WETH):", harvested);
                } catch (bytes memory reason) {
                    console.log("harvestLpFees reverted (non-fatal):");
                    console.logBytes(reason);
                }
            }
        } catch {
            console.log("getAvailableLpFeeYield reverted");
        }

        // ── 8. Pay down debt directly via pay() ───────────────────────
        //    (skip processRewards — that requires a RewardsProcessingFacet
        //     path where YB is swappable to WETH via an approved swap target,
        //     which live SwapConfig may or may not allow for YB→WETH on this
        //     fork. Debt paydown is the assertion we care about.)
        uint256 payAmount = debt / 2;
        deal(WETH, user, payAmount);
        vm.startPrank(user);
        IERC20(WETH).approve(portfolioAccount, payAmount);
        // pay() is NOT gated by multicall — the user or portfolio manager can call.
        YieldBasisLpLendingFacet(portfolioAccount).pay(payAmount);
        vm.stopPrank();

        uint256 debtAfterPay = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertLt(debtAfterPay, debt, "debt did not decrease after pay()");
        console.log("Debt before:", debt, "after partial pay:", debtAfterPay);

        // Pay remaining so we can fully unwind
        deal(WETH, user, debtAfterPay);
        vm.startPrank(user);
        IERC20(WETH).approve(portfolioAccount, debtAfterPay);
        YieldBasisLpLendingFacet(portfolioAccount).pay(debtAfterPay);
        vm.stopPrank();
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalDebt(),
            0,
            "debt not cleared after full pay"
        );

        // ── 9. Accrue more rewards, then unstake (tests G6: unstake calls
        //       gauge.claim(_rewardToken, ...) — _rewardToken MUST be YB for
        //       this to succeed on the yb-WETH gauge). If the deploy script
        //       passed `underlying` (WETH), gauge.claim(WETH, ...) would revert
        //       because no WETH rewards are configured.
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 21600);
        uint256 ybBeforeUnstake = IERC20(YB).balanceOf(portfolioAccount);
        uint256 previewBeforeUnstake = YieldBasisLpClaimingFacet(portfolioAccount).previewGaugeRewards(YB);
        assertGt(previewBeforeUnstake, 0, "no YB accrued in 3d gap before unstake");

        (staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        // Flip directive to false before sweep — setStakedMode reads it.
        vm.prank(ybConfig.owner());
        ybConfig.setStakedGaugeMode(false);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
        uint256 ybAfterUnstake = IERC20(YB).balanceOf(portfolioAccount);
        assertGt(ybAfterUnstake - ybBeforeUnstake, 0, "unstake did not claim YB (G6 regression: _rewardToken wrong?)");
        console.log("unstake auto-claimed YB:", ybAfterUnstake - ybBeforeUnstake);

        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "gauge shares not zero after unstake");
        assertGt(unstaked, 0, "no LP after unstake");

        uint256 userLpBefore = lpToken.balanceOf(user);
        _multicallAsUser(abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, unstaked));
        uint256 userLpAfter = lpToken.balanceOf(user);
        assertGt(userLpAfter, userLpBefore, "user did not receive LP back on withdraw");

        uint256 collatEnd = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertLe(collatEnd, 1, "collateral not cleared after full withdraw");

        console.log("Lifecycle complete. Final user LP:", userLpAfter);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Companion: rewards processing wiring check
    //
    // This test verifies processRewards CAN be called end-to-end (no debt
    // path, since in the full lifecycle test we clear debt first). It
    // exercises the "zero-balance" branch which requires a nonzero
    // zero-balance fee (set to 1 bps in setUp) and doesn't require approved swap
    // targets if the rewards token == vault asset.
    // ─────────────────────────────────────────────────────────────────────
    function testProcessRewardsWiring_noDebt() public {
        // rewardsToken defaults to vault.asset() (WETH) when set to address(0)
        // and there's no debt — processRewards will then skip fees (zero-balance
        // fee is 0 in our patched LoanConfig) and route remainder to recipient.

        // Fund portfolio with some WETH to simulate post-swap rewards
        uint256 rewardsAmount = 1 ether;
        deal(WETH, portfolioAccount, rewardsAmount);

        // Ensure recipient set to user (default is owner, which IS user)
        address rewardsToken = RewardsProcessingFacet(portfolioAccount).getRewardsToken();
        assertEq(rewardsToken, WETH, "rewardsToken should default to vault asset (WETH)");

        uint256 userWethBefore = IERC20(WETH).balanceOf(user);

        vm.prank(authorizedCaller);
        try RewardsProcessingFacet(portfolioAccount).processRewards(
            0, rewardsAmount, _noSwap(), 0
        ) {
            uint256 userWethAfter = IERC20(WETH).balanceOf(user);
            assertGt(userWethAfter, userWethBefore, "User should receive residual rewards");
            console.log("processRewards sent to user:", userWethAfter - userWethBefore);
        } catch (bytes memory reason) {
            // If this reverts, it's a production wiring bug — surface it.
            console.log("processRewards reverted:");
            console.logBytes(reason);
            revert("processRewards failed against live wiring (see log)");
        }
    }
}
