// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Regression suite for the dust-growth fee-leak fix in DynamicFeesVault.
// ============================================================================
//
// Bug being prevented (pre-fix behavior):
//   `_accrueFee()` ran `_accrueFeeView()`, which returned `feeShares = 0`
//   whenever `(growth * feeBps) / 10000` rounded to zero. The function still
//   wrote `$.lastTotalAssetsForFee = newTotalAssets`, "consuming" that dust
//   delta without minting any fee shares - the value silently accrued to LPs
//   via `convertToAssets`. Permissionless `settleRewards` made this exploitable:
//   keep growth deltas under `10000/feeBps` between calls and the protocol
//   fee permanently leaks to LPs.
//
// Fix:
//   1. `_accrueFee()` early-returns when `feeShares == 0`, freezing the snapshot.
//   2. `setFeeBps()` calls `_processGlobalVesting()` first, then resets the
//      snapshot ONLY on the off->on (`oldFeeBps == 0 && newFeeBps > 0`) edge.
//   3. `setFeeRecipient()` calls `_processGlobalVesting()` first, then resets
//      the snapshot ONLY when `oldRecipient == address(0)` (initial set).
//
// The tests below cover:
//   - Dust accumulation across many calls -> eventual mint when threshold crossed.
//   - Happy path large growth (non-regression).
//   - Dust survives LP deposit/withdraw via the snapshot bump/floor in
//     `_deposit`/`_withdraw` (NOT a snapshot-to-totalAssets reset).
//   - Snapshot frozen above totalAssets / equal to totalAssets path
//     (`newTotalAssets <= last` early-return in `_accrueFeeView`).
//   - `setFeeBps` off->on does NOT retrofit fees on the off-window growth.
//   - `setFeeBps` rate->rate preserves pending dust (no reset).
//   - `setFeeBps` zero->zero is a noop.
//   - `setFeeRecipient` initial set from zero does NOT retrofit fees (gate).
//   - `setFeeRecipient` rotation crystallizes to OLD recipient and does NOT reset.
//
// Conventions (matches DynamicFeesVaultTreasury.t.sol):
//   - Hardcoded absolute timestamps (via-ir caches `block.timestamp`).
//   - Real ERC4626 vault, real USDC mock - no fee math mocks.
//   - 6-decimal asset, 6-decimal share offset.
// ============================================================================

import {Test, console, Vm} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

// ============ Mocks ============

contract MockUSDCLeak is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryLeak is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }
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

/// @dev Pinned 20% lender ratio for predictable splits.
contract FlatFeeCalculatorLeak is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// ============================================================================
// Test contract
// ============================================================================

contract DynamicFeesVaultFeeAccrualLeakTest is Test {
    DynamicFeesVault public vault;
    MockUSDCLeak public usdc;
    MockPortfolioFactoryLeak public portfolioFactory;

    address public owner;
    address public lp;       // initial LP (the test contract)
    address public borrower;
    address public feeRecipient;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;
    uint256 constant EPOCH_6 = 6 * WEEK;
    uint256 constant EPOCH_7 = 7 * WEEK;

    uint256 constant SEED = 10_000e6;

    // Re-declare events for vm.expectEmit
    event FeeAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    // ============ setUp ============

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        lp = address(0x10);
        borrower = address(0x20);
        feeRecipient = address(0xFEE);

        usdc = new MockUSDCLeak();
        portfolioFactory = new MockPortfolioFactoryLeak();
    }

    // ============ Helpers ============

    /// @dev Deploys a vault and seeds it with SEED USDC from the test contract as initial LP.
    function _deployAndSeedVault(uint256 _feeBps) internal returns (DynamicFeesVault v) {
        v = _deployVault(_feeBps, feeRecipient);
        usdc.mint(address(this), SEED);
        usdc.approve(address(v), SEED);
        v.deposit(SEED, address(this));
    }

    function _deployVault(uint256 _feeBps, address _recipient) internal returns (DynamicFeesVault v) {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory), _recipient, _feeBps
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
    }

    function _setFlatRatio(DynamicFeesVault v, uint256 ratioBps) internal {
        FlatFeeCalculatorLeak fc = new FlatFeeCalculatorLeak(ratioBps);
        vm.prank(owner);
        v.setFeeCalculator(address(fc));
    }

    function _borrow(DynamicFeesVault v, address user, uint256 amount) internal {
        vm.prank(user);
        v.borrowFromPortfolio(amount);
    }

    function _depositRewards(DynamicFeesVault v, address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(v), amount);
        v.depositRewards(amount);
        vm.stopPrank();
    }

    /// @dev Donates `amount` USDC directly to the vault (bypasses depositRewards),
    ///      causing totalAssets() to grow by exactly `amount` since donation is
    ///      not subtracted by any deduction term.
    function _donate(DynamicFeesVault v, uint256 amount) internal {
        usdc.mint(address(v), amount);
    }

    // =========================================================================
    // Test 1: Dust growth accumulates without leaking, eventually mints.
    //
    // feeBps = 100 (1%) -> growth threshold = 10000/100 = 100 wei.
    // Each 1-wei donation -> (1 * 100) / 10000 = 0 -> frozen.
    // After 99 cumulative wei: still rounds to 0.
    // After 100 cumulative wei: growth crosses threshold, mint observable.
    //
    // Pre-fix behavior: snapshot would advance every sync, so the dust
    // delta would be silently consumed without minting. The post-fix
    // assertions below would FAIL on the un-fixed code:
    //   - `lastAfterFirstDust == lastBeforeFirstDust` (frozen) <- would fail
    //   - shares > 0 after threshold cross <- would fail (snapshot already advanced)
    // =========================================================================

    function test_dustGrowthAccumulates_eventuallyMintsFee() public {
        vault = _deployAndSeedVault(100); // 1% fee
        uint256 lastBefore = vault.lastTotalAssetsForFee();
        uint256 totalBefore = vault.totalAssets();
        assertEq(lastBefore, SEED, "snapshot starts at SEED post-init+seed");
        assertEq(totalBefore, SEED, "totalAssets starts at SEED");
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares minted yet");

        // Donate 1 wei and sync. Verify rounding-to-zero math and frozen snapshot.
        _donate(vault, 1);
        // Sanity: (1 * 100)/10000 == 0 confirms test 1 is exercising the dust path.
        assertEq((1 * uint256(100)) / 10000, 0, "math sanity: 1 wei * 1% rounds to 0");

        vault.sync();
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares after first dust");
        assertEq(
            vault.lastTotalAssetsForFee(), SEED,
            "snapshot frozen at SEED - the bug would have advanced this to SEED+1"
        );
        assertEq(vault.totalAssets(), SEED + 1, "totalAssets grew by exactly 1 wei");

        // Drive 98 more 1-wei dust events (total 99 dust). Each must keep snapshot frozen.
        for (uint256 i = 2; i <= 99; ++i) {
            _donate(vault, 1);
            vault.sync();
            assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares mid-dust");
            assertEq(
                vault.lastTotalAssetsForFee(), SEED,
                "snapshot must remain frozen at SEED through 99 cumulative dust wei"
            );
            assertEq(vault.totalAssets(), SEED + i, "totalAssets tracks cumulative dust");
        }

        // 100th wei: cumulative growth = 100, (100 * 100)/10000 = 1 fee asset -> mint > 0.
        _donate(vault, 1);
        // Sanity: (100 * 100)/10000 == 1 confirms threshold cross.
        assertEq((100 * uint256(100)) / 10000, 1, "math sanity: 100 wei * 1% == 1 fee asset");

        vault.sync();
        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        uint256 lastAfter = vault.lastTotalAssetsForFee();

        assertGt(sharesAfter, 0, "fee shares MUST mint once cumulative dust crosses threshold");
        assertEq(lastAfter, SEED + 100, "snapshot advances to current totalAssets after mint");
        // Fee asset value rounding: 1 fee asset on a SEED-share-supply vault may
        // round to 0 share value - we verify the SHARES are nonzero (the share
        // mint formula `feeAssets * (totalSupply + virtualShares) / (newTotalAssets - feeAssets + 1)`
        // gives a strictly positive result for feeAssets >= 1 and totalSupply > 0).

        // Cumulative dust = 100 wei realized as 1 fee asset, NOT silently leaked to LPs.
        // We don't assert tight equality on convertToAssets(shares) because the
        // share-pricing virtual-offset math can round 1-asset fee mints to 0
        // assets back; the structural assertion (snapshot advanced, shares > 0) is
        // the regression marker.
    }

    // =========================================================================
    // Test 2: Non-regression - large growth still mints (the early-return is
    // not over-tightened).
    // =========================================================================

    function test_happyPath_largeGrowth_stillMints() public {
        vault = _deployAndSeedVault(2500); // 25%
        uint256 lastBefore = vault.lastTotalAssetsForFee();
        assertEq(lastBefore, SEED, "snapshot at SEED post-seed");

        // Donate 1_000_000 wei (1e6). Growth threshold at 25% = 4 wei. We're
        // well above. Expected feeAssets = 1e6 * 2500 / 10000 = 2.5e5.
        uint256 donation = 1e6;
        _donate(vault, donation);

        uint256 expectedFeeAssets = (donation * 2500) / 10000;
        assertGt(expectedFeeAssets, 0, "math sanity: large-growth path mints > 0 fee assets");

        vault.sync();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        uint256 lastAfter = vault.lastTotalAssetsForFee();

        assertGt(sharesAfter, 0, "fee shares must mint on large growth");
        assertEq(lastAfter, SEED + donation, "snapshot advances exactly to current totalAssets");
        // Tight check: fee asset value matches expected within rounding (<= 1 wei).
        uint256 feeValue = vault.convertToAssets(sharesAfter);
        assertApproxEqAbs(feeValue, expectedFeeAssets, 1,
            "feeAssetValue ~= growth * feeBps / 10000");
    }

    // =========================================================================
    // Test 3: Pending dust survives an LP deposit.
    //
    // _deposit bumps `lastTotalAssetsForFee += assets`. Combined with the
    // _accrueFee early-return (snapshot frozen on dust), the dust delta
    // (`totalAssets - lastTotalAssetsForFee`) is preserved across the deposit.
    //
    // This test would FAIL on a buggy alternative where _deposit reset the
    // snapshot to current totalAssets instead of bumping arithmetically.
    // =========================================================================

    function test_dustThenDeposit_preservesPendingGrowth() public {
        vault = _deployAndSeedVault(100); // 1%
        // Seed 50 wei of dust and freeze.
        _donate(vault, 50);
        vault.sync();
        assertEq(vault.lastTotalAssetsForFee(), SEED, "snapshot frozen at SEED");
        assertEq(vault.totalAssets(), SEED + 50, "totalAssets = SEED + 50 dust");
        assertEq(vault.balanceOf(feeRecipient), 0, "no shares pre-deposit");

        // LP deposits 1_000e6.
        uint256 depositAmount = 1_000e6;
        usdc.mint(lp, depositAmount);
        vm.startPrank(lp);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, lp);
        vm.stopPrank();

        // The deposit triggers _processGlobalVesting (no stream, no work) ->
        // _accrueFee. Pre-deposit growth=50 wei, (50*100)/10000=0 -> frozen.
        // Then super._deposit + snapshot += assets.
        // POST-FIX expected: snapshot = oldSnapshot(SEED) + assets = SEED + 1_000e6.
        // PRE-FIX expected: snapshot would have advanced to current totalAssets
        // BEFORE the deposit (SEED + 50), then += assets -> SEED + 50 + 1_000e6.
        // Either way the dust delta is destroyed pre-fix; preserved post-fix.
        assertEq(
            vault.lastTotalAssetsForFee(), SEED + depositAmount,
            "snapshot moves arithmetically by deposit, dust delta preserved"
        );
        assertEq(
            vault.totalAssets(), SEED + 50 + depositAmount,
            "totalAssets tracks dust + deposit"
        );
        // Dust still pending: totalAssets - snapshot = 50.
        assertEq(
            vault.totalAssets() - vault.lastTotalAssetsForFee(), 50,
            "50 wei of dust still pending after deposit"
        );
        assertEq(vault.balanceOf(feeRecipient), 0, "no shares minted yet");

        // Push more dust over the threshold. 50 already pending; need 50 more
        // to hit the 100-wei threshold for one fee asset.
        _donate(vault, 50);
        vault.sync();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        assertGt(sharesAfter, 0, "fee shares mint on cumulative dust + new growth");
        // Snapshot advances to totalAssets at mint time = SEED + 100 + depositAmount.
        assertEq(
            vault.lastTotalAssetsForFee(),
            SEED + 100 + depositAmount,
            "snapshot moves to current totalAssets after mint"
        );
    }

    // =========================================================================
    // Test 4: Pending dust survives an LP withdraw.
    //
    // _withdraw applies the floor `last > assets ? last - assets : 0`. If the
    // floor doesn't activate (assets < last), the dust delta is preserved
    // arithmetically.
    // =========================================================================

    function test_dustThenWithdraw_preservesPendingGrowth() public {
        vault = _deployAndSeedVault(100); // 1%
        // Build dust above the snapshot.
        _donate(vault, 50);
        vault.sync();
        assertEq(vault.lastTotalAssetsForFee(), SEED, "snapshot frozen at SEED");
        assertEq(vault.totalAssets(), SEED + 50, "totalAssets = SEED + 50 dust");

        // Need to roll past lastDepositBlock guard from setUp deposit.
        vm.roll(block.number + 5);

        // The test contract is the initial LP from _deployAndSeedVault. Withdraw
        // 1000e6 - well below `last = SEED`, so floor does NOT activate.
        uint256 withdrawAmount = 1_000e6;
        vault.withdraw(withdrawAmount, address(this), address(this));

        // Expected snapshot = SEED - 1_000e6.
        // Expected totalAssets = SEED + 50 - 1_000e6.
        assertEq(
            vault.lastTotalAssetsForFee(), SEED - withdrawAmount,
            "snapshot subtracts withdraw amount, dust delta preserved"
        );
        assertEq(
            vault.totalAssets(), SEED + 50 - withdrawAmount,
            "totalAssets reflects withdraw + dust"
        );
        // Dust still pending.
        assertEq(
            vault.totalAssets() - vault.lastTotalAssetsForFee(), 50,
            "50 wei dust still pending after withdraw"
        );
        assertEq(vault.balanceOf(feeRecipient), 0, "no shares yet");

        // Push more dust; threshold cross at cumulative 100 wei.
        _donate(vault, 50);
        vault.sync();
        uint256 shares = vault.balanceOf(feeRecipient);
        assertGt(shares, 0, "fee shares mint after threshold cross post-withdraw");
    }

    // =========================================================================
    // Test 5: `newTotalAssets <= last` early-return guard works.
    //
    // The production code has TWO guards that can return (newTotalAssets, 0):
    //   (a) `newTotalAssets <= last` - totalAssets at-or-below snapshot.
    //   (b) `feeAssets == 0` - sub-mintable growth.
    //
    // Test 1 covers (b). This test covers (a): the equality case (`newTotalAssets == last`)
    // and the "frozen snapshot survives a sync that has no growth" case.
    //
    // Across all standard public paths, `totalAssets()` is invariant across
    // `_processGlobalVesting` extraction (lender premium routes from
    // `totalUnsettledRewards` deduction into `vestingEpochPremium` deduction +
    // `globalBorrowerPending` deduction with equal magnitude). So a strict
    // dip is design-prevented; we verify the equality case fires the guard.
    //
    // A subsequent recovery (real growth) must mint fees on the recovery delta
    // measured from the FROZEN snapshot, not from the equality-point.
    // =========================================================================

    function test_totalAssetsDecreaseAndRecover_resumesAccrual() public {
        vault = _deployAndSeedVault(2500); // 25%

        // Drive a clean fee mint so the snapshot moves to a known elevated value.
        _donate(vault, 1_000e6);
        vault.sync();
        uint256 firstShares = vault.balanceOf(feeRecipient);
        uint256 snapshotAfterFirstMint = vault.lastTotalAssetsForFee();
        assertGt(firstShares, 0, "first mint produces shares");
        assertEq(snapshotAfterFirstMint, SEED + 1_000e6,
            "snapshot at SEED+donation post-mint");
        assertEq(vault.totalAssets(), SEED + 1_000e6,
            "totalAssets matches snapshot exactly post-mint");

        // GUARD CHECK (a): a second sync with NO growth - newTotalAssets == last.
        // The early-return must fire; no new shares, no snapshot move.
        vault.sync();
        assertEq(
            vault.balanceOf(feeRecipient), firstShares,
            "no shares minted when newTotalAssets == last"
        );
        assertEq(
            vault.lastTotalAssetsForFee(), snapshotAfterFirstMint,
            "snapshot unchanged when no growth"
        );

        // PRODUCTION INVARIANT CHECK: drive a stream extraction. Because
        // _processGlobalVesting is invariant for totalAssets, the snapshot
        // (already equal to totalAssets) does not strictly exceed totalAssets
        // after extraction. We verify this property and that no spurious mint
        // occurs during the stream cycle.
        _setFlatRatio(vault, 2000); // 20% lender split
        // Advance to a fresh epoch to avoid setUp's partial-week artifacts.
        vm.warp(EPOCH_3);

        // Borrow + deposit rewards to set up an active stream.
        _borrow(vault, borrower, 3_000e6);
        _depositRewards(vault, borrower, 200e6);

        uint256 totalAssetsBeforeExtraction = vault.totalAssets();
        uint256 snapshotBeforeExtraction = vault.lastTotalAssetsForFee();
        // Snapshot must be <= totalAssets before extraction (the borrow+deposit paths
        // call _processGlobalVesting -> _accrueFee, but neither path drives growth).
        assertLe(snapshotBeforeExtraction, totalAssetsBeforeExtraction,
            "snapshot <= totalAssets pre-extraction");

        // Warp to epoch boundary and trigger extraction via sync.
        vm.warp(EPOCH_4);
        vault.sync();

        uint256 totalAssetsAfterExtraction = vault.totalAssets();
        uint256 snapshotAfterExtraction = vault.lastTotalAssetsForFee();

        // CRITICAL INVARIANT: snapshot must NOT strictly exceed totalAssets in
        // any normal-path scenario. The early-return guard `newTotalAssets <= last`
        // is defensive - verify it never trips erroneously, and totalAssets
        // remains >= snapshot after extraction.
        assertGe(
            totalAssetsAfterExtraction, snapshotAfterExtraction,
            "totalAssets >= snapshot post-extraction (production invariant)"
        );

        // RECOVERY: fully vest stream's premium. Warp past the epoch boundary so
        // the unvested-premium deduction stops applying.
        vm.warp(EPOCH_5);
        uint256 sharesBeforeRecovery = vault.balanceOf(feeRecipient);
        vault.sync();
        uint256 sharesAfterRecovery = vault.balanceOf(feeRecipient);

        // The lender premium for a 200e6 stream at 20% = 40e6.
        // Once fully vested it lifts totalAssets by 40e6 above the previous
        // snapshot, and 25% of that (10e6) is the fee.
        assertGt(
            sharesAfterRecovery, sharesBeforeRecovery,
            "fee resumes accruing on recovery delta above frozen snapshot"
        );

        // Snapshot moved up to current totalAssets.
        assertEq(
            vault.lastTotalAssetsForFee(), vault.totalAssets(),
            "snapshot now matches totalAssets again"
        );
    }

    // =========================================================================
    // Test 6: setFeeBps off->on does NOT retrofit fees on the off-window growth.
    //
    // This is the CRITICAL fairness property: an LP cannot be charged fees
    // on totalAssets growth that occurred while the fee was disabled.
    //
    // Pre-fix behavior (ABSENT the off->on snapshot reset): the off-window
    // growth would be measured against the stale snapshot at the moment
    // setFeeBps(rate>0) was called -> the next sync would mint on the entire
    // off-window growth. This test would FAIL on the un-fixed code.
    // =========================================================================

    function test_setFeeBps_offToOn_doesNotRetrofitFees() public {
        // Start with feeBps = 0 (fee disabled). Init requires nonzero recipient,
        // and feeBps=0 is allowed at init, so this is the natural off state.
        vault = _deployAndSeedVault(0);
        assertEq(vault.feeBps(), 0, "feeBps starts at 0");
        assertEq(vault.lastTotalAssetsForFee(), SEED, "snapshot at SEED");

        // Drive significant growth during the off-window. Several fee-mintable
        // units worth at the eventual fee rate.
        uint256 offWindowGrowth = 10_000e6;
        _donate(vault, offWindowGrowth);
        // Even though feeBps=0, _accrueFee is called from _processGlobalVesting.
        // _accrueFeeView short-circuits on `feeBpsLocal == 0` returning feeShares=0.
        // Post-fix: early-return -> snapshot frozen at SEED.
        vault.sync();
        assertEq(vault.balanceOf(feeRecipient), 0, "no shares minted at feeBps=0");
        assertEq(
            vault.lastTotalAssetsForFee(), SEED,
            "snapshot frozen at SEED through the off-window"
        );

        // Flip on at 25% bps. This MUST reset the snapshot to current totalAssets.
        vm.prank(owner);
        vault.setFeeBps(2500);

        // Post-fix: setFeeBps on the off->on edge resets snapshot to totalAssets().
        assertEq(
            vault.lastTotalAssetsForFee(),
            vault.totalAssets(),
            "off->on edge MUST reset snapshot - would FAIL pre-fix"
        );
        assertEq(
            vault.lastTotalAssetsForFee(), SEED + offWindowGrowth,
            "snapshot now at SEED + offWindow (no retroactive accrual baseline)"
        );

        // Trigger the next state-changing path. There must be ZERO fee shares
        // on the off-window growth.
        vault.sync();
        assertEq(
            vault.balanceOf(feeRecipient), 0,
            "off-window growth NOT retroactively charged - would FAIL pre-fix"
        );

        // Sanity: subsequent post-flip growth IS charged at the new rate.
        _donate(vault, 1_000e6);
        vault.sync();
        uint256 shares = vault.balanceOf(feeRecipient);
        assertGt(shares, 0, "post-flip growth IS charged");
        // Tight: 25% * 1_000e6 = 250e6.
        uint256 feeValue = vault.convertToAssets(shares);
        assertApproxEqAbs(feeValue, 250e6, 250e6 / 100,
            "post-flip fee ~= 25% * 1_000e6 = 250e6");
    }

    // =========================================================================
    // Test 7: setFeeBps rate->rate (e.g. 100 -> 50) does NOT reset the snapshot,
    //          and pending dust is preserved through the rate change.
    //
    // Key behavior: setFeeBps calls _processGlobalVesting FIRST. If the pending
    // dust is mintable at the OLD rate, _accrueFee crystallizes it at the OLD
    // rate before the rate change takes effect. Otherwise dust survives.
    //
    // We use a setup where the dust is mintable at the OLD rate (100 bps)
    // so we can exact-check the crystallized fee value.
    // =========================================================================

    function test_setFeeBps_rateToRate_preservesPendingGrowth() public {
        vault = _deployAndSeedVault(100); // start at 1%

        // Drive 1_000_000 wei of growth. At 100 bps this is 100 fee assets.
        // Mintable at OLD rate (not dust under 100 bps threshold).
        uint256 growth = 1_000_000;
        _donate(vault, growth);
        // Don't sync yet - pend the growth.

        uint256 totalBefore = vault.totalAssets();
        assertEq(totalBefore, SEED + growth, "totalAssets = SEED + 1e6");
        assertEq(vault.lastTotalAssetsForFee(), SEED, "snapshot still at SEED pre-update");

        // Change rate from 100 -> 50. setFeeBps calls _processGlobalVesting FIRST,
        // which runs _accrueFee at the OLD rate (100 bps) and crystallizes the
        // mintable portion. Then the rate is changed. Old(100) != 0, so the
        // off->on gate does NOT trip - snapshot is NOT force-reset.
        uint256 expectedFeeAssetsAtOldRate = (growth * 100) / 10000; // 10_000 wei = 1e4
        assertEq(expectedFeeAssetsAtOldRate, 1e4, "math: 1e6 * 100bps = 1e4 fee assets");

        vm.prank(owner);
        vault.setFeeBps(50);

        assertEq(vault.feeBps(), 50, "rate updated");

        // Crystallization happened at the OLD rate. Fee shares were minted on
        // _processGlobalVesting -> _accrueFee. Verify by share value.
        uint256 sharesAtOldRate = vault.balanceOf(feeRecipient);
        assertGt(sharesAtOldRate, 0, "fee crystallized at OLD rate during _processGlobalVesting");
        uint256 feeValueAtOldRate = vault.convertToAssets(sharesAtOldRate);
        // Tight: should match (growth * oldBps / 10000) = 1e4 within rounding.
        assertApproxEqAbs(
            feeValueAtOldRate, expectedFeeAssetsAtOldRate, 5,
            "crystallized fee ~= growth * OLD bps / 10000"
        );

        // Snapshot must equal current totalAssets (after the crystallized accrual
        // wrote it). It was NOT force-reset by the off->on gate.
        assertEq(
            vault.lastTotalAssetsForFee(), vault.totalAssets(),
            "snapshot at totalAssets after rate->rate accrual (no force-reset)"
        );

        // Drive new growth at the NEW rate. Verify fee accrues at 50 bps now.
        _donate(vault, growth);
        vault.sync();
        uint256 sharesAfterNewGrowth = vault.balanceOf(feeRecipient);
        uint256 newGrowthShares = sharesAfterNewGrowth - sharesAtOldRate;
        uint256 newFeeValue = vault.convertToAssets(newGrowthShares);
        // Tight: 1e6 * 50bps = 5_000 wei.
        uint256 expectedNewFee = (growth * 50) / 10000;
        assertEq(expectedNewFee, 5_000, "math sanity");
        assertApproxEqAbs(newFeeValue, expectedNewFee, 5,
            "new growth charged at NEW (50bps) rate");
    }

    // =========================================================================
    // Test 8: setFeeBps(0) when current is already 0 - noop.
    // =========================================================================

    function test_setFeeBps_zeroToZero_isNoop() public {
        vault = _deployAndSeedVault(0);

        // Drive some growth so totalAssets != snapshot. Even with feeBps=0, this
        // should not be retro-charged on the noop call.
        _donate(vault, 1_000e6);
        uint256 snapshotBefore = vault.lastTotalAssetsForFee();
        uint256 sharesBefore = vault.balanceOf(feeRecipient);
        assertEq(snapshotBefore, SEED, "snapshot frozen during off-window");

        // setFeeBps(0) -> old=0, new=0. The gate `old==0 && new>0` is FALSE. The
        // setter calls _processGlobalVesting first; _accrueFee sees feeBps=0
        // (still zero at this point) -> returns feeShares=0 -> frozen.
        vm.prank(owner);
        vault.setFeeBps(0);

        assertEq(vault.feeBps(), 0, "still 0");
        assertEq(
            vault.lastTotalAssetsForFee(), snapshotBefore,
            "snapshot unchanged on zero->zero (no off->on reset, no accrual)"
        );
        assertEq(
            vault.balanceOf(feeRecipient), sharesBefore,
            "no shares minted on zero->zero"
        );
    }

    // =========================================================================
    // Test 9: setFeeRecipient initial set from address(0) does NOT retrofit fees.
    //
    // The init validates `_feeRecipient != address(0)`, so we cannot reach
    // `feeRecipient == address(0)` through the public API. We construct that
    // state directly via `vm.store` to exercise the dead-code-looking gate
    // `if (old == address(0)) { reset snapshot }`.
    //
    // This test guards the gate against regressions if a future migration
    // path ever lands `feeRecipient == 0` in storage.
    // =========================================================================

    function test_setFeeRecipient_initialSetFromZero_doesNotRetrofitFees() public {
        vault = _deployAndSeedVault(2500); // 25% fee

        // Compute the storage slot for `feeRecipient` (struct offset 26).
        bytes32 STORAGE_LOCATION = 0x9a0c9d8ec1d9f8b4c5e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b200;
        bytes32 feeRecipientSlot = bytes32(uint256(STORAGE_LOCATION) + 26);

        // Sanity: verify the slot maps to the recipient address before overwriting.
        bytes32 currentSlotValue = vm.load(address(vault), feeRecipientSlot);
        assertEq(
            address(uint160(uint256(currentSlotValue))), feeRecipient,
            "feeRecipient slot must match expected layout - recompute slot if this fails"
        );

        // Force feeRecipient to address(0).
        vm.store(address(vault), feeRecipientSlot, bytes32(0));
        assertEq(vault.feeRecipient(), address(0), "feeRecipient now zero (forced)");

        // Drive growth. With recipient==0, _accrueFeeView short-circuits
        // (`recipient == address(0)` -> feeShares=0). Post-fix: snapshot frozen.
        uint256 offWindowGrowth = 1_000e6;
        _donate(vault, offWindowGrowth);
        vault.sync();
        assertEq(
            vault.lastTotalAssetsForFee(), SEED,
            "snapshot frozen during recipient-zero window"
        );

        // Set the recipient. This is the initial-set gate (`old == address(0)`),
        // which MUST reset the snapshot to current totalAssets.
        address alice = address(0xA11CE);
        vm.prank(owner);
        vault.setFeeRecipient(alice);

        // Pending growth must NOT be charged to alice.
        assertEq(
            vault.lastTotalAssetsForFee(), vault.totalAssets(),
            "initial-set gate MUST reset snapshot to totalAssets"
        );
        assertEq(
            vault.lastTotalAssetsForFee(), SEED + offWindowGrowth,
            "snapshot at SEED + offWindow"
        );
        assertEq(
            vault.balanceOf(alice), 0,
            "alice MUST NOT receive shares on the off-window growth"
        );

        // Subsequent growth IS charged to alice.
        _donate(vault, 1_000e6);
        vault.sync();
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "alice charged on post-set growth");
        // Tight: 25% * 1_000e6 = 250e6.
        uint256 aliceFeeValue = vault.convertToAssets(aliceShares);
        assertApproxEqAbs(aliceFeeValue, 250e6, 250e6 / 100,
            "alice fee ~= 25% * 1_000e6");
    }

    // =========================================================================
    // Test 10: setFeeRecipient rotation crystallizes pending fee to OLD recipient
    //          and does NOT reset the snapshot.
    //
    // The gate `old == address(0)` does NOT trip on a rotation (alice->bob),
    // so the snapshot is NOT force-reset. _processGlobalVesting runs FIRST,
    // crystallizing the mintable portion to alice via _accrueFee.
    // =========================================================================

    function test_setFeeRecipient_nonInitialChange_crystallizesToOldRecipient() public {
        vault = _deployAndSeedVault(2500); // 25%

        // alice is the initial recipient (set in setUp via _deployAndSeedVault).
        address alice = feeRecipient;
        address bob = address(0xB0B);

        // Drive growth above the mintable threshold. 1_000e6 * 25% = 250e6.
        uint256 growth = 1_000e6;
        _donate(vault, growth);

        // Pre-rotation: snapshot still at SEED, no shares yet.
        assertEq(vault.lastTotalAssetsForFee(), SEED, "snapshot at SEED pre-rotation");
        assertEq(vault.balanceOf(alice), 0, "alice has 0 shares pre-rotation");

        // Rotate alice->bob. setFeeRecipient calls _processGlobalVesting FIRST,
        // which runs _accrueFee while $.feeRecipient is still alice.
        // Crystallization mints to alice. THEN the recipient is updated to bob.
        vm.prank(owner);
        vault.setFeeRecipient(bob);

        assertEq(vault.feeRecipient(), bob, "recipient is now bob");
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "alice MUST have received the crystallized fee");
        assertEq(vault.balanceOf(bob), 0, "bob has 0 shares immediately after rotation");

        // Tight check: alice's fee ~= 25% * growth = 250e6.
        uint256 aliceFeeValue = vault.convertToAssets(aliceShares);
        assertApproxEqAbs(aliceFeeValue, 250e6, 250e6 / 100,
            "alice received ~= 25% * 1_000e6 (crystallized at OLD rate, OLD recipient)");

        // Snapshot was NOT force-reset (the gate `old == address(0)` is FALSE
        // on a rotation). It was advanced by _accrueFee writing newTotalAssets.
        assertEq(
            vault.lastTotalAssetsForFee(), vault.totalAssets(),
            "snapshot moved by _accrueFee, not force-reset by the gate"
        );

        // Subsequent growth charges bob, not alice.
        _donate(vault, 1_000e6);
        vault.sync();

        uint256 aliceSharesAfter = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        assertEq(aliceSharesAfter, aliceShares, "alice frozen after rotation");
        assertGt(bobShares, 0, "bob now accumulates");
        uint256 bobFeeValue = vault.convertToAssets(bobShares);
        assertApproxEqAbs(bobFeeValue, 250e6, 250e6 / 100,
            "bob fee ~= 25% * 1_000e6");
    }
}
