// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// DynamicFeesVault.incentivize(uint256) — Mode 1 hardening tests
// ============================================================================
//
// Function under test: DynamicFeesVault.sol lines ~747-769
//
//   function incentivize(uint256 amount) external nonReentrant {
//       if (amount == 0) revert ZeroAmount();
//       _processGlobalVesting();
//       safeTransferFrom(msg.sender -> vault, amount);
//       if (vestingEpochStart > 0 && nowEpoch > vestingEpochStart) sweep stale bucket
//       vestingEpochPremium += amount;
//       if (vestingEpochStart < nowEpoch) vestingEpochStart = nowEpoch;
//       emit Incentivized(...)
//   }
//
// Key behavioral properties under test:
//   1. Permissionless (any EOA, including non-portfolio).
//   2. Always callable (NOT gated by `whenNotPaused`).
//   3. Reverts on zero amount with `ZeroAmount()`.
//   4. Reverts on reentrancy via `nonReentrant`.
//   5. Routes 100% of `amount` into `vestingEpochPremium` for current epoch.
//   6. Linearly vests over the current epoch into `totalAssets()`.
//   7. Mid-epoch top-ups stack additively (already-vested portion of prior
//      contribution stays realized; new amount adds to the bucket).
//   8. Stale-bucket sweep on epoch rollover.
//   9. Coexists with concurrent borrower-stream rewards (no double-counting,
//      no underflow).
//  10. Avoids the two-epoch lag that affects stream-derived premium under late
//      `_processGlobalVesting` settlement (regression guard).
//  11. Performance fee path activates on incentive-derived growth.
//  12. Donation-attack resistance via virtual-shares decimal offset.
//  13. `Incentivized` event arguments correct.
//  14. Transient totalAssets monotonicity across the safeTransferFrom hook
//      (pre-write transfer — tests guard against future write reordering).
//
// Findings surfaced during test authoring (non-blocking, see report-back):
//   - None of the 13 scenarios required scaffolding beyond what the existing
//     Treasury test file already establishes (MockUSDC, MockPortfolioFactoryFee,
//     FlatFeeCalculator). The hook-token mock is local to this file.
// ============================================================================

import {Test, Vm} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

// ============ Mocks (local) ============

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryIncentivize is IPortfolioFactory {
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

/// @dev USDC-decimal mock that re-enters the vault mid-`transferFrom`. Single-shot.
///      Used for two purposes:
///        1) Reentrancy assertion: armed with calldata that invokes a
///           `nonReentrant` vault entrypoint; expects the inner call to revert.
///        2) Transient totalAssets monotonicity: armed with calldata that
///           records `totalAssets()` mid-transfer (pre-write).
contract HookUSDC is ERC20 {
    address public hookTarget;
    bytes public hookCalldata;
    bool public armedOnce;
    bool public lastInnerOk;
    bytes public lastInnerReturn;

    constructor() ERC20("Hook USDC", "hUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function arm(address target, bytes calldata data) external {
        hookTarget = target;
        hookCalldata = data;
        armedOnce = true;
        lastInnerOk = false;
        lastInnerReturn = "";
    }

    /// @dev Two flavors:
    ///       - propagateRevert == true: bubble up inner revert (reentrancy test).
    ///       - propagateRevert == false: swallow inner revert, store outcome
    ///         (monotonicity test — staticcall to view fns shouldn't revert anyway).
    bool public propagateRevert = true;
    function setPropagateRevert(bool v) external { propagateRevert = v; }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armedOnce && hookTarget != address(0)) {
            armedOnce = false;
            (bool ok, bytes memory ret) = hookTarget.call(hookCalldata);
            lastInnerOk = ok;
            lastInnerReturn = ret;
            if (!ok && propagateRevert) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

// ============================================================================
// Test contract
// ============================================================================

contract DynamicFeesVaultIncentivizeTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryIncentivize public portfolioFactory;

    address public owner;
    address public lender;
    address public borrower;
    address public randomEoa;
    address public feeRecipient;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // Hardcoded absolute timestamps from setUp warp (avoid via-ir caching).
    uint256 constant EPOCH_2 = 2 * WEEK; // setUp time
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    uint256 constant SEED = 10_000e6;
    uint256 constant DEFAULT_FEE_BPS = 0; // disable perf fee by default; tests opt in

    // Re-declare event for vm.expectEmit
    event Incentivized(address indexed from, uint256 amount, uint256 epoch);
    event FeeAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares);

    // ============ setUp ============

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        lender = address(0x10);
        borrower = address(0x20);
        randomEoa = address(0xEEE);
        feeRecipient = address(0xFEE);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryIncentivize();
        portfolioFactory.setPortfolio(borrower, true);

        vault = _deployVault(address(usdc), address(portfolioFactory), feeRecipient, DEFAULT_FEE_BPS);

        // Initial LP seed (test contract acts as LP).
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
            asset_, "Vault", "vUSDC", pf, 8000, recip, _feeBps
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
    }

    function _setFlatRatio(DynamicFeesVault v, uint256 ratioBps) internal {
        FlatFeeCalculator fc = new FlatFeeCalculator(ratioBps);
        vm.prank(owner);
        v.setFeeCalculator(address(fc));
    }

    function _doIncentivize(address from, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(vault), amount);
        vault.incentivize(amount);
        vm.stopPrank();
    }

    // =========================================================================
    // 1. Zero amount reverts
    // =========================================================================

    function test_incentivize_zeroAmount_reverts() public {
        vm.prank(randomEoa);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.incentivize(0);
    }

    // =========================================================================
    // 7. Permissionless caller (non-portfolio EOA)
    // =========================================================================

    function test_incentivize_permissionlessCaller_succeeds() public {
        assertFalse(portfolioFactory.isPortfolio(randomEoa), "preconditon: caller is NOT a portfolio");
        _doIncentivize(randomEoa, 50e6);
        // Bucket populated for the current epoch.
        assertEq(vault.getUnvestedLenderPremium(), 50e6, "full incentive unvested at vest start");
    }

    // =========================================================================
    // 8. Always callable — pause does NOT block
    // =========================================================================

    function test_incentivize_whenPaused_stillSucceeds() public {
        // owner pauses
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "pre: vault paused");

        // EOA can still incentivize (no ContractPaused revert)
        _doIncentivize(randomEoa, 25e6);
        assertEq(vault.getUnvestedLenderPremium(), 25e6, "incentive lands while paused");
    }

    // =========================================================================
    // 11. Incentivized event arguments
    // =========================================================================

    function test_incentivize_emitsEvent_withCorrectArgs() public {
        usdc.mint(randomEoa, 7e6);
        vm.startPrank(randomEoa);
        usdc.approve(address(vault), 7e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Incentivized(randomEoa, 7e6, EPOCH_2); // EPOCH_2 == epochStart at setUp
        vault.incentivize(7e6);
        vm.stopPrank();
    }

    // =========================================================================
    // 2. Linear vesting profile within the epoch
    // =========================================================================

    function test_incentivize_linearVesting_acrossEpoch() public {
        // Disable perf fee to make math clean (DEFAULT_FEE_BPS already 0).
        uint256 X = 1000e6;

        uint256 taBefore = vault.totalAssets();
        // setUp warped to EPOCH_2 boundary, so we are exactly at vest start.
        _doIncentivize(randomEoa, X);

        // Right at vest start, full X is unvested (deducted from totalAssets).
        // _doIncentivize transferred X into the vault, but the entire X is in
        // vestingEpochPremium with elapsed=0 so totalAssets is unchanged.
        assertEq(vault.totalAssets(), taBefore, "totalAssets unchanged at vest start (X fully unvested)");
        assertEq(vault.getUnvestedLenderPremium(), X, "all X unvested at start");

        // 25% through the epoch: ~ X/4 vested into totalAssets.
        vm.warp(EPOCH_2 + WEEK / 4);
        uint256 ta25 = vault.totalAssets();
        // tolerance 1 wei for division rounding.
        assertApproxEqAbs(ta25, taBefore + X / 4, 1, "totalAssets ~= prev + X/4 at 25% elapsed");

        // 50%
        vm.warp(EPOCH_2 + WEEK / 2);
        assertApproxEqAbs(vault.totalAssets(), taBefore + X / 2, 1, "~ prev + X/2 at 50%");

        // 75%
        vm.warp(EPOCH_2 + (WEEK * 3) / 4);
        assertApproxEqAbs(vault.totalAssets(), taBefore + (X * 3) / 4, 1, "~ prev + 3X/4 at 75%");

        // End of epoch (epochStart + WEEK == start of next epoch). Once
        // nowEpoch > vestingEpochStart, _getUnvestedLenderPremium returns 0
        // and the full X is realized.
        vm.warp(EPOCH_3);
        assertEq(vault.totalAssets(), taBefore + X, "full X realized at epoch boundary");
        assertEq(vault.getUnvestedLenderPremium(), 0, "no unvested premium past vest epoch");
    }

    // =========================================================================
    // 3. Mid-epoch top-up: bucket additivity
    // =========================================================================

    function test_incentivize_midEpochTopup_additive() public {
        uint256 X = 800e6;
        uint256 Y = 400e6;

        uint256 taBefore = vault.totalAssets();

        // First incentive at epoch start.
        _doIncentivize(randomEoa, X);
        assertEq(vault.getUnvestedLenderPremium(), X, "X fully unvested at start");

        // Top up at 25% elapsed. By this point X/4 has vested into totalAssets.
        vm.warp(EPOCH_2 + WEEK / 4);
        uint256 taMid = vault.totalAssets();
        assertApproxEqAbs(taMid, taBefore + X / 4, 1, "X/4 vested by mid-call");

        _doIncentivize(randomEoa, Y);

        // Implementation does `vestingEpochPremium += amount`. The unvested
        // portion of X (= 3X/4) is still in the bucket, so post-add bucket
        // contains 3X/4 + Y. The vested portion (X/4) has already flowed into
        // totalAssets via the USDC balance.
        //
        // Sanity check: `getUnvestedLenderPremium` views the bucket's unvested
        // share at this elapsed time. Bucket = X + Y (since `vestingEpochPremium
        // += Y` adds Y to the existing X — no re-vesting). Unvested share at
        // 25% elapsed of (X + Y) = 3(X+Y)/4. So the immediate view jumps to
        // 3(X+Y)/4, NOT (3X/4 + Y). This is an artefact of the additive bucket
        // model and is consistent with the production expectation in the task
        // description: "the implementation just does vestingEpochPremium +=
        // amount without re-vesting".
        uint256 unvestedAfter = vault.getUnvestedLenderPremium();
        assertApproxEqAbs(unvestedAfter, (3 * (X + Y)) / 4, 1, "unvested = 3(X+Y)/4 at 25% elapsed under additive model");

        // Walk to epoch end. Final realized total must be exactly X + Y.
        // (Even though the bucket model is additive rather than re-vesting,
        // the bucket fully drains at WEEK elapsed regardless.)
        vm.warp(EPOCH_3);
        assertEq(vault.totalAssets(), taBefore + X + Y, "by epoch end, full X + Y is realized");
        assertEq(vault.getUnvestedLenderPremium(), 0, "bucket fully vested past epoch");
    }

    // =========================================================================
    // 4. Epoch rollover with stale bucket sweep
    // =========================================================================

    function test_incentivize_staleBucketSweep_onEpochRollover() public {
        uint256 X = 600e6;
        uint256 Y = 200e6;

        uint256 taBefore = vault.totalAssets();
        _doIncentivize(randomEoa, X);

        // Cross into the next epoch WITHOUT calling sync.
        vm.warp(EPOCH_3);
        // X has fully vested via balance growth (USDC sits on the contract,
        // and now nowEpoch > vestingEpochStart so _getUnvestedLenderPremium
        // returns 0).
        assertEq(vault.totalAssets(), taBefore + X, "X fully realized by epoch boundary");
        assertEq(vault.getUnvestedLenderPremium(), 0, "no unvested premium pre-sweep");

        // Now incentivize again; the implementation must zero the stale bucket
        // before adding Y. After the call: vestingEpochPremium == Y,
        // vestingEpochStart == EPOCH_3.
        _doIncentivize(randomEoa, Y);

        // Y is freshly unvested at the start of EPOCH_3 — but X is gone from
        // the bucket (already realized into balance). totalAssets should be
        // taBefore + X (from realized X) — the freshly transferred Y is held
        // back by the new vesting bucket, so it does NOT show up yet.
        assertEq(vault.totalAssets(), taBefore + X, "Y is unvested, X realized");
        assertEq(vault.getUnvestedLenderPremium(), Y, "bucket holds only Y after sweep");

        // Walk to EPOCH_4. Y now realized too.
        vm.warp(EPOCH_4);
        assertEq(vault.totalAssets(), taBefore + X + Y, "X + Y both realized by EPOCH_4");
    }

    // =========================================================================
    // 5. Coexistence with concurrent borrower-stream rewards
    // =========================================================================

    function test_incentivize_concurrentWithBorrowerStream_noDoubleCount() public {
        // Setup: 30% util, 20% lender ratio (flat).
        _setFlatRatio(vault, 2000);

        // borrower borrows
        vm.prank(borrower);
        vault.borrowFromPortfolio(3000e6);

        // borrower deposits 100e6 reward. Stream runs EPOCH_2 -> EPOCH_3.
        // Of that, 20% (20e6) is lender premium, 80% (80e6) is borrower credit.
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 taBeforeIncentive = vault.totalAssets();

        // Third party adds 50e6 incentive at EPOCH_2 (vest start of stream).
        _doIncentivize(randomEoa, 50e6);

        // At vest start: incentive fully unvested, stream has 0 elapsed.
        // totalAssets shouldn't have changed materially from the incentive.
        assertApproxEqAbs(vault.totalAssets(), taBeforeIncentive, 1, "no movement at t=0 of fresh bucket");

        // Walk to EPOCH_3: full epoch elapsed.
        // sync() runs _processGlobalVesting, which:
        //   1. Sees full WEEK elapsed → globalVested = stream rate * WEEK ≈ 100e6.
        //      Splits: lenderPremium = 20e6, borrowerCredit = 80e6.
        //   2. Reaches the stale-bucket sweep:
        //        vestingEpochStart=EPOCH_2 > 0 && nowEpoch=EPOCH_3 > EPOCH_2
        //        → wipes vestingEpochPremium (the prior 50e6 incentive) and
        //          resets vestingEpochStart=0.
        //   3. Then `vestingEpochPremium += 20e6` and `vestingEpochStart = EPOCH_3`.
        //
        // The key invariant: the 50e6 incentive's USDC is STILL in the vault
        // balance, and now there's no offsetting deduction in the formula since
        // the bucket was wiped. So totalAssets reflects the realized 50e6.
        // The 20e6 stream premium has been re-tagged to EPOCH_3 and remains
        // unvested (deducted from totalAssets) until EPOCH_4.
        vm.warp(EPOCH_3);
        vault.sync();

        uint256 taAfter = vault.totalAssets();
        // Expected: only the 50e6 incentive shows up. The 20e6 stream premium
        // is now tagged EPOCH_3 and unvested. (This is the documented two-epoch
        // lag behavior for stream premium under late settlement; incentivize
        // cleanly avoids that lag because its bucket-tag never goes backwards
        // — see test_incentivize_noTwoEpochLag_whenAfterStreamFinalize.)
        // Tolerance covers floor-division dust on per-second rate derivation
        // (premium dust bounded by 0.2 * WEEK = 120,960 wei per stream).
        assertApproxEqAbs(taAfter - taBeforeIncentive, 50e6, 200_000,
            "incentive 50e6 realized; stream 20e6 premium re-tagged to EPOCH_3 and still unvested");
        // Tolerance covers floor-division dust on per-second rate derivation.
        assertApproxEqAbs(vault.getUnvestedLenderPremium(), 20e6, 200_000,
            "vesting bucket holds only the freshly-routed stream premium");

        // Walk one more epoch: stream premium fully realizes too.
        vm.warp(EPOCH_4);
        vault.sync();
        // Now both have realized: total delta = 50e6 + 20e6 = 70e6, no double-count.
        // Tolerance covers floor-division dust on per-second rate derivation.
        assertApproxEqAbs(vault.totalAssets() - taBeforeIncentive, 70e6, 200_000,
            "by EPOCH_4 both lender delta components are realized exactly once");

        // Underflow guard: settle borrower and verify no revert.
        vault.settleRewards(borrower);
        // Borrower credit applied: debt should drop by ~80e6 (within 1 wei from
        // integer-division rounding in `(rate * accumulatorDelta) / 1e18`).
        // Tolerance covers floor-division dust on per-second rate derivation
        // (borrower-credit dust bounded by 0.8 * WEEK = 483,840 wei per stream).
        assertApproxEqAbs(vault.getDebtBalance(borrower), 3000e6 - 80e6, 600_000,
            "borrower debt reduced by ~80e6 of borrower credit (no double count)");
    }

    // =========================================================================
    // 6. Two-epoch lag does NOT apply to incentivize (regression guard)
    //
    // Background: per project memory, stream-derived premium can lag the source
    // epoch by 2 epochs because `_processGlobalVesting` may roll
    // `currentEpochStart` forward to the current epoch on late settlement,
    // tagging the bucket to a later epoch than the source.
    //
    // For `incentivize`, the bucket is tagged with `nowEpoch =
    // epochStart(block.timestamp)` at the time of the call — never in the past.
    // So an `incentivize` at the START of epoch N+2 must vest IN epoch N+2,
    // not in N+3.
    // =========================================================================

    function test_incentivize_noTwoEpochLag_whenAfterStreamFinalize() public {
        _setFlatRatio(vault, 2000);
        vm.prank(borrower);
        vault.borrowFromPortfolio(3000e6);

        // Stream in epoch N (= EPOCH_2): runs EPOCH_2 -> EPOCH_3.
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Skip ahead WITHOUT settlement to EPOCH_4 (epoch N+2). The stream
        // finalized at EPOCH_3 but no one has called sync. When we call
        // incentivize at EPOCH_4, _processGlobalVesting will run and route the
        // stream's lender premium with vestingEpochStart = EPOCH_4 (max of
        // EPOCH_3-stream-end and EPOCH_4-now). That's the "late settlement"
        // path producing the 2-epoch lag for stream-derived premium.
        vm.warp(EPOCH_4);

        uint256 taPre = vault.totalAssets();
        uint256 INCENTIVE = 200e6;
        _doIncentivize(randomEoa, INCENTIVE);

        // Right after the call:
        //   vestingEpochStart == EPOCH_4 (current epoch, by construction)
        //   vestingEpochPremium == 20e6 (stream premium) + 200e6 (incentive)
        // Both vest TOGETHER over EPOCH_4 -> EPOCH_5.
        // Tolerance covers floor-division dust on per-second rate derivation.
        assertApproxEqAbs(vault.getUnvestedLenderPremium(), 20e6 + INCENTIVE, 200_000,
            "bucket holds stream premium + incentive at EPOCH_4 start");

        // Walk to EPOCH_5 — both premiums fully realize. The incentive vested
        // IN epoch N+2 (EPOCH_4 -> EPOCH_5), NOT in N+3. This is the
        // regression guard.
        vm.warp(EPOCH_5);
        // Need to trigger fee accrual / view recomputation.
        // totalAssets() is a pure view of state; just read it.
        // Tolerance covers floor-division dust on per-second rate derivation.
        assertApproxEqAbs(vault.totalAssets(), taPre + 20e6 + INCENTIVE, 200_000,
            "incentive realized in N+2 (no two-epoch lag)");
    }

    // =========================================================================
    // 9. Donation-attack resistance via virtual-shares offset
    // =========================================================================

    function test_incentivize_donationAttack_resistance() public {
        // Classic ERC4626 first-depositor inflation attack adapted to incentivize:
        //   1. Attacker is first depositor with 1 wei → 1 * 1e6 = 1e6 shares
        //      (decimalsOffset=6 → virtualShares=1e6).
        //   2. Attacker `incentivize`s a huge amount, inflating eventual
        //      totalAssets while supply stays at 1e6.
        //   3. A victim then deposits a meaningful amount; the attack succeeds
        //      if the victim receives ZERO shares due to inflated share price.
        //
        // With decimalsOffset=6, the offset adds 1e6 virtual shares to the
        // denominator and 1 to totalAssets, so the share price is bounded:
        //   shares_for_victim = victim_assets * (totalSupply + 1e6)
        //                                    / (totalAssets + 1)
        // For attack to succeed (victim gets 0 shares), we need totalAssets/1e6
        // to dominate victim_assets — i.e. attacker's donation > victim's
        // deposit * 1e6. That's a 1,000,000x asymmetry.
        //
        // We verify two things:
        //   (a) A reasonably-sized victim still gets a positive number of shares
        //       even after a meaningful attack budget.
        //   (b) The victim can redeem a fair fraction of what they put in,
        //       proving the inflation-attack didn't grant the attacker the
        //       lion's share.

        DynamicFeesVault freshVault = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, 0
        );

        address attacker = address(0xA77AC4);
        address victim = address(0x717C71);

        // Step 1: attacker deposits 1 wei. Yields 1e6 shares.
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(freshVault), 1);
        uint256 attackerShares = freshVault.deposit(1, attacker);
        vm.stopPrank();
        assertEq(attackerShares, 1e6, "1 wei deposit -> 1e6 shares (virtual offset)");

        // Step 2: attacker incentivizes 1000 USDC (a meaningful but not absurd
        // attack budget — donating more is just lighting more money on fire).
        uint256 ATTACK = 1000e6;
        usdc.mint(attacker, ATTACK);
        vm.startPrank(attacker);
        usdc.approve(address(freshVault), ATTACK);
        freshVault.incentivize(ATTACK);
        vm.stopPrank();

        // Wait for the incentive to fully vest.
        vm.warp(EPOCH_3);

        // Roll past attacker's lastDepositBlock guard so we can take other
        // actions in subsequent blocks.
        vm.roll(block.number + 5);

        // Step 3: victim deposits 100 USDC. Must receive non-zero shares.
        uint256 VICTIM_DEPOSIT = 100e6;
        usdc.mint(victim, VICTIM_DEPOSIT);
        vm.startPrank(victim);
        usdc.approve(address(freshVault), VICTIM_DEPOSIT);
        uint256 victimShares = freshVault.deposit(VICTIM_DEPOSIT, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim must receive non-zero shares (inflation attack would zero them)");

        // Verify the victim's share position retains meaningful value via
        // previewRedeem (this avoids the maxRedeem-vs-liquidity branch).
        uint256 victimQuote = freshVault.previewRedeem(victimShares);
        assertGt(victimQuote, 0, "victim's shares retain non-zero asset value");

        // The critical inflation-attack property: attacker did NOT profit. They
        // donated ATTACK + 1 wei and own 1e6 shares; their max-recovery cannot
        // exceed what they donated.
        uint256 attackerCap = freshVault.previewRedeem(attackerShares);
        assertLe(
            attackerCap,
            ATTACK + 1,
            "attacker's recoverable assets <= what they donated (no profit from inflation attack)"
        );
    }

    // =========================================================================
    // 10. Performance fee charges on incentive vesting
    // =========================================================================

    function test_incentivize_perfFeeAccrues_onIncentiveGrowth() public {
        // Deploy a vault with feeBps > 0.
        DynamicFeesVault feeVault = _deployVault(
            address(usdc), address(portfolioFactory), feeRecipient, 2500 // 25% bps
        );
        // Seed it
        usdc.mint(address(this), SEED);
        usdc.approve(address(feeVault), SEED);
        feeVault.deposit(SEED, address(this));

        // Sanity: no fee shares yet.
        assertEq(feeVault.balanceOf(feeRecipient), 0);

        // Third party incentivizes 1000e6.
        uint256 X = 1000e6;
        usdc.mint(randomEoa, X);
        vm.startPrank(randomEoa);
        usdc.approve(address(feeVault), X);
        feeVault.incentivize(X);
        vm.stopPrank();

        // Walk to next epoch — the full X realizes into totalAssets. We need
        // ANY state-changing call to trigger _accrueFee since totalAssets()
        // delta itself doesn't mint shares — _accrueFee does.
        vm.warp(EPOCH_3);
        feeVault.sync();

        uint256 feeShares = feeVault.balanceOf(feeRecipient);
        assertGt(feeShares, 0, "feeRecipient receives perf fee shares from incentive vesting");

        // Tight assertion: feeAssets ~= 25% * X = 250e6 (within rounding).
        uint256 feeValue = feeVault.convertToAssets(feeShares);
        uint256 expected = (X * 2500) / 10000;
        assertApproxEqAbs(feeValue, expected, expected / 100 + 1,
            "feeValue ~= 25% * incentive amount (within 1% rounding)");
    }

    // =========================================================================
    // 12. Reentrancy via malicious token hook is blocked
    // =========================================================================

    function test_incentivize_reentrancy_blocked() public {
        // Deploy a fresh vault using the hook token as the underlying so we
        // can intercept transferFrom mid-incentivize.
        HookUSDC hook = new HookUSDC();
        DynamicFeesVault hookVault = _deployVault(
            address(hook), address(portfolioFactory), feeRecipient, 0
        );

        // Seed it (no hook armed yet).
        hook.mint(address(this), SEED);
        hook.approve(address(hookVault), SEED);
        hookVault.deposit(SEED, address(this));

        // Arm the hook to call back into vault.sync() during the next
        // transferFrom. sync() goes through _processGlobalVesting -> _accrueFee
        // -> nothing nonReentrant by itself, but vault.deposit(),
        // vault.incentivize(), vault.claimEscrow() are nonReentrant.
        //
        // We arm with `incentivize(1)` — a reentrant call into the same
        // function. That MUST revert with ReentrancyGuardReentrantCall.
        hook.mint(address(this), 100e6);
        hook.approve(address(hookVault), 100e6);

        // Need to set up the inner call to be authenticated:
        //   incentivize(1) only requires amount>0 and a token.allowance/balance.
        //   But during reentry, the *hook.transferFrom* will be called by the
        //   inner incentivize too. To avoid infinite recursion, we use the
        //   single-shot armedOnce flag in HookUSDC. The inner incentivize will
        //   pass the amount==0 check, hit nonReentrant -> revert.
        bytes memory innerData = abi.encodeWithSelector(
            DynamicFeesVault.incentivize.selector,
            uint256(1)
        );
        hook.arm(address(hookVault), innerData);

        // Outer call: incentivize(100e6). Inside hook.transferFrom, the call
        // recurses via incentivize(1). Recursion is blocked by nonReentrant.
        // The hook bubbles up the inner revert → outer call also reverts.
        vm.expectRevert(); // ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector
        hookVault.incentivize(100e6);
    }

    // =========================================================================
    // 13. Transient totalAssets monotonicity across the safeTransferFrom hook
    //
    // The implementation deliberately transfers BEFORE the storage write so
    // totalAssets() observed mid-transfer is non-decreasing. This test guards
    // against a future regression where someone reorders the writes back to
    // pre-transfer (which would temporarily INCREASE the unvested premium
    // bucket, decreasing totalAssets transiently).
    // =========================================================================

    function test_incentivize_transientTotalAssets_isMonotonic() public {
        HookUSDC hook = new HookUSDC();
        DynamicFeesVault hookVault = _deployVault(
            address(hook), address(portfolioFactory), feeRecipient, 0
        );
        hook.mint(address(this), SEED);
        hook.approve(address(hookVault), SEED);
        hookVault.deposit(SEED, address(this));

        // Arm hook to call back into a view: no revert propagation.
        hook.setPropagateRevert(false);
        bytes memory viewCall = abi.encodeWithSelector(DynamicFeesVault.totalAssets.selector);
        hook.arm(address(hookVault), viewCall);

        // Pre-call totalAssets snapshot.
        uint256 taPre = hookVault.totalAssets();

        // Now incentivize. The hook will read totalAssets() during transferFrom —
        // AFTER the underlying tokens have been pulled in but BEFORE the
        // storage write to vestingEpochPremium.
        hook.mint(randomEoa, 500e6);
        vm.startPrank(randomEoa);
        hook.approve(address(hookVault), 500e6);
        hookVault.incentivize(500e6);
        vm.stopPrank();

        // Inspect what the hook recorded.
        assertTrue(hook.lastInnerOk(), "inner totalAssets() call succeeded");
        uint256 midTotalAssets = abi.decode(hook.lastInnerReturn(), (uint256));

        // Mid-call: tokens already transferred (balance += 500e6) but bucket
        // NOT yet written. So _getUnvestedLenderPremium uses the OLD bucket
        // state (zero or stale). totalAssets includes the new balance →
        // totalAssets >= taPre.
        //
        // If the writes were reordered (write before transfer), midTotalAssets
        // would equal taPre - 500e6 momentarily. This assertion catches that.
        assertGe(midTotalAssets, taPre,
            "transient totalAssets MUST be non-decreasing during incentivize transferFrom");

        // After the call, totalAssets equals taPre (the 500e6 is now fully
        // unvested in the bucket and deducted from gross — at vest start,
        // elapsed=0 → unvested = full 500e6).
        assertEq(hookVault.totalAssets(), taPre,
            "post-call totalAssets unchanged (full bucket unvested)");
    }

    // =========================================================================
    // Bonus: the `Incentivized` event epoch field equals epochStart(now), even
    // when called mid-epoch.
    // =========================================================================

    function test_incentivize_eventEpoch_isEpochStart_notNow() public {
        // Warp to mid-epoch
        vm.warp(EPOCH_2 + WEEK / 3);
        usdc.mint(randomEoa, 1e6);
        vm.startPrank(randomEoa);
        usdc.approve(address(vault), 1e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Incentivized(randomEoa, 1e6, EPOCH_2); // floored to epoch start
        vault.incentivize(1e6);
        vm.stopPrank();
    }
}
