// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Stale-NAV preview bug — failing tests (test-first per CLAUDE.md)
// ============================================================================
//
// Bug (DynamicFeesVault.sol totalAssets at lines 425-443):
// `totalAssets()` deducts the FULL `totalUnsettledRewards` but does NOT
// simulate the slice of `totalUnsettledRewards` that would flow into lender
// premium / borrower credit if `_processGlobalVesting()` ran at
// `block.timestamp`.
//
// Concretely, when:
//   - an active stream exists (activeEpochRate > 0)
//   - block.timestamp > globalLastUpdateTime
//   - block.timestamp < activeEpochEnd
//   - the lender ratio > 0 (so there's a premium portion)
//
// Then a state-changing call would extract `globalVested * ratio / 10000`
// of lender premium and immediately partially vest it into NAV via
// `vestingEpochPremium`. The four preview/max functions don't simulate
// this. So `previewDeposit(X)` quotes shares against the stale low NAV,
// but `deposit(X)` runs `_processGlobalVesting` first, raising NAV, then
// mints against the higher NAV — producing fewer shares than quoted.
//
// Math (canonical):
//   - At time t mid-epoch where t > globalLastUpdateTime and t <
//     activeEpochEnd, the vested-this-tick amount = activeEpochRate *
//     (t - globalLastUpdateTime).
//   - lenderPremium = vested * ratioBps / 10000.
//   - That lenderPremium routes to `vestingEpochPremium` with vestStart
//     = epochStart(t) (or stays at existing vestStart if same epoch). At
//     time t, elapsed_in_vest_epoch = t - vestStart, so the share already
//     vested into NAV = lenderPremium * elapsed / WEEK. THAT is the
//     stale-NAV delta `Δ` between pre- and post-sync `totalAssets()`.
//
// Once `totalAssets()` is patched to simulate `_processGlobalVesting`,
// all four previews will quote against the post-sync NAV and these tests
// will pass exactly.
//
// Scenario design knobs:
//   - setUp warps to EPOCH_2.
//   - Borrow 3000e6 at EPOCH_2 (30% util on 10_000e6 seed).
//   - Pin flat lender ratio at 2000 bps (20% lender / 80% borrower).
//   - depositRewards(100e6) at EPOCH_2 → stream EPOCH_2 → EPOCH_3 at
//     rate 100e6 / WEEK.
//   - Warp to EPOCH_2 + WEEK/2 (HARDCODED absolute timestamp per
//     via-ir caching guidance).
//   - At this point: globalVested = 50e6, lenderPremium = 10e6,
//     elapsed_in_vest_epoch = WEEK/2 → Δ = 10e6 * 0.5 = 5e6.
// ============================================================================

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

// ============ Mocks ============

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryStale is IPortfolioFactory {
    mapping(address => bool) public _isPortfolio;
    function setPortfolio(address a, bool v) external { _isPortfolio[a] = v; }
    function isPortfolio(address p) external view override returns (bool) { return _isPortfolio[p]; }
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

contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// ============================================================================
// Test contract
// ============================================================================

contract DynamicFeesVaultStaleNavPreviewTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryStale public portfolioFactory;

    address public owner;
    address public borrower;
    address public feeRecipient;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;

    // Hardcoded absolute timestamps (via-ir caches block.timestamp).
    uint256 constant EPOCH_2 = 2 * WEEK;            // setUp time
    uint256 constant EPOCH_2_HALF = 2 * WEEK + WEEK / 2;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_3_QUARTER = 3 * WEEK + WEEK / 4;
    uint256 constant EPOCH_4 = 4 * WEEK;

    uint256 constant SEED = 10_000e6;
    uint256 constant BORROW = 3_000e6;             // 30% util
    uint256 constant REWARDS = 100e6;
    uint256 constant LENDER_RATIO_BPS = 2000;      // 20% lender / 80% borrower

    // Disable perf fee to keep math clean.
    uint256 constant DEFAULT_FEE_BPS = 0;

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        borrower = address(0x20);
        feeRecipient = address(0xFEE);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryStale();
        portfolioFactory.setPortfolio(borrower, true);

        vault = _deployVault();

        // Pin flat lender ratio so we can hand-compute expected splits.
        FlatFeeCalculator fc = new FlatFeeCalculator(LENDER_RATIO_BPS);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));

        // Seed the vault (test contract is initial LP).
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, address(this));
    }

    // ============ Helpers ============

    function _deployVault() internal returns (DynamicFeesVault v) {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC",
            address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
    }

    /// @dev Pre-stage state that exposes the bug:
    ///      - Borrow 30% util at EPOCH_2.
    ///      - depositRewards(100e6) at EPOCH_2 (stream EPOCH_2 → EPOCH_3).
    ///      - Warp to EPOCH_2_HALF mid-epoch. No state-changing call.
    ///      - Roll one block to release the same-block-as-deposit guard
    ///        from setUp.
    function _midEpochUnsettledState() internal {
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        vm.startPrank(borrower);
        usdc.mint(borrower, REWARDS);
        usdc.approve(address(vault), REWARDS);
        vault.depositRewards(REWARDS);
        vm.stopPrank();

        // Mid-epoch. NO sync. Now `totalAssets()` is stale-low because
        // `totalUnsettledRewards = 100e6` is fully deducted, while the
        // share of lenderPremium that would have already vested
        // (≈ 5e6 at WEEK/2 elapsed at 20% ratio) is not credited back.
        vm.warp(EPOCH_2_HALF);

        // Release the same-block guard from setUp's seed-deposit.
        vm.roll(block.number + 1);
    }

    /// @dev Returns absolute Δ between current totalAssets() and totalAssets()
    ///      after sync() is forced. Captures the stale-NAV gap that the
    ///      preview functions miss.
    function _measureStaleNavGap() internal returns (uint256) {
        uint256 taBefore = vault.totalAssets();
        vault.sync();
        uint256 taAfter = vault.totalAssets();
        return taAfter > taBefore ? taAfter - taBefore : taBefore - taAfter;
    }

    // ========================================================================
    // Group A — Preview stability across sync
    //
    // The OZ ERC4626 base implementation defines:
    //
    //   function deposit(uint256 assets, address receiver) {
    //       uint256 shares = previewDeposit(assets);    // <- computed BEFORE _deposit
    //       _deposit(_msgSender(), receiver, assets, shares);
    //       return shares;
    //   }
    //
    // So `deposit()` return value == `previewDeposit(assets)` tautologically,
    // regardless of NAV staleness. Same for mint/withdraw/redeem.
    //
    // The actual stale-NAV bug surface: a quote taken BEFORE the next
    // `_processGlobalVesting` differs from a quote taken AFTER. On the
    // broken code, `previewDeposit(X)` returns more shares than it would
    // immediately after `sync()`. On the fixed code, both quotes match
    // because `totalAssets()` already includes the simulation.
    //
    // We use `vm.snapshotState` / `vm.revertToState` to compare the same
    // input against two timelines without leaking sync-side effects into
    // the no-sync timeline.
    // ========================================================================

    function test_previewDeposit_matchesActualDeposit_withUnsettledVesting() public {
        _midEpochUnsettledState();

        uint256 amountIn = 1_000e6;

        // Quote against current (stale) NAV.
        uint256 quotedStale = vault.previewDeposit(amountIn);

        // Snapshot, force sync, re-quote, revert.
        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 quotedSynced = vault.previewDeposit(amountIn);
        vm.revertToState(snapId);

        // Post-fix invariant: previewDeposit must already reflect what
        // sync() would do. Tolerance 1 wei for share-math rounding.
        assertApproxEqAbs(
            quotedStale,
            quotedSynced,
            1,
            "previewDeposit before sync must match previewDeposit after sync (NAV must be simulated)"
        );
    }

    function test_previewMint_matchesActualMint_withUnsettledVesting() public {
        _midEpochUnsettledState();

        // Use enough shares to exceed the 1-wei rounding tolerance of
        // the share-math. The 6-decimals virtual-shares offset means
        // shares scale ~ 1e10 of assets; small share counts produce
        // sub-wei assets and trip the tolerance. Use ~half the seed in
        // share units so the delta is on the order of 0.05% of seed.
        uint256 sharesWanted = 5_000e6 * (10 ** 6); // 5e15 shares

        uint256 quotedStale = vault.previewMint(sharesWanted);

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 quotedSynced = vault.previewMint(sharesWanted);
        vm.revertToState(snapId);

        assertApproxEqAbs(
            quotedStale,
            quotedSynced,
            1,
            "previewMint before sync must match previewMint after sync (NAV must be simulated)"
        );
    }

    function test_previewWithdraw_matchesActualWithdraw_withUnsettledVesting() public {
        _midEpochUnsettledState();

        uint256 amount = 500e6;

        uint256 quotedStale = vault.previewWithdraw(amount);

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 quotedSynced = vault.previewWithdraw(amount);
        vm.revertToState(snapId);

        assertApproxEqAbs(
            quotedStale,
            quotedSynced,
            1,
            "previewWithdraw before sync must match previewWithdraw after sync (NAV must be simulated)"
        );
    }

    function test_previewRedeem_matchesActualRedeem_withUnsettledVesting() public {
        _midEpochUnsettledState();

        // Same tolerance rationale as previewMint — small share counts
        // produce sub-wei assets under the 6-decimals virtual-shares
        // offset and trip the 1-wei tolerance erroneously. Use ~half the
        // seed so the stale-vs-synced delta is well above rounding.
        uint256 sharesToRedeem = 5_000e6 * (10 ** 6); // 5e15 shares

        uint256 quotedStale = vault.previewRedeem(sharesToRedeem);

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 quotedSynced = vault.previewRedeem(sharesToRedeem);
        vm.revertToState(snapId);

        assertApproxEqAbs(
            quotedStale,
            quotedSynced,
            1,
            "previewRedeem before sync must match previewRedeem after sync (NAV must be simulated)"
        );
    }

    // Bonus: maxWithdraw / maxRedeem must also reflect simulated NAV.
    // maxWithdraw caps the asset math at the vault's liquid balance.
    // To make the assets-side math bind (and thus expose the stale-NAV
    // bug), we use a SECOND LP whose share value is far below the
    // vault's liquid balance. The test contract's full-SEED holding
    // would otherwise be capped by liquidity and mask the bug.
    //
    // The small LP must be created BEFORE the mid-epoch warp so the
    // post-warp staleness gap is preserved (a deposit after warp would
    // call _processGlobalVesting and zero the gap).
    function test_maxWithdraw_matchesPostSync_withUnsettledVesting() public {
        // Create a small LP at setUp time (still EPOCH_2 here).
        address smallLp = address(0xCAFE);
        uint256 smallDeposit = 50e6;
        usdc.mint(smallLp, smallDeposit);
        vm.startPrank(smallLp);
        usdc.approve(address(vault), smallDeposit);
        vault.deposit(smallDeposit, smallLp);
        vm.stopPrank();

        // Now stage the mid-epoch unsettled state (borrow, depositRewards,
        // warp). _midEpochUnsettledState rolls 1 block past the
        // smallLp deposit's same-block guard.
        _midEpochUnsettledState();

        uint256 staleMax = vault.maxWithdraw(smallLp);

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 syncedMax = vault.maxWithdraw(smallLp);
        vm.revertToState(snapId);

        assertApproxEqAbs(
            staleMax,
            syncedMax,
            1,
            "maxWithdraw before sync must match maxWithdraw after sync (NAV must be simulated)"
        );
    }

    function test_maxRedeem_matchesPostSync_withUnsettledVesting() public {
        _midEpochUnsettledState();

        uint256 staleMax = vault.maxRedeem(address(this));

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 syncedMax = vault.maxRedeem(address(this));
        vm.revertToState(snapId);

        assertApproxEqAbs(
            staleMax,
            syncedMax,
            1,
            "maxRedeem before sync must match maxRedeem after sync (NAV must be simulated)"
        );
    }

    // ========================================================================
    // Group B — totalAssets simulation directly
    //
    // After fix, `totalAssets()` already simulates `_processGlobalVesting`,
    // so forcing sync produces no change. On the broken implementation,
    // sync raises totalAssets by Δ.
    // ========================================================================

    function test_totalAssets_simulatesPendingVesting() public {
        _midEpochUnsettledState();

        uint256 taBefore = vault.totalAssets();
        vault.sync();
        uint256 taAfter = vault.totalAssets();

        // Post-fix invariant: views must already reflect what sync() would do.
        // 1 wei tolerance for rounding artifacts in share math.
        assertApproxEqAbs(
            taAfter,
            taBefore,
            1,
            "totalAssets() must already include pending vesting; sync() should be a no-op for NAV"
        );
    }

    // ========================================================================
    // Group C — Post-call differential consistency
    //
    // After any mutating function returns, an immediate sync() must not
    // change totalAssets(). This is the regression guard requested by the
    // lending-review pass: once a function runs, NAV is synced — calling
    // sync again can't surface more value.
    //
    // For functions that themselves change totalAssets (deposit pulls
    // assets; withdraw pushes assets), we measure totalAssets BEFORE the
    // sync and assert sync() leaves it unchanged.
    // ========================================================================

    function test_postCall_totalAssetsAlreadySynced_borrow() public {
        // Fresh state — no stream yet. Stage a stream first so a sync would
        // do real work; then borrow; then assert sync after borrow is a no-op.
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        vm.startPrank(borrower);
        usdc.mint(borrower, REWARDS);
        usdc.approve(address(vault), REWARDS);
        vault.depositRewards(REWARDS);
        vm.stopPrank();

        vm.warp(EPOCH_2_HALF);
        vm.roll(block.number + 1);

        // Mint borrower more debt capacity by mocking a portfolio call.
        vm.prank(borrower);
        vault.borrowFromPortfolio(100e6);

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "borrow must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_repay() public {
        _midEpochUnsettledState();

        // Fund borrower for repay.
        usdc.mint(borrower, 50e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 50e6);
        vault.repay(50e6);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "repay must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_depositRewards() public {
        _midEpochUnsettledState();

        // depositRewards top-up onto the existing stream.
        vm.startPrank(borrower);
        usdc.mint(borrower, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "depositRewards must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_incentivize() public {
        _midEpochUnsettledState();

        address eoa = address(0xE0A);
        usdc.mint(eoa, 25e6);
        vm.startPrank(eoa);
        usdc.approve(address(vault), 25e6);
        vault.incentivize(25e6);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "incentivize must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_payFromPortfolio() public {
        _midEpochUnsettledState();

        usdc.mint(borrower, 80e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 80e6);
        vault.payFromPortfolio(80e6, 0);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "payFromPortfolio must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_deposit() public {
        _midEpochUnsettledState();

        address depositor = address(0xD9);
        usdc.mint(depositor, 200e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 200e6);
        vault.deposit(200e6, depositor);
        vm.stopPrank();

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "deposit must leave NAV synced");
    }

    function test_postCall_totalAssetsAlreadySynced_withdraw() public {
        _midEpochUnsettledState();

        // Test contract is the LP. Same-block guard already released
        // in _midEpochUnsettledState's vm.roll.
        vault.withdraw(100e6, address(this), address(this));

        uint256 taAfter = vault.totalAssets();
        vault.sync();
        uint256 taAfterSync = vault.totalAssets();
        assertApproxEqAbs(taAfterSync, taAfter, 1, "withdraw must leave NAV synced");
    }

    // ========================================================================
    // Group D — Fee-accrual consistency under simulation (fuzz)
    //
    // The preview/mint path folds `pendingFeeShares` into the share-side
    // math. Patching totalAssets() to simulate vesting must remain
    // consistent with that fold across the full fee range.
    // ========================================================================

    function testFuzz_previewDeposit_matchesActualDeposit_withFeeBps(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, vault.MAX_FEE_BPS());

        // Set the fee bps before staging the stream so accrual is armed.
        vm.prank(owner);
        vault.setFeeBps(feeBps);

        _midEpochUnsettledState();

        uint256 amountIn = 1_000e6;

        uint256 quotedStale = vault.previewDeposit(amountIn);

        uint256 snapId = vm.snapshotState();
        vault.sync();
        uint256 quotedSynced = vault.previewDeposit(amountIn);
        vm.revertToState(snapId);

        // Post-fix: previewDeposit must already include simulated NAV
        // across the entire fee range. Allow off-by-one for share-math
        // rounding interactions with the inflation-attack virtual-shares
        // offset and the pendingFeeShares fold.
        assertApproxEqAbs(
            quotedStale,
            quotedSynced,
            1,
            "previewDeposit must equal post-sync quote across feeBps range"
        );
    }

    // ========================================================================
    // Group E — _simulateBorrowerCreditPerRateAt expired-stream branch
    //
    // When `block.timestamp >= userPeriodFinish` and the
    // `epochEndBorrowerCreditPerRate[userPeriodFinish]` snapshot has
    // not been written yet, the helper must reproduce the cap-to-finish
    // semantics currently inlined at DynamicFeesVault.sol:322-338.
    //
    // Scenario:
    //   - Borrow 3000e6 at EPOCH_2 (30% util).
    //   - depositRewards(100e6) at EPOCH_2 → stream finishes at EPOCH_3.
    //   - Warp past EPOCH_3 but before EPOCH_4 — into the expired
    //     window where the snapshot has not yet been written because
    //     no state-changing call ran at the boundary.
    //   - Call getEffectiveDebtBalance(borrower). The result must equal
    //     the hand-computed expected value:
    //
    //   The stream ran fully one epoch. globalVested = 100e6.
    //   lenderPremium = 100e6 * 2000 / 10000 = 20e6.
    //   borrowerCredit = 100e6 - 20e6 = 80e6.
    //   The full borrower credit is the borrower's reward (1 borrower,
    //   rate == activeEpochRate at the time).
    //   So the borrower's effective debt = 3000e6 - 80e6 = 2920e6.
    //
    //   We use the exact 1e18-scaled math the production code uses to
    //   eliminate any tolerance issue:
    //
    //   accumulatorDelta = (borrowerCredit * 1e18) / currentRate
    //   borrowerReward   = (currentRate * accumulatorDelta) / 1e18
    //                    = (currentRate * (borrowerCredit * 1e18 / currentRate)) / 1e18
    //                    = borrowerCredit   (exactly, no remainder, since
    //                                        currentRate divides cleanly)
    //
    //   Wait — currentRate = 100e6 / WEEK does NOT divide cleanly. So
    //   we use assertApproxEqAbs with the rate-truncation tolerance,
    //   which is at most (WEEK * 1e18 / 1e18) wei = 1 wei per scaling
    //   round-trip. Conservative tolerance: 2 wei.
    // ========================================================================

    function test_getEffectiveDebtBalance_expiredStream_noEpochSnapshot_handComputed() public {
        // Stage the stream
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        vm.startPrank(borrower);
        usdc.mint(borrower, REWARDS);
        usdc.approve(address(vault), REWARDS);
        vault.depositRewards(REWARDS);
        vm.stopPrank();

        // Warp PAST the stream's periodFinish (EPOCH_3) into the next
        // epoch (EPOCH_3_QUARTER). No state-changing call has crossed
        // the boundary, so:
        //   - userPeriodFinish[borrower] = EPOCH_3
        //   - epochEndBorrowerCreditPerRate[EPOCH_3] = 0 (no snapshot)
        //   - block.timestamp = EPOCH_3_QUARTER >= userPeriodFinish
        // This forces the "snapshot not yet written" branch at
        // DynamicFeesVault.sol:322-338.
        vm.warp(EPOCH_3_QUARTER);

        // Hand-computed expected value.
        // Stream rate (truncated divison): rate = 100e6 / WEEK.
        // Vested-to-finish at EPOCH_3: rate * (EPOCH_3 - EPOCH_2) = rate * WEEK.
        // This may be < 100e6 due to integer truncation of (100e6 / WEEK).
        // Specifically: rate * WEEK = (100e6 / WEEK) * WEEK <= 100e6 with
        // residual <= WEEK - 1 wei. So the rate-truncated `vested` is
        // at most WEEK wei below 100e6.
        //
        // After cap: vestedToFinish = min(vested, totalUnsettledRewards) =
        //            vested (since totalUnsettledRewards == 100e6 >= vested).
        //
        // lenderPremium  = vested * 2000 / 10000 = vested * 0.2 (integer truncation).
        // borrowerCredit = vested - lenderPremium.
        //
        // accumulatorDelta = (borrowerCredit * 1e18) / currentRate.
        // borrowerReward   = (userRate * accumulatorDelta) / 1e18.
        // Because userRate == currentRate (single borrower), the round-trip
        // through 1e18 may lose 1 wei.
        //
        // Effective debt = max(0, storedDebt - borrowerReward) = 3000e6 - borrowerReward.
        //
        // We replicate the exact integer arithmetic of the production code
        // to compute the expected value — NOT delegate to the new code
        // path being tested.
        uint256 currentRate = REWARDS / WEEK;                 // truncating
        uint256 vested      = currentRate * WEEK;             // <= REWARDS
        uint256 lenderPrem  = (vested * LENDER_RATIO_BPS) / 10000;
        uint256 borrowerCr  = vested - lenderPrem;
        uint256 accumDelta  = (borrowerCr * 1e18) / currentRate;
        uint256 borrowerRew = (currentRate * accumDelta) / 1e18;
        uint256 expected    = BORROW > borrowerRew ? BORROW - borrowerRew : 0;

        uint256 actual = vault.getEffectiveDebtBalance(borrower);

        // Tolerate at most 1 wei of 1e18-scaling residual. The hand-computed
        // formula tracks the production integer arithmetic precisely; the
        // only allowed slack is the rounding in `(borrowerCr * 1e18) /
        // currentRate * currentRate / 1e18`.
        assertApproxEqAbs(actual, expected, 1, "expired-stream / no-snapshot branch must match hand-computed cap-to-finish");
    }
}
