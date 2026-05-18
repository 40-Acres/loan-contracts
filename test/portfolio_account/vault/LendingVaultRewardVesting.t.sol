// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/*
 * =============================================================
 * LendingVault Reward Vesting / JIT Sandwich Defense Tests
 * =============================================================
 *
 * Validates the WEEK-grossed mid-epoch deposit fix in
 * `_accumulateEpochReward`:
 *
 *   ΔLocked = (remaining / WEEK) * (amount * WEEK / remaining) = amount
 *   ΔtotalAssets() = +amount (balance) - amount (locked) = 0
 *
 * Storage layout (computed for `vm.load`-based assertions):
 *   base = keccak256("storage.LendingVault")
 *   Slot offsets within LendingVaultStorage:
 *     0  portfolioFactory      (address)
 *     1  owner                 (address)
 *     2  totalLoanedAssets     (uint256)
 *     3  debtBalance mapping
 *     4  __deprecated_maxUtilizationBps (uint256)
 *     5  originationFeeBps     (uint256)
 *     6  paused                (bool, alone since next is uint256)
 *     7  currentEpochRewards   (uint256)   <-- grossed-up vesting basis
 *     8  currentEpochStart     (uint256)
 *     9  lastDepositBlock mapping
 *     10 sharesDecimalsOffset + treasury packed (uint8 + address)
 *     11 currentEpochActualRewards (uint256)   <-- truthful sum
 * =============================================================
 */

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
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

contract LendingVaultRewardVestingTest is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public vaultOwner;
    address public lpA;
    address public lpB;
    address public attackerC;
    address public rewarder;

    uint256 internal constant WEEK = ProtocolTimeLibrary.WEEK;
    // Absolute, hardcoded timestamps -- via-ir caches block.timestamp across vm.warp
    // in the same function, so we never recompute epoch boundaries from block.timestamp.
    uint256 internal constant EPOCH_START = 2 * WEEK;        // setUp warp target
    uint256 internal constant EPOCH_MID   = EPOCH_START + WEEK / 2;
    uint256 internal constant EPOCH_NEXT  = EPOCH_START + WEEK;      // == 3 * WEEK
    uint256 internal constant EPOCH_NEXT_MID = EPOCH_NEXT + WEEK / 2;

    uint256 internal constant ORIG_FEE_BPS = 0; // disable for cleanliness in vesting tests

    bytes32 internal constant STORAGE_BASE = keccak256("storage.LendingVault");
    uint256 internal constant SLOT_CURRENT_EPOCH_REWARDS        = 7;
    uint256 internal constant SLOT_CURRENT_EPOCH_ACTUAL_REWARDS = 11;

    function setUp() public {
        vm.warp(EPOCH_START);

        vaultOwner = address(0xA1);
        lpA = address(0xB1);
        lpB = address(0xB2);
        attackerC = address(0xCC);
        rewarder = address(0xDD);

        vm.label(vaultOwner, "VaultOwner");
        vm.label(lpA, "LP-A");
        vm.label(lpB, "LP-B");
        vm.label(attackerC, "Attacker-C");
        vm.label(rewarder, "Rewarder");

        usdc = new MockUSDC();
        vm.label(address(usdc), "USDC");

        portfolioFactory = new MockPortfolioFactory();

        LendingVault vaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(usdc),
            address(portfolioFactory),
            vaultOwner,
            "Lending Vault",
            "lvUSDC",
            ORIG_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LendingVault(address(proxy));
        vm.label(address(vault), "LendingVault");
    }

    // -------------------- helpers --------------------

    function _deposit(address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
        // Advance block so the flash-deposit guard in _withdraw doesn't trip
        // on subsequent withdraws / redeems in the same test.
        vm.roll(block.number + 1);
    }

    function _depositRewards(uint256 amount) internal {
        usdc.mint(rewarder, amount);
        vm.startPrank(rewarder);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    function _readSlot(uint256 fieldOffset) internal view returns (uint256) {
        bytes32 slot = bytes32(uint256(STORAGE_BASE) + fieldOffset);
        return uint256(vm.load(address(vault), slot));
    }

    function _currentEpochRewards() internal view returns (uint256) {
        return _readSlot(SLOT_CURRENT_EPOCH_REWARDS);
    }

    function _currentEpochActualRewards() internal view returns (uint256) {
        return _readSlot(SLOT_CURRENT_EPOCH_ACTUAL_REWARDS);
    }

    // -------------------- 1. JIT invariant --------------------

    /// @notice The headline visible invariant: a mid-epoch depositRewards call
    /// must not bump totalAssets() at the moment of the call. The gross-up
    /// in _accumulateEpochReward is precisely the mechanism that enforces this.
    function test_DepositRewards_MidEpoch_TotalAssetsUnchanged() public {
        _deposit(lpA, 1_000_000e6);

        vm.warp(EPOCH_MID);
        uint256 totalBefore = vault.totalAssets();

        _depositRewards(10_000e6);

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalAfter, totalBefore, "totalAssets must not jump on mid-epoch reward deposit");
    }

    // -------------------- 2. Gross-up accounting --------------------

    /// @notice At remaining = WEEK/2, the stored vesting basis (currentEpochRewards)
    /// should be grossed up by WEEK/(WEEK/2) = 2x, while the truthful sum
    /// (currentEpochActualRewards) should equal the raw amount.
    function test_DepositRewards_MidEpoch_GrossUpAccounting() public {
        _deposit(lpA, 1_000_000e6);

        vm.warp(EPOCH_MID);

        uint256 R = 10_000e6;
        uint256 grossBefore   = _currentEpochRewards();
        uint256 actualBefore  = _currentEpochActualRewards();

        _depositRewards(R);

        uint256 grossDelta  = _currentEpochRewards()       - grossBefore;
        uint256 actualDelta = _currentEpochActualRewards() - actualBefore;

        // remaining == WEEK/2 -> gross-up factor 2x
        assertEq(grossDelta,  2 * R, "currentEpochRewards must gross up by WEEK/remaining (2x at mid-epoch)");
        assertEq(actualDelta, R,     "currentEpochActualRewards must record raw amount");

        // Public surface: lastEpochReward() returns the truthful figure.
        assertEq(vault.lastEpochReward(), R, "lastEpochReward must reflect truthful sum");

        // And epochRewardsLocked() must equal R (the linear-vesting locked portion
        // at the moment of deposit is exactly the incoming amount -- that's what
        // makes totalAssets() invariant).
        assertEq(vault.epochRewardsLocked(), R, "locked portion at deposit-moment == raw amount");
    }

    // -------------------- 3. JIT sandwich regression --------------------

    /// @notice Attacker C tries the classic mid-epoch sandwich:
    ///   1. LP-A pre-deposits (long-term holder)
    ///   2. Warp to mid-epoch
    ///   3. C front-runs: deposits assets just before a reward-fee deposit
    ///   4. The rewarder deposits R
    ///   5. Roll forward one block (same-block redeem is blocked by lastDepositBlock)
    ///   6. C redeems all shares -> should NOT profit beyond the linear vesting
    ///      that genuinely accrued over the 1-block window.
    ///
    /// Pre-fix: totalAssets jumps by R at step 4, share price jumps, C extracts.
    /// Post-fix: totalAssets is invariant at step 4, C only earns the
    ///           per-block linear-vesting drip (bounded by R * 1 block / WEEK).
    function test_DepositRewards_JIT_SandwichYieldsZeroProfit() public {
        // 1. LP-A pre-deposits.
        _deposit(lpA, 1_000_000e6);

        // 2. Mid-epoch.
        vm.warp(EPOCH_MID);

        // 3. Attacker C deposits (front-run).
        uint256 cDeposit = 1_000_000e6;
        usdc.mint(attackerC, cDeposit);
        vm.startPrank(attackerC);
        usdc.approve(address(vault), cDeposit);
        vault.deposit(cDeposit, attackerC);
        vm.stopPrank();

        uint256 cShares = vault.balanceOf(attackerC);

        // 4. Reward deposit lands in the same block.
        uint256 R = 100_000e6;
        _depositRewards(R);

        // 5. Advance 1 block (same-block redeem is blocked by `lastDepositBlock`).
        //    Importantly: do NOT warp the clock here -- we want to isolate the
        //    "same-second sandwich" case. block.number changes; block.timestamp does not.
        vm.roll(block.number + 1);

        // 6. C redeems.
        vm.prank(attackerC);
        uint256 cWithdrawn = vault.redeem(cShares, attackerC, attackerC);

        // No timestamp advance -> no vesting drip -> profit must be exactly zero
        // (modulo small ERC4626 rounding dust). Pre-fix this would show meaningful
        // positive profit equal to ~half of R * (cShares/totalShares).
        assertLe(cWithdrawn, cDeposit + 2, "JIT sandwich must not yield profit beyond 2 wei rounding");

        // Also verify the upper bound predicted by linear vesting over 0 seconds:
        // attacker's pro-rata share of (epochRewardsLocked_before - epochRewardsLocked_after)
        // is 0 when no time elapsed. We assert profit strictly bounded by tiny dust.
        if (cWithdrawn > cDeposit) {
            uint256 profit = cWithdrawn - cDeposit;
            assertLe(profit, 2, "max profit must be <= rounding dust");
        }
    }

    // -------------------- 4. Multi-deposit accumulation --------------------

    /// @notice Three mid-epoch reward deposits should sum truthfully and,
    /// once fully vested at epoch end, deliver exactly 3R into totalAssets.
    function test_MultiDepositSameEpoch_VestsToExactSum() public {
        _deposit(lpA, 1_000_000e6);

        uint256 R = 5_000e6;
        uint256 totalAt0 = vault.totalAssets();

        // Deposit 1: at epoch start
        vm.warp(EPOCH_START);
        _depositRewards(R);

        // Deposit 2: at epoch start + 2 days
        vm.warp(EPOCH_START + 2 days);
        _depositRewards(R);

        // Deposit 3: at epoch start + 5 days
        vm.warp(EPOCH_START + 5 days);
        _depositRewards(R);

        // Warp to next epoch -> rewards fully vested.
        vm.warp(EPOCH_NEXT);

        uint256 totalAtEnd = vault.totalAssets();
        uint256 grew = totalAtEnd - totalAt0;
        assertApproxEqAbs(grew, 3 * R, 3, "totalAssets must grow by exactly 3R (<=3 wei dust)");

        // Truthful sum reflects exactly 3R regardless of vesting math.
        assertEq(vault.lastEpochReward(), 3 * R, "lastEpochReward must sum raw amounts");
    }

    // -------------------- 5. Boundary: 1 second remaining --------------------

    /// @notice With remaining == 1s, gross-up factor is WEEK. A deposit of R
    /// at this boundary must still leave totalAssets unchanged, and after
    /// crossing into the next epoch, totalAssets should grow by R.
    /// Also: lastEpochReward() lingers at R after the rollover until the next
    /// depositRewards() call resets it (lazy slot rollover is correct).
    function test_EndOfEpochBoundary_OneSecondRemaining() public {
        _deposit(lpA, 1_000_000e6);

        // 1 second before epoch boundary.
        vm.warp(EPOCH_NEXT - 1);
        uint256 totalBefore = vault.totalAssets();

        uint256 R = 7_777e6;
        _depositRewards(R);

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalAfter, totalBefore, "totalAssets invariant even at 1s remaining");
        assertEq(vault.lastEpochReward(), R, "truthful counter records R");

        // Step 1s -> next epoch -> reward fully vested.
        vm.warp(EPOCH_NEXT);
        assertEq(vault.epochRewardsLocked(), 0, "no locked portion after rollover");
        uint256 totalNext = vault.totalAssets();
        assertEq(totalNext, totalBefore + R, "totalAssets grew by exactly R after vesting");

        // Slot lingers (lazy rollover): a fresh epoch with no new depositRewards
        // call must still report the prior epoch's actual sum.
        assertEq(vault.lastEpochReward(), R, "lastEpochReward lingers across epoch until next deposit");
    }

    // -------------------- 6. Idle epoch rollover --------------------

    /// @notice After mid-epoch reward deposit, warp deep into the next epoch
    /// (no further depositRewards). epochRewardsLocked must read 0 (no vesting
    /// owed). lastEpochReward must still return the prior epoch's actual sum.
    function test_IdleEpochRollover_ReadsAreHonest() public {
        _deposit(lpA, 1_000_000e6);

        vm.warp(EPOCH_MID);
        uint256 R = 12_345e6;
        _depositRewards(R);

        // Step into next epoch + half a week -- no depositRewards call.
        vm.warp(EPOCH_NEXT_MID);

        assertEq(vault.epochRewardsLocked(), 0, "epochRewardsLocked must be 0 in idle next epoch");
        assertEq(vault.lastEpochReward(), R, "lastEpochReward retains prior epoch's truthful sum");
    }

    // -------------------- 7. Fuzz: full vest releases exact amount --------------------

    /// @notice For any amount and any deposit timing within the epoch, the full
    /// reward must vest into totalAssets by the next epoch boundary.
    function testFuzz_FullVest_ReleasesExactlyAmount(uint256 amount, uint256 elapsed) public {
        amount  = bound(amount, 1e6, 1e15);          // 1 USDC .. 1B USDC
        elapsed = bound(elapsed, 0, WEEK - 1);

        _deposit(lpA, 1_000_000e6);

        // Snapshot totalAssets at EPOCH_START (before any reward deposit).
        vm.warp(EPOCH_START);
        uint256 totalBefore = vault.totalAssets();

        // Warp to mid-deposit timestamp.
        vm.warp(EPOCH_START + elapsed);
        _depositRewards(amount);

        // Warp to next epoch boundary.
        vm.warp(EPOCH_NEXT);

        uint256 totalAfter = vault.totalAssets();
        uint256 grew = totalAfter - totalBefore;
        assertApproxEqAbs(grew, amount, 2, "full vest must release exactly amount (<=2 wei dust)");
    }

    // -------------------- 8. Fresh-epoch boundary case --------------------

    /// @notice At a fresh epoch boundary, remaining == WEEK so the gross-up
    /// factor is 1: currentEpochRewards == currentEpochActualRewards == R.
    function test_DepositRewards_FreshEpoch_FullAmountVests() public {
        _deposit(lpA, 1_000_000e6);

        // Warp to a NEW epoch boundary (must be strictly after EPOCH_START so
        // the contract enters the "new epoch" branch of _accumulateEpochReward).
        vm.warp(EPOCH_NEXT);

        uint256 R = 50_000e6;
        _depositRewards(R);

        assertEq(_currentEpochRewards(),       R, "fresh-epoch gross-up factor == 1");
        assertEq(_currentEpochActualRewards(), R, "truthful counter == R at fresh epoch");

        // And the visible invariant still holds at this boundary.
        // (Move 1s into the epoch to read totalAssets pre/post a freshly-locked R.
        // We test the invariant by computing the locked portion and asserting it
        // accounts for the full incoming amount.)
        // remaining == WEEK here -> locked == R
        assertEq(vault.epochRewardsLocked(), R, "locked == R immediately at fresh-epoch deposit");
    }
}
