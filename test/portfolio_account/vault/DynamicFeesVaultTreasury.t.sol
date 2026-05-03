// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Issue Summary (findings from grounding-read of DynamicFeesVault.sol)
// ============================================================================
//
//
// Behaviors validated:
// - Setter access control + validation (`setFeeRecipient`, `setFeeBps`)
// - Initialize validation (`address(0)`, `feeBps > 5000`)
// - Default-disabled state when `feeBps == 0`
// - Fee accrual mints shares to `feeRecipient`, NOT USDC
// - `totalAssets()` invariance across `_processGlobalVesting`
// - Share-price dilution via mint (intended) at non-zero fee
// - All state-changing paths trigger `_accrueFee`
// - Borrower economics are EXACTLY the same with `feeBps = 0` vs active fee
// - `getEffectiveDebtBalance` consistency with `_settleRewards`
// - LP `deposit`/`withdraw` are NOT counted as interest (snapshot bumps)
// - Recipient blacklist does NOT halt vault operation (unlike old treasury)
//   only the recipient's own `redeem()` reverts
// - Recipient rotation freezes prior recipient's accrual
// - Mid-stream `feeBps` update applies to subsequent accruals only
// - `pendingFeeShares` view consistency
// - Preview function fairness (deposit/mint/withdraw/redeem)
// - Redemption flow (success + insufficient liquidity)
// - `FeeAccrued` event arguments
// - Regression guard: `depositRewards` must NOT count its own inflow as interest
//
// Quirks of the vesting timing (governs WHERE in the stream chain a fee is realized):
// - `totalAssets()` excludes both `totalUnsettledRewards` (pending stream) AND
//   `unvestedLenderPremium`. Under the single-bucket current-epoch vesting
//   model, a reward stream's lender premium is routed to `vestingEpochPremium`
//   when extracted, with `vestingEpochStart = max(existing, epochStart(now))`.
//   It vests linearly across the REMAINDER of that epoch and is fully realized
//   into `totalAssets()` by the start of the next epoch — a 1-epoch lag from
//   settlement.
// - Net result: lender premium from a deposit in epoch N, settled at the
//   epoch boundary (start of N+1), becomes part of `totalAssets()` by start
//   of N+1 (or strictly speaking, fully realized by start of N+2 if
//   `vestStart = N+1` when the stream finalizes at the boundary).
// - The 2-stream chain in `_twoEpochVestSetup` (deposits at EPOCH_2 and
//   EPOCH_4) is sized so a sync at EPOCH_5 realizes exactly ONE premium:
//   stream #1's 20e6 (interest delta = 20e6, fee at 25% bps = 5e6).
//   Stream #2's premium routes to `vestingEpochStart = EPOCH_5` and stays
//   unvested at the moment of sync.
// - The `currentEpochPremium` / `currentEpochStart` storage slots in
//   `DynamicFeesVaultStorage` are retained for ERC-7201 layout compatibility
//   but are NEVER WRITTEN under the single-bucket model. See the comment
//   block in `DynamicFeesVault._processGlobalVesting` for the rationale.
// - via-ir caches `block.timestamp` and `block.number` across cheatcodes; we
//   use HARDCODED absolute timestamps and NEVER warp backward.
// - In setUp, the test contract is the initial LP, and `lastTotalAssetsForFee`
//   is bumped by the deposit. So at setUp end:
//       lastTotalAssetsForFee == totalAssets() == seedAmount
//
// Math reference for the canonical scenario (used by many tests below):
//   3 streams of 100e6 (rate=2000 bps lender, feeBps=2500), sync at EPOCH_5:
//     interest delta  = 20e6  (one stream's fully-realized lender premium)
//     feeAssets       = 5e6   (= interest * feeBps / 10000)
//     feeAssetValue ≈ 5e6 (within tiny rounding from share-price math)
// ============================================================================

import {Test, console, Vm} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";
import {MockBlacklistableERC20} from "../../mocks/MockBlacklistableERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// ============ Mocks ============

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryFee is IPortfolioFactory {
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

/// @dev Pinned 20% lender ratio so we can compute exact expected splits.
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// ============================================================================
// Test contract
// ============================================================================

contract DynamicFeesVaultTreasuryTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryFee public portfolioFactory;

    address public owner;
    address public lender;       // initial LP (test contract acts as second LP too)
    address public borrower;
    address public feeRecipient;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // setUp warps to 2*WEEK. We pre-compute hardcoded absolute timestamps so via-ir
    // can't bite us with cached block.timestamp.
    uint256 constant EPOCH_2 = 2 * WEEK; // setUp time
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;
    uint256 constant EPOCH_6 = 6 * WEEK;
    uint256 constant EPOCH_7 = 7 * WEEK;
    uint256 constant EPOCH_8 = 8 * WEEK;

    uint256 constant SEED = 10_000e6;
    uint256 constant DEFAULT_FEE_BPS = 2500;

    // Re-declare events for vm.expectEmit
    event FeeAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    // ============ setUp ============

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        lender = address(0x10);
        borrower = address(0x20);
        feeRecipient = address(0xFEE);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryFee();

        vault = _deployVault(address(usdc), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS);

        // Seed vault with liquidity (test contract is initial LP)
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, address(this));
    }

    // ============ Helpers ============

    function _deployVault(
        address asset_,
        address pf,
        address recip,
        uint256 _feeBps
    ) internal returns (DynamicFeesVault v) {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            asset_, "USDC Vault", "vUSDC", pf, 8000, recip, _feeBps
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
    }

    function _setFlatRatio(uint256 ratioBps) internal {
        FlatFeeCalculator fc = new FlatFeeCalculator(ratioBps);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        vault.borrowFromPortfolio(amount);
    }

    function _depositRewards(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.mint(user, amount);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    /// @dev Sets up util ~30% (flat 20% lender ratio) with TWO non-adjacent reward streams.
    ///
    ///      Stream chain (each runs one epoch, lender premium 20e6/each):
    ///        Stream #1: deposited EPOCH_2, runs EPOCH_2→EPOCH_3
    ///        Stream #2: deposited EPOCH_4, runs EPOCH_4→EPOCH_5
    ///
    ///      Premium realization timeline under the single-bucket current-epoch
    ///      vesting model (premium routes to vestingEpochPremium with
    ///       vestStart = max(existing, epochStart(now))):
    ///        Deposit of #2 at EPOCH_4 finalizes stream #1 → premium routed to
    ///        vestingEpochPremium with vestStart = EPOCH_4 (max of ended-epoch
    ///        EPOCH_3 and now-epoch EPOCH_4). The new stream #2 starts.
    ///        Sync at EPOCH_5: the inline stale-vesting sweep clears stream #1's
    ///        vesting slot (epochStart(EPOCH_5) > vestStart=EPOCH_4 → vest epoch
    ///        passed → premium fully realized into totalAssets, slot zeroed).
    ///        Stream #2 finalizes via the late path with vestStart = EPOCH_5
    ///        and stays unvested.
    ///
    ///      Net at EPOCH_5 sync: interest delta = 20e6 (stream #1 only),
    ///                          feeAssets = 25% * 20e6 = 5e6.
    ///
    ///      Why this differs from a 3-stream chain: the single-bucket model
    ///      realizes lender premium one epoch after settlement. A 3-stream
    ///      chain at EPOCH_5 would realize TWO premiums (40e6, fee=10e6).
    ///      Skipping the EPOCH_3 deposit keeps "exactly one fully-realized
    ///      premium at sync" — preserving the canonical 5e6 fee value all
    ///      downstream tests assert against — without changing the post-setup
    ///      timestamp (EPOCH_5).
    ///
    ///      The test must call `vault.sync()` at EPOCH_5 to observe the fee.
    function _twoEpochVestSetup() internal {
        _setFlatRatio(2000); // 20% lender, 80% borrower

        // 30% util
        _borrow(borrower, 3000e6);

        // Stream #1
        _depositRewards(borrower, 100e6);

        // Skip EPOCH_3 deposit (was stream #2 in the old 3-stream chain).

        // Stream #2 (was stream #3 in the old chain)
        vm.warp(EPOCH_4);
        _depositRewards(borrower, 100e6);

        // Advance into stream #2's vesting period; stream #1's premium fully realized
        // at the next sync.
        vm.warp(EPOCH_5);
    }

    /// @dev Same chain as `_twoEpochVestSetup` but ALSO triggers the fee-realizing sync
    ///      at EPOCH_5 so callers can examine the resulting fee shares directly.
    function _twoEpochVestSetupAndRealize() internal {
        _twoEpochVestSetup();
        vault.sync();
    }

    // =========================================================================
    // A. Setter access control + validation
    // =========================================================================

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_nonOwner_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(
            OwnableUpgradeable.OwnableUnauthorizedAccount.selector, borrower
        ));
        vault.setFeeRecipient(address(0xBEEF));
    }

    function test_setFeeRecipient_owner_succeedsAndEmits() public {
        address newRecipient = address(0xBEEF);
        vm.expectEmit(true, true, false, true, address(vault));
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        vm.prank(owner);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient);
    }

    function test_setFeeBps_aboveMax_reverts() public {
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.FeeBpsTooHigh.selector);
        vault.setFeeBps(5001);
    }

    function test_setFeeBps_zero_succeeds() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit FeeBpsUpdated(DEFAULT_FEE_BPS, 0);
        vm.prank(owner);
        vault.setFeeBps(0);
        assertEq(vault.feeBps(), 0);
    }

    function test_setFeeBps_atMax_succeeds() public {
        vm.prank(owner);
        vault.setFeeBps(5000);
        assertEq(vault.feeBps(), 5000);
    }

    function test_setFeeBps_nonOwner_reverts() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(
            OwnableUpgradeable.OwnableUnauthorizedAccount.selector, borrower
        ));
        vault.setFeeBps(1000);
    }

    // =========================================================================
    // B. Initialize validation
    // =========================================================================

    function test_initialize_zeroFeeRecipient_reverts() public {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "X", "X", address(portfolioFactory), 8000, address(0), uint256(0)
        );
        vm.expectRevert(DynamicFeesVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_feeBpsTooHigh_reverts() public {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "X", "X", address(portfolioFactory), 8000, feeRecipient, uint256(5001)
        );
        vm.expectRevert(DynamicFeesVault.FeeBpsTooHigh.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_lastTotalAssetsForFee_matchesTotalAssets_onFreshVault() public {
        // Fresh vault, no deposits — totalAssets and snapshot should both be 0.
        DynamicFeesVault freshVault = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );
        assertEq(freshVault.totalAssets(), 0);
        assertEq(freshVault.lastTotalAssetsForFee(), 0);
        assertEq(freshVault.lastTotalAssetsForFee(), freshVault.totalAssets());
    }

    // =========================================================================
    // C. Default-disabled state
    // =========================================================================

    function test_feeBpsZero_noFeeShares_noEvent() public {
        vm.prank(owner);
        vault.setFeeBps(0);

        _twoEpochVestSetupAndRealize();

        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares at feeBps=0");
    }

    // =========================================================================
    // D. Basic share-mint flow
    // =========================================================================

    /// @notice Regression guard: `depositRewards` must NOT count its own inflow as interest.
    ///
    /// History: an earlier version of `depositRewards` ran `safeTransferFrom` BEFORE
    /// `_settleRewards`, which inflated `totalAssets()` by the deposit amount during
    /// the subsequent `_accrueFee`, charging a 25% fee on the entire 100e6 inflow
    /// (~25e6) instead of on the realized lender premium (~5e6).
    ///
    /// The fix re-orders the call so `_settleRewards` runs before the transfer
    /// (mirroring repay / borrow / payFromPortfolio). After the fix, the realized
    /// fee for the canonical 3-stream / 100e6-each / 2000-bps-lender / 2500-bps-fee
    /// scenario is approximately 5e6 = 25% * 20e6 lender premium.
    ///
    /// Implementation reference: DynamicFeesVault.sol lines ~706-754.
    ///   `_settleRewards` runs before `safeTransferFrom`, so `_accrueFee` sees
    ///   pre-deposit `totalAssets()` and ignores the inflow. The bookkeeping
    ///   `totalUnsettledRewards += amount` is invariant-preserving since the
    ///   freshly transferred USDC is excluded from `totalAssets()` via the
    ///   `totalUnsettledRewards` subtraction term.
    function test_depositRewards_doesNotCountInflowAsInterest() public {
        _twoEpochVestSetupAndRealize();

        uint256 shares = vault.balanceOf(feeRecipient);
        uint256 feeAssetValue = vault.convertToAssets(shares);

        emit log_named_uint("Fee shares minted", shares);
        emit log_named_uint("Fee asset value", feeAssetValue);

        // Expected: 25% feeBps * 20e6 lender premium = 5e6.
        // Allow ±1% rounding from share-price math.
        assertApproxEqAbs(feeAssetValue, 5e6, 5e4,
            "feeAssetValue must be ~5e6 (25% of 20e6 lender premium), NOT ~25e6 (the historical bug)");

        // Hard upper bound that would have failed the buggy implementation.
        assertLt(feeAssetValue, 10e6,
            "regression guard: fee must NOT scale with the 100e6 inflow (would be ~25e6 under the bug)");
    }

    /// @notice The canonical fee scenario yields exactly 5e6 of fee asset value.
    function test_basicShareMintFlow_secondEpoch_mintsExpectedShares() public {
        _twoEpochVestSetupAndRealize();

        uint256 shares = vault.balanceOf(feeRecipient);
        assertGt(shares, 0, "fee shares should be minted by EPOCH_5 sync");

        uint256 feeAssetValue = vault.convertToAssets(shares);
        // Tight expected: 25% of 20e6 = 5e6 (within rounding).
        assertApproxEqAbs(feeAssetValue, 5e6, 5e4, "feeAssetValue ~= 5e6");
    }

    function test_basicShareMintFlow_emitsFeeAccrued() public {
        // The FeeAccrued event fires inside _accrueFee, which is called from
        // _processGlobalVesting at the EPOCH_5 sync.
        _twoEpochVestSetup();

        vm.recordLogs();
        vault.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("FeeAccrued(address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), feeRecipient);
                (uint256 feeAssets, uint256 feeShares) = abi.decode(logs[i].data, (uint256, uint256));
                // Exact: 25% * 20e6 = 5e6.
                assertApproxEqAbs(feeAssets, 5e6, 5e4, "feeAssets ~= 5e6");
                assertGt(feeShares, 0, "feeShares > 0");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeAccrued event should be emitted on EPOCH_5 sync");
    }

    // =========================================================================
    // E. Fee bps variants — separate functions per via-ir warning
    // =========================================================================

    function test_feeBpsVariant_0() public {
        _runFeeBpsVariant(0);
    }
    function test_feeBpsVariant_500() public {
        _runFeeBpsVariant(500);
    }
    function test_feeBpsVariant_2500() public {
        _runFeeBpsVariant(2500);
    }
    function test_feeBpsVariant_5000() public {
        _runFeeBpsVariant(5000);
    }

    function _runFeeBpsVariant(uint256 bps) internal {
        vm.prank(owner);
        vault.setFeeBps(bps);

        _twoEpochVestSetupAndRealize();

        uint256 shares = vault.balanceOf(feeRecipient);
        if (bps == 0) {
            assertEq(shares, 0, "no shares at 0 bps");
            return;
        }
        // For non-zero bps: shares should be > 0.
        assertGt(shares, 0, "fee shares > 0 for non-zero bps");
        uint256 feeAssetValue = vault.convertToAssets(shares);

        // Exact expected: bps * 20e6 / 10000 (interest = 20e6 lender premium).
        uint256 expected = (20e6 * bps) / 10000;
        // Allow ±1% rounding tolerance.
        uint256 tolerance = expected / 100 + 1;
        assertApproxEqAbs(feeAssetValue, expected, tolerance,
            "feeAssetValue must equal bps * 20e6 / 10000 within rounding");
    }

    // =========================================================================
    // F. Share price evolution
    // =========================================================================

    function test_totalAssetsInvariant_acrossSync() public {
        // _twoEpochVestSetup itself does not change totalAssets() — only the EPOCH_5 sync
        // does (when stream #1's premium fully vests). We test invariance across the
        // sync's _accrueFee step: totalAssets must be the same before and after the
        // share-mint, since minting shares doesn't add/remove assets.
        _twoEpochVestSetup();

        uint256 totalAssetsBefore = vault.totalAssets();
        vault.sync();
        uint256 totalAssetsAfter = vault.totalAssets();
        // Sync itself realizes 20e6 of premium; the snapshot move accounts for that.
        // Within the same block, _accrueFee mints shares without touching totalAssets,
        // so before/after match exactly.
        assertEq(totalAssetsBefore, totalAssetsAfter, "totalAssets must be invariant across _accrueFee");
    }

    function test_sharePriceDrops_whenFeeMintsShares() public {
        // Use a large share quantum so the price difference is observable above rounding.
        uint256 quantum = 1e15;
        uint256 priceBefore = vault.convertToAssets(quantum);

        // Run the chained vesting setup and realize the fee at EPOCH_5.
        _twoEpochVestSetupAndRealize();

        // At least some fee shares should have been minted.
        assertGt(vault.balanceOf(feeRecipient), 0, "shares minted");

        uint256 priceAfter = vault.convertToAssets(quantum);

        // Concretely: compute what price WOULD have been with no fee shares minted.
        // priceNoFee = totalAssets / (totalSupply - feeShares). This must be > priceAfter.
        uint256 ta = vault.totalAssets();
        uint256 ts = vault.totalSupply();
        uint256 feeShares = vault.balanceOf(feeRecipient);
        assertGt(feeShares, 0, "feeShares > 0");
        assertGt(ts, feeShares, "totalSupply > feeShares");

        uint256 priceNoFee = ta * quantum / ((ts - feeShares) + (10 ** 6));
        uint256 priceWithFee = ta * quantum / (ts + (10 ** 6));
        assertLt(priceWithFee, priceNoFee, "share price strictly diluted by fee shares");

        // priceAfter should reflect the fee-diluted price, which is strictly less than the
        // pre-realization no-interest baseline once we add the realized interest:
        // before any premium realizes, totalAssets is unchanged across the chain, so the
        // no-fee price would only drift up if interest accrues. With 5e6 of interest
        // captured by feeRecipient as shares, LP price drifts up LESS than it would have.
        assertGt(priceAfter, priceBefore, "share price rises with realized interest, even net of fee");
    }

    function test_sharePriceInvariant_whenFeeBpsZero() public {
        vm.prank(owner);
        vault.setFeeBps(0);

        // Same chained-stream setup. With feeBps=0 no shares are minted, so totalSupply
        // is invariant across syncs. Any share price change comes from totalAssets
        // changes (i.e., realized premium).
        uint256 supplyBefore = vault.totalSupply();
        _twoEpochVestSetupAndRealize();
        uint256 supplyAfter = vault.totalSupply();
        assertEq(supplyAfter, supplyBefore, "totalSupply invariant when feeBps=0 (no fee shares)");
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares at feeBps=0");
    }

    // =========================================================================
    // G. All state-changing paths trigger accrual
    // =========================================================================

    function test_feeAccruesOnEveryPath() public {
        _setFlatRatio(2000);

        // Borrow path triggers _settleRewards/_processGlobalVesting → _accrueFee
        // (but with no stream, _processGlobalVesting exits early, so no _accrueFee here yet).
        _borrow(borrower, 3000e6);
        uint256 s0 = vault.balanceOf(feeRecipient);

        // Stream #1
        _depositRewards(borrower, 100e6);
        uint256 s1 = vault.balanceOf(feeRecipient);
        assertGe(s1, s0, "depositRewards #1 path: non-decreasing");

        // Stream #2 — _processGlobalVesting runs, _accrueFee runs but Δ=0 (premium not yet realized).
        vm.warp(EPOCH_3);
        _depositRewards(borrower, 100e6);
        uint256 s2 = vault.balanceOf(feeRecipient);
        assertGe(s2, s1, "depositRewards #2 path: non-decreasing");

        // Stream #3
        vm.warp(EPOCH_4);
        _depositRewards(borrower, 100e6);
        uint256 s3 = vault.balanceOf(feeRecipient);
        assertGe(s3, s2, "depositRewards #3 path: non-decreasing");

        // EPOCH_5: stream #3 vests AND stream #1's premium fully realizes → first non-zero accrual.
        vm.warp(EPOCH_5);

        // Stream #4 to keep activeEpochRate non-zero across subsequent paths
        _depositRewards(borrower, 100e6);
        uint256 s4 = vault.balanceOf(feeRecipient);
        assertGt(s4, s3, "depositRewards #4 path (EPOCH_5): fee actually accrues");

        // payFromPortfolio path
        vm.warp(EPOCH_6);
        vm.startPrank(borrower);
        usdc.mint(borrower, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.payFromPortfolio(50e6, 0);
        vm.stopPrank();
        uint256 s5 = vault.balanceOf(feeRecipient);
        assertGt(s5, s4, "payFromPortfolio path (EPOCH_6, stream #2 premium realizes): fee accrues");

        // Need active stream for subsequent _accrueFee paths
        _depositRewards(borrower, 100e6);
        uint256 s5b = vault.balanceOf(feeRecipient);
        assertGe(s5b, s5, "depositRewards #5: non-decreasing");

        // repay path
        vm.warp(EPOCH_7);
        vm.startPrank(borrower);
        usdc.mint(borrower, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repay(50e6);
        vm.stopPrank();
        uint256 s6 = vault.balanceOf(feeRecipient);
        assertGt(s6, s5b, "repay path: fee accrues");

        // _deposit path (LP) — must NOT mint fee shares (snapshot bumped by deposit).
        // Need an active stream first.
        _depositRewards(borrower, 100e6);
        uint256 s6b = vault.balanceOf(feeRecipient);
        assertGe(s6b, s6, "depositRewards #6: non-decreasing");

        // Roll a block for the deposit/withdraw flow.
        usdc.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, lender);
        vm.stopPrank();
        uint256 s7 = vault.balanceOf(feeRecipient);
        assertEq(s7, s6b, "_deposit path: must NOT mint fee shares (snapshot bumped)");

        // Roll forward so withdraw is allowed.
        vm.roll(100);

        // _withdraw path — must NOT mint fee shares.
        vm.prank(lender);
        vault.withdraw(100e6, lender, lender);
        uint256 s8 = vault.balanceOf(feeRecipient);
        assertEq(s8, s7, "_withdraw path: must NOT mint fee shares (snapshot bumped)");

        // settleRewards path — _processGlobalVesting runs and may accrue if delta > 0.
        vault.settleRewards(borrower);
        uint256 s9 = vault.balanceOf(feeRecipient);
        assertGe(s9, s8, "settleRewards path: non-decreasing");

        // Total accumulated > 0 (proven by post-EPOCH_5 steps).
        assertGt(s9, 0, "fee shares accumulated over the sequence");
    }

    // =========================================================================
    // H. Borrower credit invariance — fee mechanism must NOT touch borrower
    //     economics. This is the critical correctness property.
    // =========================================================================

    function test_borrowerCreditInvariant_feeBpsZero_vs_active() public {
        // Run the same script in two parallel vaults, compare borrower-side state.
        DynamicFeesVault vaultA = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, 0
        );
        DynamicFeesVault vaultB = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );

        // Use a flat ratio in both
        FlatFeeCalculator fc = new FlatFeeCalculator(2000);
        vm.startPrank(owner);
        vaultA.setFeeCalculator(address(fc));
        vaultB.setFeeCalculator(address(fc));
        vm.stopPrank();

        // Seed both
        usdc.mint(address(this), 2 * SEED);
        usdc.approve(address(vaultA), SEED);
        usdc.approve(address(vaultB), SEED);
        vaultA.deposit(SEED, address(this));
        vaultB.deposit(SEED, address(this));

        address bA = address(0xAA);
        address bB = address(0xBB);

        // Borrow
        vm.prank(bA); vaultA.borrowFromPortfolio(3000e6);
        vm.prank(bB); vaultB.borrowFromPortfolio(3000e6);

        // First reward epoch
        usdc.mint(bA, 100e6);
        vm.startPrank(bA);
        usdc.approve(address(vaultA), 100e6);
        vaultA.depositRewards(100e6);
        vm.stopPrank();

        usdc.mint(bB, 100e6);
        vm.startPrank(bB);
        usdc.approve(address(vaultB), 100e6);
        vaultB.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_3);
        vaultA.sync();
        vaultB.sync();

        // Second reward epoch
        usdc.mint(bA, 100e6);
        vm.startPrank(bA);
        usdc.approve(address(vaultA), 100e6);
        vaultA.depositRewards(100e6);
        vm.stopPrank();

        usdc.mint(bB, 100e6);
        vm.startPrank(bB);
        usdc.approve(address(vaultB), 100e6);
        vaultB.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_4);
        vaultA.settleRewards(bA);
        vaultB.settleRewards(bB);

        // Borrower-side state must match exactly.
        assertEq(vaultA.getDebtBalance(bA), vaultB.getDebtBalance(bB), "debtBalance must match");
        assertEq(
            vaultA.getGlobalBorrowerPending(),
            vaultB.getGlobalBorrowerPending(),
            "globalBorrowerPending must match"
        );
        assertEq(
            vaultA.getEffectiveDebtBalance(bA),
            vaultB.getEffectiveDebtBalance(bB),
            "getEffectiveDebtBalance must match"
        );
    }

    // =========================================================================
    // I. getEffectiveDebtBalance consistency after settle
    // =========================================================================

    function test_getEffectiveDebtBalance_equalsDebtBalance_afterSettle() public {
        _twoEpochVestSetup();
        vault.settleRewards(borrower);
        assertEq(
            vault.getEffectiveDebtBalance(borrower),
            vault.getDebtBalance(borrower),
            "after _settleRewards, effective == stored"
        );
    }

    // =========================================================================
    // J. LP deposit/withdraw don't count as interest (snapshot bumps)
    // =========================================================================

    function test_lpDeposit_doesNotMintFeeShares() public {
        // Get to EPOCH_5 with realized fee accrued.
        _twoEpochVestSetupAndRealize();
        uint256 sharesAfterRealize = vault.balanceOf(feeRecipient);
        assertGt(sharesAfterRealize, 0, "fee accrued at EPOCH_5 sync");

        // Now LP deposits MORE — should NOT mint fee shares (because lastTotalAssetsForFee
        // is bumped by the deposit amount).
        usdc.mint(lender, 5_000e6);
        vm.startPrank(lender);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, lender);
        vm.stopPrank();

        assertEq(
            vault.balanceOf(feeRecipient),
            sharesAfterRealize,
            "LP deposit must NOT mint fee shares"
        );
    }

    function test_lpWithdraw_doesNotMintFeeShares_andDoesNotUnderflow() public {
        // First, deposit a buffer LP so we can later withdraw
        usdc.mint(lender, 2_000e6);
        vm.startPrank(lender);
        usdc.approve(address(vault), 2_000e6);
        vault.deposit(2_000e6, lender);
        vm.stopPrank();

        _twoEpochVestSetupAndRealize();
        uint256 sharesBeforeWithdraw = vault.balanceOf(feeRecipient);
        assertGt(sharesBeforeWithdraw, 0, "fee accrued at EPOCH_5 sync");

        // Roll a block so lastDepositBlock guard releases
        vm.roll(block.number + 5);

        // LP withdraws — must not mint fee shares, must not underflow.
        vm.prank(lender);
        vault.withdraw(500e6, lender, lender);

        assertEq(
            vault.balanceOf(feeRecipient),
            sharesBeforeWithdraw,
            "LP withdraw must NOT mint fee shares"
        );

        // Sanity: subsequent state-changing call doesn't revert (zero-floor in snapshot is safe).
        vm.roll(block.number + 5);
        vault.sync();
    }

    // =========================================================================
    // K. Edge: feeAssets == 0 from rounding
    // =========================================================================

    function test_tinyDonation_roundsToZeroFeeShares() public {
        // We need _accrueFee to actually run. _processGlobalVesting calls it
        // unconditionally at the end of each invocation. We exercise the dust
        // path: a small donation creates totalAssets growth that, at 25% bps,
        // rounds to zero fee assets — exactly the leak case the fix addresses.

        _setFlatRatio(2000);
        _borrow(borrower, 3000e6);
        _depositRewards(borrower, 100e6);

        // Snapshot the state BEFORE the dust donation. The borrow + depositRewards
        // paths are invariant for totalAssets (each deduction term offsets the
        // balance change), so under the post-fix early-return, the snapshot has
        // remained pinned to the setUp-deposit value (SEED).
        uint256 lastBefore = vault.lastTotalAssetsForFee();
        uint256 sharesBefore = vault.balanceOf(feeRecipient);

        vm.warp(EPOCH_3);

        // Donate 3 wei. (3 * 2500) / 10000 == 0 → feeShares = 0 path in
        // _accrueFeeView.
        usdc.mint(address(vault), 3);

        // Pre-sync sanity: a 3-wei delta is well below the 4-wei threshold for
        // a single fee asset at 25% bps. This is the exact rounding-to-zero
        // scenario the production fix protects against.
        assertEq((3 * uint256(2500)) / 10000, 0, "math sanity: 3 wei * 25% rounds to 0");

        vault.sync();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        uint256 lastAfter = vault.lastTotalAssetsForFee();

        // POST-FIX assertions (would FAIL on the un-fixed code):
        //   - Pre-fix: snapshot advanced unconditionally. `lastAfter > lastBefore`.
        //   - Post-fix: feeShares == 0 → early-return → snapshot frozen.
        assertEq(
            lastAfter, lastBefore,
            "snapshot MUST be frozen when feeShares == 0 (pre-fix would advance to SEED+3)"
        );
        // Fee shares unchanged — the 3-wei dust silently leaked to LPs pre-fix
        // (snapshot was advanced, the delta consumed without minting). Post-fix,
        // the dust is preserved as a pending delta; on a future call where
        // cumulative growth crosses the fee threshold, it will mint.
        assertEq(
            sharesAfter, sharesBefore,
            "no fee shares minted on dust donation"
        );
    }

    // =========================================================================
    // L. Empty vault first accrual is zero
    // =========================================================================

    function test_emptyVault_firstAccrual_isZero() public {
        DynamicFeesVault freshVault = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );

        vm.recordLogs();
        freshVault.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 feeTopic = keccak256("FeeAccrued(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != feeTopic, "no FeeAccrued on empty vault sync");
        }

        assertEq(freshVault.balanceOf(feeRecipient), 0);
        assertEq(freshVault.lastTotalAssetsForFee(), 0);
    }

    // =========================================================================
    // M. Recipient blacklist does NOT halt vault (the BIG behavioral change)
    // =========================================================================

    function test_blacklistedFeeRecipient_doesNotHaltVault() public {
        // Deploy a separate vault that uses MockBlacklistableERC20 so we can blacklist.
        MockBlacklistableERC20 bAsset = new MockBlacklistableERC20("bUSDC", "bUSDC", 6);
        DynamicFeesVault bVault = _deployVault(
            address(bAsset), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );

        bAsset.mint(address(this), SEED);
        bAsset.approve(address(bVault), SEED);
        bVault.deposit(SEED, address(this));

        FlatFeeCalculator fc = new FlatFeeCalculator(2000);
        vm.prank(owner);
        bVault.setFeeCalculator(address(fc));

        // Blacklist the fee recipient BEFORE any operations.
        bAsset.setBlacklisted(feeRecipient, true);

        // borrow
        vm.prank(borrower);
        bVault.borrowFromPortfolio(3000e6);

        // Stream #1 (EPOCH_2 → EPOCH_3)
        bAsset.mint(borrower, 100e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 100e6);
        bVault.depositRewards(100e6);
        vm.stopPrank();

        // Skip the EPOCH_3 deposit. Under the single-bucket current-epoch
        // vesting model, late settlement routes premium directly into
        // vestingEpochPremium, so a 3-stream chain at EPOCH_5 would realize
        // TWO premiums (~10e6 fee). Mirror _twoEpochVestSetup: only deposit
        // again at EPOCH_4 so exactly one stream's premium is fully realized
        // at the EPOCH_5 sync.
        vm.warp(EPOCH_4);

        // Stream #2 (EPOCH_4 → EPOCH_5)
        bAsset.mint(borrower, 100e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 100e6);
        bVault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_5);

        // Sync triggers fee accrual to blacklisted recipient. Must NOT revert (share-mint is internal).
        bVault.sync();

        uint256 sharesAfterAccrual = bVault.balanceOf(feeRecipient);
        assertGt(sharesAfterAccrual, 0, "recipient accumulates shares despite blacklist");

        // Tight bound: fee = 25% * 20e6 = 5e6.
        uint256 feeValue = bVault.convertToAssets(sharesAfterAccrual);
        assertApproxEqAbs(feeValue, 5e6, 5e4, "feeValue ~= 5e6");

        // Continue with other paths to verify they all succeed.
        bVault.settleRewards(borrower);

        // repay
        bAsset.mint(borrower, 50e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 50e6);
        bVault.repay(50e6);
        vm.stopPrank();

        // payFromPortfolio
        bAsset.mint(borrower, 50e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 50e6);
        bVault.payFromPortfolio(50e6, 0);
        vm.stopPrank();

        // LP deposit
        bAsset.mint(lender, 100e6);
        vm.startPrank(lender);
        bAsset.approve(address(bVault), 100e6);
        bVault.deposit(100e6, lender);
        vm.stopPrank();

        vm.roll(block.number + 5);

        // LP withdraw
        vm.prank(lender);
        bVault.withdraw(50e6, lender, lender);

        // Recipient's share balance is preserved (no operations transferred USDC to it).
        assertGe(bVault.balanceOf(feeRecipient), sharesAfterAccrual, "recipient shares preserved through paths");
    }

    function test_blacklistedFeeRecipient_redeem_reverts() public {
        MockBlacklistableERC20 bAsset = new MockBlacklistableERC20("bUSDC", "bUSDC", 6);
        DynamicFeesVault bVault = _deployVault(
            address(bAsset), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS
        );

        bAsset.mint(address(this), SEED);
        bAsset.approve(address(bVault), SEED);
        bVault.deposit(SEED, address(this));

        FlatFeeCalculator fc = new FlatFeeCalculator(2000);
        vm.prank(owner);
        bVault.setFeeCalculator(address(fc));

        // Accumulate fee shares (recipient NOT yet blacklisted).
        vm.prank(borrower);
        bVault.borrowFromPortfolio(3000e6);

        // Stream #1
        bAsset.mint(borrower, 100e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 100e6);
        bVault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_3);
        // Stream #2
        bAsset.mint(borrower, 100e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 100e6);
        bVault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_4);
        // Stream #3
        bAsset.mint(borrower, 100e6);
        vm.startPrank(borrower);
        bAsset.approve(address(bVault), 100e6);
        bVault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_5);
        bVault.sync();

        uint256 shares = bVault.balanceOf(feeRecipient);
        assertGt(shares, 0);

        // Now blacklist and try to redeem.
        bAsset.setBlacklisted(feeRecipient, true);

        vm.roll(block.number + 5);
        vm.prank(feeRecipient);
        vm.expectRevert(); // safeTransfer to blacklisted recipient reverts
        bVault.redeem(shares, feeRecipient, feeRecipient);
    }

    // =========================================================================
    // N. Recipient rotation
    // =========================================================================

    function test_recipientRotation_freezesPriorRecipient() public {
        address recipientA = feeRecipient;
        address recipientB = address(0xB0B);

        // Accumulate fee shares to A
        _twoEpochVestSetupAndRealize();
        uint256 aShares1 = vault.balanceOf(recipientA);
        assertGt(aShares1, 0);

        // Tight: 5e6 of asset value.
        assertApproxEqAbs(vault.convertToAssets(aShares1), 5e6, 5e4, "A first accrual ~= 5e6");

        // Rotate to B
        vm.prank(owner);
        vault.setFeeRecipient(recipientB);

        // Stream #4 to keep activeEpochRate non-zero, then warp two more epochs
        // so stream #2's lender premium fully realizes for B.
        _depositRewards(borrower, 100e6); // Stream #4 at EPOCH_5
        vm.warp(EPOCH_6);
        _depositRewards(borrower, 100e6); // Stream #5 at EPOCH_6
        vm.warp(EPOCH_7);
        vault.sync();

        // A's balance frozen
        assertEq(vault.balanceOf(recipientA), aShares1, "A frozen after rotation");
        // B grew
        uint256 bShares = vault.balanceOf(recipientB);
        assertGt(bShares, 0, "B accumulates");

        // A can still redeem
        vm.roll(block.number + 5);
        vm.prank(recipientA);
        vault.redeem(aShares1, recipientA, recipientA);
        assertGt(usdc.balanceOf(recipientA), 0, "A successfully redeemed");
    }

    // =========================================================================
    // O. Fee bps mid-stream
    // =========================================================================

    function test_feeBps_midStreamUpdate_appliesGoingForward() public {
        // Accrue at 25%
        _twoEpochVestSetupAndRealize();
        uint256 sharesAt25 = vault.balanceOf(feeRecipient);
        assertGt(sharesAt25, 0);
        // Tight: ~5e6
        uint256 valueAt25 = vault.convertToAssets(sharesAt25);
        assertApproxEqAbs(valueAt25, 5e6, 5e4, "first accrual at 25% bps ~= 5e6");

        // Drop to 10%
        vm.prank(owner);
        vault.setFeeBps(1000);

        // Continue stream chain: stream #4 at EPOCH_5, #5 at EPOCH_6, sync at EPOCH_7.
        _depositRewards(borrower, 100e6);
        vm.warp(EPOCH_6);
        _depositRewards(borrower, 100e6);
        vm.warp(EPOCH_7);
        vault.sync();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        uint256 sharesGainedAt10 = sharesAfter - sharesAt25;
        uint256 valueGainedAt10 = vault.convertToAssets(sharesGainedAt10);

        // After rotation, two more lender premiums fully realize:
        //   - stream #2's 20e6 (vesting cleared at EPOCH_6 sync triggered by stream #5 deposit)
        //   - stream #3's 20e6 (vesting cleared at EPOCH_7 sync)
        // Total realized interest at 10% bps = 40e6 * 10% = 4e6.
        assertGt(sharesGainedAt10, 0);
        assertApproxEqAbs(valueGainedAt10, 4e6, 1e5,
            "at 10% bps the post-rotation accrual is ~4e6 (10% * 40e6 across two realizations)");
        // Verify the bps math: gainedAt10 / valueAt25 ≈ (2 * 0.10) / 0.25 = 0.8.
        // So at 10% bps with 2 realizations, the gain is LESS than the first single realization at 25%.
        assertLt(valueGainedAt10, valueAt25, "10% * 2 realizations < 25% * 1 realization");
    }

    // =========================================================================
    // P. pendingFeeShares() view consistency
    // =========================================================================

    function test_pendingFeeShares_matchesNextAccrual() public {
        _twoEpochVestSetup();

        uint256 pending = vault.pendingFeeShares();
        uint256 sharesBefore = vault.balanceOf(feeRecipient);

        vault.sync();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        assertEq(sharesAfter - sharesBefore, pending, "pendingFeeShares == minted shares");
        assertGt(pending, 0, "pendingFeeShares > 0 at EPOCH_5 (fee about to accrue)");
    }

    function test_pendingFeeShares_zeroWhenNoInterest() public {
        // Fresh from setUp, no rewards deposited yet.
        assertEq(vault.pendingFeeShares(), 0, "no pending fee shares without interest");
    }

    // =========================================================================
    // Q. Preview function fairness
    // =========================================================================

    function test_previewDeposit_matchesActualDeposit_withPendingInterest() public {
        _twoEpochVestSetup();

        address depositor = address(0xD3);
        uint256 amount = 1000e6;
        usdc.mint(depositor, amount);

        uint256 quoted = vault.previewDeposit(amount);

        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        uint256 actualShares = vault.deposit(amount, depositor);
        vm.stopPrank();

        assertEq(actualShares, vault.balanceOf(depositor), "shares minted matches return value");
        assertEq(quoted, actualShares, "previewDeposit must match actual deposit");
    }

    function test_previewMint_matchesActualMint_withPendingInterest() public {
        _twoEpochVestSetup();

        address depositor = address(0xD4);
        uint256 sharesWanted = 500e6;
        uint256 quotedAssetsIn = vault.previewMint(sharesWanted);

        usdc.mint(depositor, quotedAssetsIn);
        vm.startPrank(depositor);
        usdc.approve(address(vault), quotedAssetsIn);
        uint256 actualAssetsIn = vault.mint(sharesWanted, depositor);
        vm.stopPrank();

        assertEq(quotedAssetsIn, actualAssetsIn, "previewMint must match actual mint");
        assertEq(vault.balanceOf(depositor), sharesWanted, "got the requested shares");
    }

    function test_previewWithdraw_matchesActualWithdraw_withPendingInterest() public {
        _twoEpochVestSetup();

        // The test contract is the LP from setUp — has shares.
        // Roll a block to release the lastDepositBlock guard (setUp deposited at block N).
        vm.roll(block.number + 5);

        uint256 amount = 500e6;
        uint256 quotedSharesBurned = vault.previewWithdraw(amount);

        uint256 sharesBefore = vault.balanceOf(address(this));
        vault.withdraw(amount, address(this), address(this));
        uint256 sharesBurned = sharesBefore - vault.balanceOf(address(this));

        assertEq(quotedSharesBurned, sharesBurned, "previewWithdraw matches actual shares burned");
    }

    function test_previewRedeem_matchesActualRedeem_withPendingInterest() public {
        _twoEpochVestSetup();

        vm.roll(block.number + 5);

        uint256 sharesToRedeem = 500e6;
        uint256 quotedAssets = vault.previewRedeem(sharesToRedeem);

        uint256 assetsBefore = usdc.balanceOf(address(this));
        vault.redeem(sharesToRedeem, address(this), address(this));
        uint256 assetsReceived = usdc.balanceOf(address(this)) - assetsBefore;

        assertEq(quotedAssets, assetsReceived, "previewRedeem matches actual assets received");
    }

    // =========================================================================
    // R. Redemption flow
    // =========================================================================

    function test_redeem_recipient_receivesCorrectAssets() public {
        _twoEpochVestSetupAndRealize();
        uint256 shares = vault.balanceOf(feeRecipient);
        assertGt(shares, 0);

        uint256 quoted = vault.previewRedeem(shares);

        vm.roll(block.number + 5);
        vm.prank(feeRecipient);
        uint256 received = vault.redeem(shares, feeRecipient, feeRecipient);

        assertEq(received, quoted, "redeemed assets match preview");
        assertEq(usdc.balanceOf(feeRecipient), received, "recipient received USDC");
        assertEq(vault.balanceOf(feeRecipient), 0, "recipient shares zeroed");
    }

    /// @notice EIP-4626 compliance: previewRedeem MUST NOT revert on values the
    ///         vault cannot satisfy — it returns the unconstrained quote — while
    ///         the actual redeem call still reverts when there isn't enough liquidity.
    ///
    /// The legacy implementation guarded both `previewRedeem` and `previewWithdraw`
    /// with `require(assets <= liquid, "Insufficient liquidity")`. EIP-4626 requires
    /// the preview functions to be revert-free quotes; only the state-changing
    /// `redeem`/`withdraw` paths may revert. The guards were removed; the
    /// underlying `safeTransfer` in `_withdraw` enforces liquidity instead.
    function test_redeem_revertsWhenInsufficientLiquidity_butPreviewDoesNot() public {
        // 1) previewRedeem on a clearly unsatisfiable value MUST NOT revert.
        //    It returns the asset-equivalent of `type(uint128).max` shares per the
        //    EIP-4626 share-price math, regardless of vault liquidity.
        uint256 quoted = vault.previewRedeem(type(uint128).max);
        assertGt(quoted, 0, "previewRedeem must return a non-zero quote (no revert) on unsatisfiable input");

        // 2) The ACTUAL redeem call still reverts. The test contract owns SEED
        //    shares from setUp — far less than `type(uint128).max` — so the
        //    burn step trips ERC20's insufficient-balance check before the
        //    transfer is even attempted. Either way, the call MUST revert.
        vm.roll(block.number + 5); // release lastDepositBlock guard
        vm.expectRevert();
        vault.redeem(type(uint128).max, address(this), address(this));
    }

    /// @notice Same split-assertion pattern for a real liquidity shortfall:
    ///         previewWithdraw must quote, withdraw must revert.
    function test_redeem_revertsWhenLiquidityShortfall_butPreviewDoesNot() public {
        // Reduce vault liquidity by borrowing.
        // setUp seeded SEED = 10_000e6. After 3000e6 borrow, liquid = 7000e6.
        // The test contract holds shares worth ~SEED, so a 8000e6 withdraw is
        // representable in shares (preview returns a valid number) but cannot
        // be satisfied by the vault's USDC balance.
        _borrow(borrower, 3000e6);

        uint256 liquid = usdc.balanceOf(address(vault));
        uint256 shortfallAmount = liquid + 1_000e6; // 8000e6 — exceeds liquidity, < user's share value
        assertGt(shortfallAmount, liquid, "scenario sanity: requested amount exceeds liquid balance");

        // Confirm the test contract really can cover this in share terms (so the
        // failure is liquidity, not share-balance).
        uint256 ownerAssets = vault.convertToAssets(vault.balanceOf(address(this)));
        assertGe(ownerAssets, shortfallAmount, "scenario sanity: caller has enough share value");

        // 1) previewWithdraw MUST NOT revert even though the vault can't pay.
        uint256 sharesQuoted = vault.previewWithdraw(shortfallAmount);
        assertGt(sharesQuoted, 0, "previewWithdraw must return a non-zero quote (no revert) on shortfall");

        // 2) previewRedeem on the share-quote also doesn't revert.
        uint256 assetsQuoted = vault.previewRedeem(sharesQuoted);
        assertGt(assetsQuoted, 0, "previewRedeem must return a non-zero quote (no revert)");

        // 3) The ACTUAL withdraw call reverts. The revert comes from SafeERC20's
        //    transfer failing when the vault's USDC balance < requested amount.
        //    No specific selector — MockUSDC reverts via OZ's ERC20InsufficientBalance
        //    error (custom error). vm.expectRevert() with no argument matches any revert.
        vm.roll(block.number + 5); // release lastDepositBlock guard
        vm.expectRevert();
        vault.withdraw(shortfallAmount, address(this), address(this));
    }

    // =========================================================================
    // S. Events: FeeAccrued argument correctness
    // =========================================================================

    function test_feeAccrued_eventArguments() public {
        // Reproduce the conditions where _accrueFee fires (EPOCH_5 sync of canonical chain).
        _twoEpochVestSetup();

        uint256 sharesBefore = vault.balanceOf(feeRecipient);

        vm.recordLogs();
        vault.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 sharesAfter = vault.balanceOf(feeRecipient);
        uint256 sharesDelta = sharesAfter - sharesBefore;

        bytes32 topic = keccak256("FeeAccrued(address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                address evRecipient = address(uint160(uint256(logs[i].topics[1])));
                (uint256 evFeeAssets, uint256 evFeeShares) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(evRecipient, feeRecipient, "topic1 = recipient");
                // Tight: 25% * 20e6 = 5e6.
                assertApproxEqAbs(evFeeAssets, 5e6, 5e4, "evFeeAssets ~= 5e6");
                assertGt(evFeeShares, 0, "feeShares > 0");
                assertEq(evFeeShares, sharesDelta, "feeShares matches recipient delta");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeAccrued event must emit");
    }
}
