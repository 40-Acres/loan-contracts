// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Regression tests for the `escrowedExcessTotal` accounting fix in
// DynamicFeesVault.
//
// Bug (pre-fix): when `_transferOrEscrow` took the failure branch (e.g. USDC
// blacklist), cash was retained inside the vault and tagged in
// `escrowedExcess[user]`, but no corresponding liability was deducted from
// `totalAssets()`. Net effect: vault balance went up while liabilities
// stayed flat, share price ratchet'd up, and `_accrueFee` minted phantom
// fee shares from a non-event.
//
// Fix:
//   - new storage: `escrowedExcessTotal` (running sum of escrowedExcess[*])
//   - `totalAssets()` deducts `$.escrowedExcessTotal`
//   - `_transferOrEscrow` failure branch increments `$.escrowedExcessTotal`
//   - `claimEscrow()` decrements before transfer (CEI), `nonReentrant`
//   - new views: `escrowedExcessTotal()`, `escrowedExcessOf(address)`
//   - vault inherits ReentrancyGuardUpgradeable and inits in `initialize`.
//
// Invariant proven by the fix:
//   `totalAssets()` is INVARIANT across the escrow event itself — the fix
//   moves the liability from `globalBorrowerPending` (which is decremented
//   in _settleRewards) into `escrowedExcessTotal` (incremented in
//   _transferOrEscrow), and both are deducted equally inside totalAssets().
//
// Each test below explains, in a comment, what specific line of the fix it
// would catch on regression — these tests are designed to FAIL against the
// pre-fix code (or against any future regression that drops the deduction
// or forgets to bump/decrement the counter).
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";

// =====================================================================
// Mocks
// =====================================================================

contract MockUSDCWithBlacklist is ERC20 {
    mapping(address => bool) public blacklisted;
    enum FailMode { ReturnFalse, Revert }
    FailMode public failMode;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setBlacklisted(address user, bool b) external { blacklisted[user] = b; }

    function setFailMode(FailMode m) external { failMode = m; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[to]) {
            if (failMode == FailMode.Revert) revert("blacklisted");
            return false;
        }
        return super.transfer(to, amount);
    }

    // The vault uses safeTransfer in claimEscrow which calls transferFrom from
    // the vault contract itself (no — safeTransfer uses transfer). transferFrom
    // is unused here, but ERC20 default applies for repay() flow.
}

/// @dev Reentrant ERC20 used to verify the `nonReentrant` modifier on claimEscrow.
/// On `transfer`, when armed, calls back into the vault's `claimEscrow()`.
contract ReentrantERC20 is ERC20 {
    address public vaultAddr;
    bool public armed;

    constructor() ERC20("Reentrant USDC", "rUSDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setVault(address v) external { vaultAddr = v; }

    function arm() external { armed = true; }

    function disarm() external { armed = false; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && msg.sender == vaultAddr) {
            // Re-enter — this MUST be blocked by nonReentrant.
            DynamicFeesVault(vaultAddr).claimEscrow();
        }
        return super.transfer(to, amount);
    }
}

contract MockPortfolioFactoryEscrowAcct is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }
    function facetRegistry() external pure override returns (address) { return address(0); }
    function portfolioManager() external pure override returns (address) { return address(0); }
    function portfolios(address) external pure override returns (address) { return address(0); }
    function owners(address) external pure override returns (address) { return address(0); }
    function createAccount(address) external pure override returns (address) { return address(0); }
    function getRegistryVersion() external pure override returns (uint256) { return 0; }
    function ownerOf(address portfolio) external pure override returns (address) { return portfolio; }
    function portfolioOf(address) external pure override returns (address) { return address(0); }
    function getAllPortfolios() external pure override returns (address[] memory) { return new address[](0); }
    function getPortfoliosLength() external pure override returns (uint256) { return 0; }
    function getPortfolio(uint256) external pure override returns (address) { return address(0); }
}

/// @dev Pinned 20% lender ratio so reward splits are deterministic (80% to debt, 20% to lender premium).
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// =====================================================================
// Test
// =====================================================================

contract DynamicFeesVaultEscrowAccountingTest is Test {
    DynamicFeesVault public vault;
    MockUSDCWithBlacklist public usdc;
    MockPortfolioFactoryEscrowAcct public portfolioFactory;

    address public owner = address(0xA1);
    address public borrower = address(0xB1);
    address public lp2 = address(0xCAFE);
    address public feeRecipient = address(0xFEE);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // setUp warps to EPOCH_2; rewards stream lifecycle uses absolute hardcoded
    // epoch boundaries to defeat via-ir's block.timestamp caching across vm.warp.
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    uint256 constant SEED       = 10_000e6;
    uint256 constant BORROW     = 100e6;
    uint256 constant REWARDS    = 500e6; // > BORROW so excess > 0 after debt is cleared
    uint256 constant FEE_BPS    = 0;     // disable performance fee here so phantom-fee
                                          // dynamics are isolated to the (e) test.

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDCWithBlacklist();
        portfolioFactory = new MockPortfolioFactoryEscrowAcct();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC",
            address(portfolioFactory), feeRecipient, FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Production fee curve. At this suite's ~1% utilization the borrower share is
        // high, so an over-deposit (capped at debt/worstBorrowerFraction by Part A) still
        // vests into excess that reaches the escrow path under test.
        FeeCalculator fc = new FeeCalculator();
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));

        // Initial LP supplies liquidity.
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, address(this));
    }

    // ----- helpers -----

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

    // -----------------------------------------------------------------
    // Scenario builder used by (a)/(c)/(d)/(f)/(g)/(h):
    // 1) borrower borrows BORROW
    // 2) borrower deposits REWARDS as a reward stream at EPOCH_2
    // 3) advance to EPOCH_5 so the stream has fully vested AND any deferred
    //    lender-premium rolling has had two epochs to settle (per memory the
    //    lag can be up to 2 epochs).
    // 4) blacklist borrower with the requested fail mode
    // 5) settleRewards(borrower) -> drives _settleRewards -> _transferOrEscrow
    //    failure branch.
    // -----------------------------------------------------------------
    function _setupExcessAndEscrow(MockUSDCWithBlacklist.FailMode mode) internal {
        _borrow(borrower, BORROW);
        _depositRewards(borrower, REWARDS);

        // Warp to a far-future epoch so vesting is complete.
        vm.warp(EPOCH_5);

        usdc.setFailMode(mode);
        usdc.setBlacklisted(borrower, true);

        vault.settleRewards(borrower);
    }

    // =================================================================
    // (a) Total assets invariant across an escrow event when there's debt
    //     PLUS excess.
    //
    // What this catches on regression:
    //   - If `+ $.escrowedExcessTotal` is removed from `totalAssets()`'s
    //     `deductions` (DynamicFeesVault.sol L403), totalAssets jumps by
    //     `excess` at the moment of escrow.
    //   - If `_transferOrEscrow` failure branch (L644) forgets to bump
    //     `escrowedExcessTotal`, the same assertion against
    //     `escrowedExcessTotal()` fails.
    // =================================================================
    function test_TotalAssets_InvariantAcrossEscrowEvent_DebtAndExcess() public {
        _borrow(borrower, BORROW);
        _depositRewards(borrower, REWARDS);
        vm.warp(EPOCH_5);

        // Pre-escrow snapshot (drives global vesting so totalAssets is fully
        // up to date for both pre and post snapshots).
        vault.settleRewards(address(0xDEAD)); // settling a no-op user just runs _processGlobalVesting

        // Now blacklist and force the escrow path.
        usdc.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdc.setBlacklisted(borrower, true);

        uint256 totalBefore = vault.totalAssets();
        uint256 escrowTotalBefore = vault.escrowedExcessTotal();
        assertEq(escrowTotalBefore, 0, "no escrow yet");

        vault.settleRewards(borrower);

        uint256 totalAfter = vault.totalAssets();
        uint256 escrowTotalAfter = vault.escrowedExcessTotal();

        // Excess credited as escrow must be > 0 — borrower had REWARDS=500e6,
        // 80% goes to borrower credit (= 400e6), debt was BORROW=100e6, so
        // excess = 300e6 (modulo rounding). Just assert > 0 and that the
        // borrower's per-user mapping matches the global counter.
        assertGt(escrowTotalAfter, 0, "escrow must have grown");
        assertEq(
            escrowTotalAfter,
            vault.escrowedExcessOf(borrower),
            "global counter must equal sum of per-user (single user case)"
        );

        // The actual fix: totalAssets is invariant across the escrow event.
        assertEq(totalAfter, totalBefore, "totalAssets must be invariant across escrow event");
    }

    // =================================================================
    // (b) Total assets invariant when borrower has NO debt at settlement.
    //     Exercises the no-debt branch in _settleRewards (L626-L630).
    //
    // What this catches on regression:
    //   - Same as (a), but explicitly drives the no-debt branch path. If
    //     someone forgets to bump escrowedExcessTotal in the failure branch,
    //     or removes the deduction from totalAssets(), totalAssets() jumps
    //     by the full borrower reward.
    // =================================================================
    function test_TotalAssets_InvariantAcrossEscrowEvent_NoDebtFullExcess() public {
        // Borrow, then repay in full so debt is 0, then deposit rewards.
        _borrow(borrower, BORROW);

        vm.startPrank(borrower);
        usdc.mint(borrower, BORROW);
        usdc.approve(address(vault), BORROW);
        vault.repay(BORROW);
        vm.stopPrank();
        assertEq(vault.getDebtBalance(borrower), 0, "debt cleared");

        // We need a stream to drive borrower credit. depositRewards requires
        // debtBalance > 0 (`require($.debtBalance[msg.sender] > 0, "No debt to repay");`),
        // so re-borrow a tiny amount, deposit large rewards, then we're back
        // in the typical setup but the resulting borrowerReward will exceed
        // the tiny debt and route through the >oldDebtBalance branch
        // (which is functionally equivalent to no-debt for the escrow flow).
        _borrow(borrower, 1e6); // tiny debt
        _depositRewards(borrower, REWARDS);

        vm.warp(EPOCH_5);

        // Settle a no-op user so global vesting catches up.
        vault.settleRewards(address(0xDEAD));

        usdc.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdc.setBlacklisted(borrower, true);

        uint256 totalBefore = vault.totalAssets();
        uint256 escrowTotalBefore = vault.escrowedExcessTotal();
        assertEq(escrowTotalBefore, 0, "no escrow yet");

        vault.settleRewards(borrower);

        uint256 totalAfter = vault.totalAssets();
        uint256 escrowTotalAfter = vault.escrowedExcessTotal();

        assertGt(escrowTotalAfter, 0, "escrow must have grown");
        assertEq(escrowTotalAfter, vault.escrowedExcessOf(borrower), "global counter == per-user");
        assertEq(totalAfter, totalBefore, "totalAssets invariant across escrow (~no-debt)");
    }

    // =================================================================
    // (c) Same as (a), but the asset's transfer REVERTS (FailMode.Revert)
    //     instead of returning false. Confirms the catch path of
    //     _transferOrEscrow's `.call` (L637) actually escrows on revert.
    //
    // What this catches on regression:
    //   - If _transferOrEscrow stops using `.call` (and instead uses a direct
    //     transfer that bubbles up the revert), `settleRewards` would revert
    //     instead of escrowing. Test would fail because settleRewards itself
    //     would revert.
    //   - The totalAssets invariant fails the same way as (a) on the
    //     accounting regression.
    // =================================================================
    function test_TotalAssets_InvariantAcrossEscrowEvent_RevertingTransfer() public {
        _borrow(borrower, BORROW);
        _depositRewards(borrower, REWARDS);
        vm.warp(EPOCH_5);

        vault.settleRewards(address(0xDEAD)); // sync vesting

        usdc.setFailMode(MockUSDCWithBlacklist.FailMode.Revert);
        usdc.setBlacklisted(borrower, true);

        uint256 totalBefore = vault.totalAssets();
        uint256 escrowBefore = vault.escrowedExcessTotal();

        vault.settleRewards(borrower); // must NOT revert

        uint256 totalAfter = vault.totalAssets();
        uint256 escrowAfter = vault.escrowedExcessTotal();

        assertGt(escrowAfter, escrowBefore, "escrow grew on revert path");
        assertEq(totalAfter, totalBefore, "totalAssets invariant across reverting-transfer escrow");
    }

    // =================================================================
    // (d) Utilization percent invariant across an escrow event.
    //
    // What this catches on regression:
    //   - getUtilizationPercent reads `totalAssets()` as the denominator.
    //     If the escrow deduction is dropped from totalAssets, utilization
    //     drops, possibly relaxing the fee curve and corrupting downstream
    //     behaviour. This is a functional, observable consequence of the bug.
    // =================================================================
    function test_UtilizationPercent_InvariantAcrossEscrow() public {
        _borrow(borrower, BORROW);
        _depositRewards(borrower, REWARDS);
        vm.warp(EPOCH_5);

        vault.settleRewards(address(0xDEAD));

        usdc.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdc.setBlacklisted(borrower, true);

        uint256 utilBefore = vault.getUtilizationPercent();

        vault.settleRewards(borrower);

        uint256 utilAfter = vault.getUtilizationPercent();
        assertEq(utilAfter, utilBefore, "utilization invariant across escrow event");
    }

    // =================================================================
    // (e) pendingFeeShares() is NOT inflated by an escrow.
    //
    // Two parallel vault deployments fed identical state: vault A settles
    // normally (no blacklist, transfer succeeds); vault B settles into
    // escrow. The phantom-fee bug causes B's pendingFeeShares to spike
    // because `totalAssets()` (denominator-of-share-price) jumped without
    // a corresponding liability increase.
    //
    // What this catches on regression:
    //   - Direct test of the original symptom: phantom fee minting on
    //     escrow. Pre-fix, B's pendingFeeShares > A's. Post-fix, equal.
    // =================================================================
    function test_PendingFeeShares_NotInflatedByEscrow() public {
        // Build vault A and vault B in parallel with the SAME initial state
        // and the SAME borrower — but on TWO separate USDC mocks so the
        // blacklist on B's USDC doesn't affect A.

        // Use a *non-zero* feeBps for this test so pendingFeeShares can move.
        uint256 testFeeBps = 1000;

        // Tear down `vault` from setUp and rebuild two siblings.
        MockUSDCWithBlacklist usdcA = new MockUSDCWithBlacklist();
        MockUSDCWithBlacklist usdcB = new MockUSDCWithBlacklist();

        DynamicFeesVault vaultA = _deployVault(usdcA, testFeeBps);
        DynamicFeesVault vaultB = _deployVault(usdcB, testFeeBps);

        // Seed both vaults identically.
        usdcA.mint(address(this), SEED);
        usdcA.approve(address(vaultA), SEED);
        vaultA.deposit(SEED, address(this));

        usdcB.mint(address(this), SEED);
        usdcB.approve(address(vaultB), SEED);
        vaultB.deposit(SEED, address(this));

        // Same borrow on both.
        vm.prank(borrower);
        vaultA.borrowFromPortfolio(BORROW);
        vm.prank(borrower);
        vaultB.borrowFromPortfolio(BORROW);

        // Same reward deposit on both. Mint & approve per-asset.
        vm.startPrank(borrower);
        usdcA.mint(borrower, REWARDS);
        usdcA.approve(address(vaultA), REWARDS);
        vaultA.depositRewards(REWARDS);
        usdcB.mint(borrower, REWARDS);
        usdcB.approve(address(vaultB), REWARDS);
        vaultB.depositRewards(REWARDS);
        vm.stopPrank();

        vm.warp(EPOCH_5);

        // Drive global vesting on both via a no-op user settle.
        vaultA.settleRewards(address(0xDEAD));
        vaultB.settleRewards(address(0xDEAD));

        // Vault A: settle normally. Vault B: blacklist on USDC B only.
        usdcB.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdcB.setBlacklisted(borrower, true);

        // Settle the borrower on both. A pays excess, B escrows.
        vaultA.settleRewards(borrower);
        vaultB.settleRewards(borrower);

        // CRITICAL ASSERTION: totalAssets must match exactly.
        assertEq(
            vaultA.totalAssets(),
            vaultB.totalAssets(),
            "totalAssets must be identical across pay-vs-escrow"
        );

        // And pendingFeeShares (which is a pure function of totalAssets and
        // lastTotalAssetsForFee) must also match.
        assertEq(
            vaultA.pendingFeeShares(),
            vaultB.pendingFeeShares(),
            "pendingFeeShares must be identical across pay-vs-escrow"
        );

        // Sanity: B did escrow.
        assertGt(vaultB.escrowedExcessTotal(), 0, "vault B did escrow");
        assertEq(vaultA.escrowedExcessTotal(), 0, "vault A did NOT escrow");
    }

    function _deployVault(MockUSDCWithBlacklist asset, uint256 _feeBps)
        internal
        returns (DynamicFeesVault v)
    {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(asset), "USDC Vault", "vUSDC",
            address(portfolioFactory), feeRecipient, _feeBps
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
        FeeCalculator fc = new FeeCalculator();
        vm.prank(owner);
        v.setFeeCalculator(address(fc));
    }

    // =================================================================
    // (f) Total assets invariant across claimEscrow().
    //
    // claimEscrow decrements escrowedExcessTotal *before* the transfer
    // (CEI) and then transfers `amount` out. So the asset balance drops
    // by `amount` and the deduction `escrowedExcessTotal` drops by the
    // same `amount`. Net change to totalAssets: zero.
    //
    // What this catches on regression:
    //   - If someone moves the decrement to AFTER the transfer (or
    //     forgets to decrement), totalAssets jumps DOWN by `amount` on
    //     claim — which would be a different inflation/deflation bug.
    //   - If `escrowedExcessTotal -= amount` is removed (L657) entirely,
    //     totalAssets goes negative-equivalent (returns 0 since we have
    //     a max(0, ...) guard) — easily detectable.
    // =================================================================
    function test_TotalAssets_InvariantAcrossClaimEscrow() public {
        _setupExcessAndEscrow(MockUSDCWithBlacklist.FailMode.ReturnFalse);

        // Un-blacklist so the transfer in claimEscrow can succeed.
        usdc.setBlacklisted(borrower, false);

        uint256 amount = vault.escrowedExcessOf(borrower);
        assertGt(amount, 0, "borrower has escrow");

        uint256 totalBefore = vault.totalAssets();
        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vault.claimEscrow();

        uint256 totalAfter = vault.totalAssets();
        uint256 borrowerUsdcAfter = usdc.balanceOf(borrower);

        assertEq(vault.escrowedExcessTotal(), 0, "global counter cleared");
        assertEq(vault.escrowedExcessOf(borrower), 0, "per-user cleared");
        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, amount, "borrower received exact amount");
        assertEq(totalAfter, totalBefore, "totalAssets invariant across claimEscrow");
    }

    // =================================================================
    // (g) Round-trip share-price invariant: a deposit between escrow and
    //     claim should not change the share price experienced by the
    //     other LP. After claim, share price should match the value
    //     observed before the deposit.
    //
    // What this catches on regression:
    //   - If totalAssets() jumps up at escrow, the second LP buys shares
    //     at an inflated price (paying more for less). When the borrower
    //     claims, totalAssets falls back proportionally — and share
    //     price diverges between pre-deposit and post-claim. The fix
    //     keeps share price stable.
    //   - This locks in the *user-visible economic correctness* of the
    //     fix, not just the accounting symbol.
    // =================================================================
    function test_RoundTripInvariant_LpDepositBetweenEscrowAndClaim() public {
        _setupExcessAndEscrow(MockUSDCWithBlacklist.FailMode.ReturnFalse);

        // Snapshot share price after escrow (and before lp2 deposit).
        uint256 priceBefore = vault.convertToAssets(1e6);

        // lp2 deposits — must NOT face a different blacklist; lp2 != borrower.
        uint256 D = 1_000e6;
        usdc.mint(lp2, D);
        vm.startPrank(lp2);
        usdc.approve(address(vault), D);
        vault.deposit(D, lp2);
        vm.stopPrank();

        uint256 priceAfterDeposit = vault.convertToAssets(1e6);

        // ERC4626 invariant: deposit at the current price must not change price
        // (modulo virtual-share rounding for tiny supplies — here SEED + D is
        // huge, so error is at most a couple wei).
        assertApproxEqAbs(
            priceAfterDeposit,
            priceBefore,
            2,
            "deposit must not change share price"
        );

        // Un-blacklist and have borrower claim.
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();

        uint256 priceAfterClaim = vault.convertToAssets(1e6);

        // Pre-deposit price (right after escrow) and post-claim price must match.
        // Tolerance: tight, since no time passed and the only state mutation
        // was claimEscrow which preserves totalAssets and totalSupply.
        assertApproxEqAbs(
            priceAfterClaim,
            priceBefore,
            2,
            "share price drifted across escrow + deposit + claim cycle"
        );
    }

    // =================================================================
    // (h) getEffectiveDebtBalance returns the same value regardless of
    //     whether the borrower's settlement paid out or escrowed.
    //
    // After settlement (success OR escrow), debt is fully cleared because
    // borrowerReward >= storedDebt. So getEffectiveDebtBalance(borrower)
    // == 0 in both cases.
    //
    // What this catches on regression:
    //   - If the escrow path were to *not* clear debt (e.g. revert and
    //     leave $.debtBalance untouched), debt would still be non-zero
    //     in run B. The fix as shipped DOES clear debt before
    //     _transferOrEscrow (debtBalance set in L613), so the test must
    //     pass and protects against future drift in that ordering.
    // =================================================================
    function test_GetEffectiveDebtBalance_UnchangedByEscrowState() public {
        // We need *parallel* runs at the same logical timeline. Build TWO
        // vaults up front, drive both through the identical sequence, but
        // blacklist only on B at the end. This avoids any cross-run timestamp
        // ordering issue (run B can't deposit rewards "in the future" relative
        // to its own setUp because vm.warp is global).
        MockUSDCWithBlacklist usdcA = new MockUSDCWithBlacklist();
        MockUSDCWithBlacklist usdcB = new MockUSDCWithBlacklist();
        DynamicFeesVault vaultA = _deployVault(usdcA, FEE_BPS);
        DynamicFeesVault vaultB = _deployVault(usdcB, FEE_BPS);

        // Seed both at EPOCH_2 (we're already there from setUp).
        usdcA.mint(address(this), SEED);
        usdcA.approve(address(vaultA), SEED);
        vaultA.deposit(SEED, address(this));
        usdcB.mint(address(this), SEED);
        usdcB.approve(address(vaultB), SEED);
        vaultB.deposit(SEED, address(this));

        vm.prank(borrower);
        vaultA.borrowFromPortfolio(BORROW);
        vm.prank(borrower);
        vaultB.borrowFromPortfolio(BORROW);

        vm.startPrank(borrower);
        usdcA.mint(borrower, REWARDS);
        usdcA.approve(address(vaultA), REWARDS);
        vaultA.depositRewards(REWARDS);
        usdcB.mint(borrower, REWARDS);
        usdcB.approve(address(vaultB), REWARDS);
        vaultB.depositRewards(REWARDS);
        vm.stopPrank();

        vm.warp(EPOCH_5);

        // Run A: clean settle (no blacklist).
        vaultA.settleRewards(borrower);

        // Run B: blacklist forces escrow path.
        usdcB.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdcB.setBlacklisted(borrower, true);
        vaultB.settleRewards(borrower);

        uint256 debtA = vaultA.getEffectiveDebtBalance(borrower);
        uint256 debtB = vaultB.getEffectiveDebtBalance(borrower);
        uint256 storedA = vaultA.getDebtBalance(borrower);
        uint256 storedB = vaultB.getDebtBalance(borrower);

        assertEq(debtA, 0, "run A: debt cleared");
        assertEq(debtB, 0, "run B: debt cleared even though excess was escrowed");
        assertEq(storedA, storedB, "stored debt balance also matches");
        assertEq(debtA, debtB, "effective debt unchanged by escrow state");

        // Bonus: the fix's invariant — run B's totalAssets must equal run A's.
        assertEq(vaultA.totalAssets(), vaultB.totalAssets(), "totalAssets parity across pay/escrow");
    }

    // =================================================================
    // (i) claimEscrow has the nonReentrant modifier.
    //
    // We deploy a vault using a malicious ERC20 (`ReentrantERC20`) whose
    // `transfer` re-enters `vault.claimEscrow()` when armed. To create
    // an escrow balance, we use the existing borrow + reward + warp +
    // fail-transfer flow. But the malicious token's transfer succeeds
    // by default — to force escrow, we briefly turn on a "fail" mode by
    // pausing the token (we don't have that). Simpler: have the borrower
    // be a contract whose `transfer` reverts unconditionally during the
    // _transferOrEscrow call — we don't need that either; we just call
    // the malicious-asset path directly.
    //
    // The cleanest approach used here: the borrower IS a contract whose
    // receive of the asset triggers reentrancy. Since _transferOrEscrow
    // uses raw `.call`, it tolerates the borrower's malicious behavior.
    // But that's the wrong direction — we need the *vault* to call into
    // a hostile contract during claimEscrow, not the other way.
    //
    // Approach actually used: the asset itself is malicious. On transfer
    // out (claimEscrow's safeTransfer), it re-enters claimEscrow.
    //
    // To get an escrow balance pre-set, we cheat by directly poking
    // storage via `vm.store` so the test focuses purely on the modifier.
    // =================================================================
    function test_ClaimEscrow_NonReentrant() public {
        ReentrantERC20 reAsset = new ReentrantERC20();

        // Deploy a fresh vault using the malicious asset.
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(reAsset), "Reentrant Vault", "rV",
            address(portfolioFactory), feeRecipient, FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        DynamicFeesVault rv = DynamicFeesVault(address(proxy));
        rv.transferOwnership(owner);
        vm.prank(owner);
        rv.acceptOwnership();

        reAsset.setVault(address(rv));

        // Preload the malicious vault with asset + escrow state directly.
        // The vault must hold enough asset to honor claimEscrow's transfer.
        uint256 amt = 100e6;
        reAsset.mint(address(rv), amt);

        // Set escrowedExcess[borrower] = amt and escrowedExcessTotal = amt
        // by directly writing storage. The storage slot for the namespaced
        // struct is STORAGE_LOCATION:
        //   0x9a0c9d8ec1d9f8b4c5e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b200
        // Layout offsets (from the struct definition, in order):
        //   0:  totalLoanedAssets
        //   1:  debtBalance mapping
        //   2:  portfolioFactory + paused (packed)
        //   3:  pausers mapping
        //   4:  feeCalculator
        //   5:  totalVestedRewardsApplied
        //   6:  lastDepositBlock mapping
        //   7:  totalDebtBalance
        //   8:  currentEpochPremium
        //   9:  currentEpochStart
        //   10: vestingEpochPremium
        //   11: vestingEpochStart
        //   12: userRewardRate mapping
        //   13: userPeriodFinish mapping
        //   14: userLastSettledTime mapping
        //   15: activeEpochRate
        //   16: activeEpochEnd
        //   17: globalLastUpdateTime
        //   18: totalUnsettledRewards
        //   19: globalBorrowerPending
        //   20: borrowerCreditPerRate
        //   21: sharesDecimalsOffset (packed alone — uint8 + padding)
        //   22: userBorrowerCreditPerRatePaid mapping
        //   23: epochEndBorrowerCreditPerRate mapping
        //   24: escrowedExcess mapping     <-- target
        //   25: maxUtilizationBps
        //   26: feeRecipient
        //   27: feeBps
        //   28: lastTotalAssetsForFee
        //   29: escrowedExcessTotal        <-- target
        //
        // Driving it via the actual code path is robust against layout drift.
        // Use the regular flow with a temporary "always fail" asset replaced
        // mid-stream… too brittle. Instead, take advantage of the fact that
        // the malicious ERC20's transfer succeeds by default — we set
        // armed=false for setup. To force escrow we override the asset's
        // transfer to fail; we don't have that. So fall back to the storage
        // poke approach by computing the slots:
        bytes32 STORAGE = 0x9a0c9d8ec1d9f8b4c5e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b200;

        // escrowedExcess mapping is at offset 24.
        bytes32 escrowMapSlot = bytes32(uint256(STORAGE) + 24);
        bytes32 borrowerEntrySlot = keccak256(abi.encode(borrower, escrowMapSlot));
        vm.store(address(rv), borrowerEntrySlot, bytes32(amt));

        // escrowedExcessTotal is at offset 29.
        bytes32 totalSlot = bytes32(uint256(STORAGE) + 29);
        vm.store(address(rv), totalSlot, bytes32(amt));

        // Sanity-check our pokes via the public views.
        assertEq(rv.escrowedExcessOf(borrower), amt, "escrow seeded");
        assertEq(rv.escrowedExcessTotal(), amt, "global escrow seeded");

        // Arm the asset: its `transfer` will re-enter claimEscrow.
        reAsset.arm();

        // The reentrancy must be caught by the OZ v5 ReentrancyGuard:
        //   error ReentrancyGuardReentrantCall();
        bytes4 reentrantSelector = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        vm.prank(borrower);
        vm.expectRevert(reentrantSelector);
        rv.claimEscrow();
    }
}
