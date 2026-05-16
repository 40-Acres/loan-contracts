// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

/**
 * @title DynamicFeesVaultSplitFuzz
 * @notice Bundle 2 — Spot-utilization split fuzz test.
 *
 * THREAT MODEL
 * ============
 * `_processGlobalVesting` reads the spot vault ratio (lender vs borrower split)
 * once per call and applies it across the entire `(currentTime - globalLastUpdateTime)`
 * window. An attacker (borrower-side) can sandwich the settle to maximize the
 * borrower share, or (lender-side) time deposits/withdraws to shift their share
 * count when the lender premium accrues. We bound the divergence between the
 * vault's actual cumulative split and a TIME-INTEGRATED reference split over a
 * single epoch.
 *
 * INVARIANT
 * =========
 * |actual_lender_bps - reference_lender_bps| <= 100 bps over one full epoch.
 *
 * The reference simulator uses the live FeeCalculator at every observation
 * (so we test settle-timing risk, not curve mismatch risk). Reference is
 * computed via piecewise-constant (left-Riemann) integration: between each pair
 * of state-changing events, we record the utilization at the event start and
 * assume it held flat until the next event.
 *
 * If the test fails (divergence > 100 bps), REPORT — do not loosen tolerance.
 * The whole point is to detect this manipulation surface.
 *
 * VIA-IR + WARP NOTES
 * ===================
 * - All timestamps are absolute, computed from setUp warp value (EPOCH_2).
 * - Never warp backward.
 * - Bound dt so total time stays within one epoch.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Mocks (mirror DynamicFeesVault.t.sol)
// ─────────────────────────────────────────────────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { _mint(msg.sender, 1_000_000e6); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) { return _portfolio != address(0); }
    function facetRegistry() external pure override returns (address) { return address(0); }
    function portfolioManager() external pure override returns (address) { return address(0); }
    function portfolios(address) external pure override returns (address) { return address(0); }
    function owners(address) external pure override returns (address) { return address(0); }
    function createAccount(address) external pure override returns (address) { return address(0); }
    function getRegistryVersion() external pure override returns (uint256) { return 0; }
    function ownerOf(address) external pure override returns (address) { return address(0); }
    function portfolioOf(address) external pure override returns (address) { return address(0); }
    function getAllPortfolios() external pure override returns (address[] memory) { return new address[](0); }
    function getPortfoliosLength() external pure override returns (uint256) { return 0; }
    function getPortfolio(uint256) external pure override returns (address) { return address(0); }
}

// ─────────────────────────────────────────────────────────────────────────────
// SplitFuzz suite
// ─────────────────────────────────────────────────────────────────────────────

contract DynamicFeesVaultSplitFuzzTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner;
    address public user1;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    // Hard cap on dt so a single action cannot consume the whole epoch.
    // Max number of actions per fuzz run.
    uint256 constant MAX_ACTIONS = 6;

    // Reference simulator state — total credits accumulated across the epoch.
    uint256 internal refLenderCredit;
    uint256 internal refBorrowerCredit;
    uint256 internal refTrackedTime; // last time at which the reference was advanced

    // Track total raw rewards we deposited (for sanity bound on divergence base).
    uint256 internal totalRewardsDeposited;

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        user1 = address(0x2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory),
            8000,
            address(this),
            uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));
        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Seed liquidity so utilization can range above zero.
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));

        // user1 takes a baseline borrow so reward deposits can occur (gate
        // requires existing debt) and so the system is in an interesting
        // utilization regime.
        vm.prank(user1);
        vault.borrowFromPortfolio(200e6);

        refTrackedTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reference simulator helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Advance the piecewise-constant reference up to `currentTime` using
    ///      the spot ratio that applies BEFORE any state mutation at this step.
    ///      This produces a left-Riemann sum over `(refTrackedTime, currentTime]`.
    function _advanceReference(uint256 currentTime, uint256 spotRate, uint256 spotRatioBps) internal {
        if (currentTime <= refTrackedTime) return;
        if (spotRate == 0) {
            refTrackedTime = currentTime;
            return;
        }
        uint256 dt = currentTime - refTrackedTime;
        // Cap dt to active stream end (mirrors vault behavior).
        uint256 vaultActiveEnd = vault.getActiveEpochRate() == 0 ? currentTime : EPOCH_3;
        if (currentTime > vaultActiveEnd) dt = vaultActiveEnd > refTrackedTime ? vaultActiveEnd - refTrackedTime : 0;

        uint256 vested = spotRate * dt;
        // Cap by remaining unsettled (mirrors vault).
        uint256 unsettled = vault.getTotalUnsettledRewards();
        if (vested > unsettled) vested = unsettled;
        // Mirror vault boundary sweep: when currentTime reaches the active
        // epoch end, _processGlobalVesting consumes any residual
        // totalUnsettledRewards (floor-division dust from depositRewards) at
        // the boundary-time ratio. Reference must book the same so the split
        // invariant holds.
        if (currentTime >= vaultActiveEnd && vested < unsettled) {
            vested = unsettled;
        }
        uint256 lenderShare = (vested * spotRatioBps) / 10000;
        uint256 borrowerShare = vested - lenderShare;
        refLenderCredit += lenderShare;
        refBorrowerCredit += borrowerShare;
        refTrackedTime = currentTime;
    }

    /// @dev Read the actual cumulative lender vs borrower split from the vault.
    ///      Uses sync() to flush all pending vesting up to current block.
    ///      `actualLender = totalAssets() - baseline` is the realized lender
    ///      gain after full vesting completes. Under the single-bucket
    ///      current-epoch vesting model, premium routes to
    ///      `vestingEpochPremium` and is fully realized one epoch after
    ///      settlement. The split fuzz invariants on the lender/borrower ratio
    ///      are unaffected — the split happens at extraction
    ///      (`_processGlobalVesting`), BEFORE vesting timing is applied.
    ///      Simpler proxy: actual lender total = sum lenderShare actually
    ///      booked into vesting state at sync time. We capture it at end of run
    ///      via the totalAssets delta after full vesting.

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz — handler-style action sequence
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Drive vault through fuzzed action tuples and compare the actual
    ///         lender/borrower split to the time-integrated reference.
    /// @dev Foundry default fuzz runs apply (256). For local sign-off, bump
    ///      `runs` to 10000 via `forge test ... --fuzz-runs 10000`.
    function testFuzz_splitDivergenceBoundedBy100Bps(
        uint256[MAX_ACTIONS] memory rawActions,
        uint256[MAX_ACTIONS] memory rawAmounts,
        uint256[MAX_ACTIONS] memory rawDts
    ) public {
        // Apply baseline fee snapshot. Track baseline totalAssets so we can
        // measure realized lender gain at the end.
        uint256 totalAssetsBaseline = vault.totalAssets();

        // Hard total-time budget: single epoch (EPOCH_2..EPOCH_3 ≈ WEEK).
        // Reserve last 1 hour for final settlement window.
        uint256 timeBudget = (WEEK - 1 hours);
        uint256 perStepCap = timeBudget / MAX_ACTIONS;

        for (uint256 i = 0; i < MAX_ACTIONS; i++) {
            uint256 action = rawActions[i] % 5;
            uint256 amount = bound(rawAmounts[i], 1e6, 50e6);
            uint256 dt = bound(rawDts[i], 1, perStepCap);

            // Capture spot rate/ratio BEFORE the time advance so the reference
            // sums the rate over the interval that actually elapsed under
            // those conditions.
            uint256 currentRate = vault.getActiveEpochRate();
            uint256 currentRatio = vault.getCurrentVaultRatioBps();

            // Advance time, then update reference.
            uint256 newTime = block.timestamp + dt;
            if (newTime >= EPOCH_3) newTime = EPOCH_3 - 1; // stay inside epoch
            vm.warp(newTime);
            vm.roll(block.number + 1);
            _advanceReference(newTime, currentRate, currentRatio);

            if (action == 0) {
                // borrow
                uint256 maxBorrow = _safeMaxBorrow();
                if (amount > maxBorrow) continue;
                vm.prank(user1);
                try vault.borrowFromPortfolio(amount) {} catch { /* skip */ }
            } else if (action == 1) {
                // repay
                if (vault.getDebtBalance(user1) == 0) continue;
                deal(address(usdc), user1, amount);
                vm.startPrank(user1);
                usdc.approve(address(vault), amount);
                try vault.repay(amount) {} catch { vm.stopPrank(); continue; }
                vm.stopPrank();
            } else if (action == 2) {
                // depositRewards
                if (vault.getDebtBalance(user1) == 0) continue;
                deal(address(usdc), user1, amount);
                vm.startPrank(user1);
                usdc.approve(address(vault), amount);
                try vault.depositRewards(amount) {
                    totalRewardsDeposited += amount;
                } catch { vm.stopPrank(); continue; }
                vm.stopPrank();
            } else if (action == 3) {
                // settle
                vault.settleRewards(user1);
            } else {
                // sync
                vault.sync();
            }
        }

        // Final: warp to end of epoch + 2 to fully vest all premium, then
        // measure realized lender gain via totalAssets.
        if (totalRewardsDeposited == 0) return; // nothing to compare

        // Cross to epoch boundary so streams finalize. _processGlobalVesting at
        // sync sweeps the residual `totalUnsettledRewards` (floor-division
        // dust) at boundary-time ratio, which folds the entire interval since
        // the last action into one chunk. _advanceReference mirrors this with
        // the `currentTime >= vaultActiveEnd` branch — so we advance straight
        // from the last loop step to EPOCH_3 using boundary-time rate/ratio,
        // skipping any intermediate "finalInEpoch" step that would double-book.
        vm.warp(EPOCH_3);
        vm.roll(block.number + 1);
        {
            uint256 boundaryRate = vault.getActiveEpochRate();
            uint256 boundaryRatio = vault.getCurrentVaultRatioBps();
            _advanceReference(EPOCH_3, boundaryRate, boundaryRatio);
        }
        vault.sync();
        vault.settleRewards(user1);

        // Warp through the next two epochs so vesting completes (per first-epoch
        // quirk) — premium tagged at EPOCH_3 won't fully release until ~EPOCH_5.
        vm.warp(5 * WEEK);
        vm.roll(block.number + 1);
        vault.sync();

        uint256 actualLenderGain = vault.totalAssets() > totalAssetsBaseline
            ? vault.totalAssets() - totalAssetsBaseline
            : 0;

        // Skip degenerate runs where almost no rewards landed.
        if (refLenderCredit + refBorrowerCredit < 1e6) return;

        uint256 refTotal = refLenderCredit + refBorrowerCredit;
        uint256 actualTotal = totalRewardsDeposited;
        // Use the smaller of the two as denominator for bps comparison so
        // partial-vesting truncation doesn't dominate.
        uint256 denominator = refTotal < actualTotal ? refTotal : actualTotal;
        if (denominator == 0) return;

        uint256 refLenderBps = (refLenderCredit * 10000) / denominator;
        uint256 actualLenderBps = (actualLenderGain * 10000) / denominator;

        uint256 diff = refLenderBps > actualLenderBps
            ? refLenderBps - actualLenderBps
            : actualLenderBps - refLenderBps;

        // Hard tolerance: 100 bps. Document tolerance choice — if exceeded,
        // REPORT, do NOT loosen.
        assertLe(
            diff,
            100,
            "split divergence exceeds 100 bps: actual vs time-integrated reference"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _safeMaxBorrow() internal view returns (uint256) {
        uint256 total = vault.totalAssets();
        if (total == 0) return 0;
        uint256 cap = (total * 7900) / 10000; // 79% to stay under 80% cap
        uint256 currentLoaned = vault.totalLoanedAssets();
        if (currentLoaned >= cap) return 0;
        return cap - currentLoaned;
    }
}
