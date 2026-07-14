// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Tests for the maxWithdraw / maxRedeem free-liquidity cap fix in
// DynamicFeesVault.
//
// THE FIX (under test)
// --------------------
// maxWithdraw/maxRedeem now cap a lender exit at FREE LIQUIDITY rather than the
// raw asset balance. free = totalAssets() - outstandingDebt, which equals
//   balanceOf(this) - (unvested lender premium
//                      + totalUnsettledRewards
//                      + aggregate excessPendingOwedToBorrowers
//                      + escrowedExcessTotal).
// Both views simulate vesting once and feed that single snapshot to both the
// entitlement math and the new _freeLiquidity(sim). So a lender can never draw
// into funds earmarked for those four liability buckets, and
// withdraw(maxWithdraw(owner)) / redeem(maxRedeem(owner)) cannot revert in
// _burn for lack of cash.
//
// These are PURE-ADDITION tests (a new file). They assert the FIXED behavior.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";

// =====================================================================
// Mocks (mirrored from sibling vault tests)
// =====================================================================

contract MockUSDCWithBlacklist is ERC20 {
    mapping(address => bool) public blacklisted;
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setBlacklisted(address user, bool b) external { blacklisted[user] = b; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[to]) return false; // ReturnFalse mode -> routes to escrow
        return super.transfer(to, amount);
    }
}

contract MockPortfolioFactoryFreeLiq is IPortfolioFactory {
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

// =====================================================================
// Test
// =====================================================================

contract DynamicFeesVaultFreeLiquidityTest is Test {
    DynamicFeesVault public vault;
    MockUSDCWithBlacklist public usdc;
    MockPortfolioFactoryFreeLiq public portfolioFactory;

    address public lp; // == address(this), the sole LP
    address public owner = address(0xA1);
    address public borrower = address(0xB1);
    address public borrower2 = address(0xB2);
    address public feeRecipient = address(0xFEE);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // Hardcoded absolute timestamps (setUp warps to EPOCH_2); never warp backward.
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    uint256 constant SEED = 10_000e6;
    uint256 constant FEE_BPS = 0;

    function setUp() public {
        lp = address(this);
        vm.warp(EPOCH_2);

        usdc = new MockUSDCWithBlacklist();
        portfolioFactory = new MockPortfolioFactoryFreeLiq();

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

        // Production fee curve; at low utilization the borrower share is high, so an over-deposit vests into excess reaching the reduction buckets.
        FeeCalculator fc = new FeeCalculator();
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));

        // Sole LP supplies liquidity.
        usdc.mint(lp, SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, lp);

        // Past the deposit block so maxWithdraw isn't gated to 0 by the
        // same-block flash-loan guard.
        vm.roll(block.number + 1);
    }

    // ----- helpers -----

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        vault.borrowFromPortfolio(amount);
    }

    function _depositRewards(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdc.mint(who, amount);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    function _incentivize(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.incentivize(amount);
    }

    // =================================================================
    // Task 2.1 -- Round-trip no revert (maxWithdraw) with earmarked
    // liabilities present (unvested premium AND an outstanding borrow).
    // Proves OZ withdraw enforcement is sufficient and no _withdraw guard
    // is needed: withdraw(maxWithdraw(lp)) does not revert and transfers
    // exactly maxWithdraw.
    // =================================================================
    function test_roundTrip_maxWithdraw_noRevert() public {
        // Outstanding borrow leaves debt on the books; cash falls below entitlement.
        _borrow(borrower, 3_000e6);
        // Unvested premium at the epoch boundary (elapsed == 0 -> fully unvested).
        _incentivize(1_000e6);
        vm.roll(block.number + 1);

        uint256 maxW = vault.maxWithdraw(lp);
        assertGt(maxW, 0, "precondition: something is withdrawable");

        uint256 lpBalBefore = usdc.balanceOf(lp);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        // Must NOT revert.
        uint256 sharesBurned = vault.withdraw(maxW, lp, lp);
        assertGt(sharesBurned, 0, "shares burned");

        // Exactly maxWithdraw transferred to the LP.
        assertEq(usdc.balanceOf(lp) - lpBalBefore, maxW, "LP received exactly maxWithdraw");
        assertEq(vaultBalBefore - usdc.balanceOf(address(vault)), maxW, "vault paid exactly maxWithdraw");

        // The earmarked liabilities remain covered by the residual cash:
        // remaining balance >= unvested premium + escrow + unsettled.
        uint256 earmarked = vault.getUnvestedLenderPremium()
            + vault.escrowedExcessTotal()
            + vault.getTotalUnsettledRewards();
        assertGe(usdc.balanceOf(address(vault)), earmarked, "earmarked liabilities still covered after exit");
    }

    // =================================================================
    // Task 2.2 -- Round-trip no revert (maxRedeem). assets out <= free.
    // =================================================================
    function test_roundTrip_maxRedeem_noRevert() public {
        _borrow(borrower, 3_000e6);
        _incentivize(1_000e6);
        vm.roll(block.number + 1);

        uint256 free = vault.totalAssets() - _outstandingDebt();
        uint256 maxShares = vault.maxRedeem(lp);
        assertGt(maxShares, 0, "precondition: something is redeemable");

        uint256 lpBalBefore = usdc.balanceOf(lp);

        // Must NOT revert.
        uint256 assetsOut = vault.redeem(maxShares, lp, lp);

        assertEq(usdc.balanceOf(lp) - lpBalBefore, assetsOut, "LP received assetsOut");
        assertLe(assetsOut, free, "redeemed assets must not exceed free liquidity");
    }

    // =================================================================
    // Task 2.3 -- Floor at 0. When earmarked liabilities >= liquid cash,
    // maxWithdraw and maxRedeem must be 0 (no revert, no underflow).
    //
    // Construct: borrow the entire seed (cash -> 0, all NAV is outstanding
    // debt), then deposit a fresh reward stream. The reward cash arrives but
    // is fully unsettled, so it is earmarked as totalUnsettledRewards and not
    // free. free = cash - unsettled = 0, and the rest of NAV is debt out on
    // loan, so the free-liquidity cap is 0 -> both views floor to 0 with no
    // underflow.
    // =================================================================
    function test_floorAtZero_whenEarmarksExceedCash() public {
        // Borrow the entire seed: cash drains to 0, all NAV is loaned out.
        _borrow(borrower, SEED);
        assertEq(usdc.balanceOf(address(vault)), 0, "all cash loaned out");

        // Fresh reward stream: brings R cash back but it is fully unsettled.
        uint256 R = 2_000e6;
        _depositRewards(borrower, R);
        vm.roll(block.number + 1);

        uint256 cash = usdc.balanceOf(address(vault));
        uint256 unsettled = vault.getTotalUnsettledRewards();
        assertEq(cash, R, "cash == reward deposit");
        assertEq(unsettled, R, "rewards fully unsettled pre-vest");

        // free = cash - unsettled = 0 (the rest of NAV is debt out on loan).
        assertEq(_outstandingDebt(), SEED, "full seed still on loan");

        // Must floor to 0, not underflow / revert.
        assertEq(vault.maxWithdraw(lp), 0, "maxWithdraw floors to 0");
        assertEq(vault.maxRedeem(lp), 0, "maxRedeem floors to 0");
    }

    // =================================================================
    // Task 2.4(a) -- Unvested lender premium independently lowers the cap.
    //
    // The earmark holds back exactly the cash it brought in: the premium adds
    // P of liquid cash AND a P-sized deduction, so an LP must NOT be able to
    // withdraw that P. Baseline-without-it = the full liquid cash (rawBalance),
    // which is what the cap would be if P were unencumbered. With the premium
    // present the cap is rawBalance - P.
    // =================================================================
    function test_bucket_unvestedPremium_reducesCap() public {
        _borrow(borrower, 3_000e6);

        // Add unvested premium at the epoch boundary (elapsed == 0 -> fully unvested).
        uint256 P = 1_500e6;
        _incentivize(P);
        vm.roll(block.number + 1);

        uint256 unvested = vault.getUnvestedLenderPremium();
        assertEq(unvested, P, "premium fully unvested at epoch boundary");

        uint256 rawBalance = usdc.balanceOf(address(vault));
        // Baseline without the earmark: an LP could draw all liquid cash
        // (entitlement ~SEED exceeds it, so cash is the binding free amount).
        uint256 baselineFree = rawBalance;
        uint256 maxWWith = vault.maxWithdraw(lp);

        assertLt(maxWWith, baselineFree, "premium lowers the cap below liquid cash");
        assertApproxEqAbs(baselineFree - maxWWith, P, 2, "reduction equals premium size");
    }

    // =================================================================
    // Task 2.4(b) -- totalUnsettledRewards (fresh, pre-vest) lowers the cap.
    // The reward cash arrives but is fully unsettled, so it must be held back:
    // cap == rawBalance - unsettled.
    // =================================================================
    function test_bucket_unsettledRewards_reducesCap() public {
        _borrow(borrower, 3_000e6);

        // Fresh reward deposit: cash arrives but is unsettled (pre-vest), so it
        // is deducted from NAV as totalUnsettledRewards. No time advance keeps
        // it fully unvested.
        uint256 R = 2_000e6;
        _depositRewards(borrower, R);
        vm.roll(block.number + 1);

        uint256 unsettled = vault.getTotalUnsettledRewards();
        assertEq(unsettled, R, "all rewards unsettled pre-vest");

        uint256 rawBalance = usdc.balanceOf(address(vault));
        uint256 baselineFree = rawBalance; // cap if the reward cash were free
        uint256 maxWWith = vault.maxWithdraw(lp);

        assertLt(maxWWith, baselineFree, "unsettled rewards lower the cap below liquid cash");
        assertApproxEqAbs(baselineFree - maxWWith, R, 2, "reduction equals unsettled rewards");
    }

    // =================================================================
    // Task 2.4(c) -- aggregate excessPendingOwedToBorrowers lowers the cap.
    // This drives totalReduction > totalLoanedAssets so the else-branch in
    // _navFromSim fires (excessPendingOwedToBorrowers > 0). This is the
    // lending-review-mandated test for the in-scope reservation.
    //
    // Setup: two borrowers borrow. One repays from a big reward deposit that
    // fully vests, clearing their debt and pushing globalBorrowerPending /
    // totalVestedRewardsApplied above totalLoanedAssets, so the aggregate
    // excess owed to borrowers becomes positive (cash retained in vault,
    // awaiting per-user settlement / payout).
    // =================================================================
    function test_bucket_excessPendingOwedToBorrowers_reducesCap() public {
        // Both borrow small amounts so total loaned is modest.
        _borrow(borrower, 100e6);
        _borrow(borrower2, 100e6);

        // borrower deposits a reward stream much larger than total loaned, so
        // once vested the borrower credit (80%) exceeds total loaned assets.
        _depositRewards(borrower, 5_000e6);

        vm.warp(EPOCH_5);
        // Process global vesting WITHOUT settling per-user, so the borrower
        // credit sits in globalBorrowerPending (not yet applied to a debt).
        // sync() runs _processGlobalVesting then sweeps stale premium.
        vault.sync();
        vm.roll(block.number + 1);

        // Aggregate reduction now exceeds total loaned -> else-branch fires.
        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 reduction = vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();
        assertGt(reduction, totalLoaned, "totalReduction must exceed totalLoanedAssets (else-branch)");

        // free liquidity == totalAssets() - outstandingDebt, and here
        // outstandingDebt == 0 (reduction absorbed it), with the surplus
        // counted as a deduction. The LP cannot withdraw the cash earmarked
        // as excess owed to borrowers.
        uint256 maxW = vault.maxWithdraw(lp);

        // Independent expectation: the excess owed to borrowers is
        // (reduction - totalLoaned). The cap must be at most
        // cash - (that excess + premium + unsettled).
        uint256 excessOwed = reduction - totalLoaned;
        uint256 cash = usdc.balanceOf(address(vault));
        uint256 otherEarmarks = vault.getUnvestedLenderPremium() + vault.getTotalUnsettledRewards();
        uint256 expectedCap = cash > (excessOwed + otherEarmarks) ? cash - (excessOwed + otherEarmarks) : 0;

        // maxW is min(entitlement, free). Free should equal expectedCap here.
        assertLe(maxW, expectedCap + 2, "cap must not exceed cash minus excess-owed earmark");
        assertGt(excessOwed, 0, "excess owed to borrowers must be positive (else-branch active)");

        // And the cap is strictly below the no-excess baseline: prove the
        // bucket reduced it. Baseline = cash minus only premium+unsettled.
        uint256 baselineNoExcess = cash > otherEarmarks ? cash - otherEarmarks : 0;
        assertLt(maxW, baselineNoExcess, "excess-owed bucket strictly lowers the cap");
        assertApproxEqAbs(baselineNoExcess - maxW, excessOwed, 2, "reduction equals excess-owed size");
    }

    // =================================================================
    // Task 2.4(d) -- escrowedExcessTotal lowers the cap (blacklist path).
    // =================================================================
    function test_bucket_escrowedExcess_reducesCap() public {
        // Borrow then deposit rewards larger than debt; blacklist the borrower
        // so the excess payout fails-soft and lands in escrow.
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 2_000e6);

        vm.warp(EPOCH_5);
        usdc.setBlacklisted(borrower, true);
        vault.settleRewards(borrower);
        vm.roll(block.number + 1);

        uint256 escrow = vault.escrowedExcessTotal();
        assertGt(escrow, 0, "precondition: escrow exists");

        uint256 cash = usdc.balanceOf(address(vault));
        uint256 otherEarmarks = vault.getUnvestedLenderPremium()
            + vault.getTotalUnsettledRewards();
        // Account for any aggregate excess-owed that may also be present.
        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 reduction = vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();
        uint256 excessOwed = reduction > totalLoaned ? reduction - totalLoaned : 0;

        // Baseline cap if escrow were not deducted.
        uint256 baselineNoEscrow =
            cash > (otherEarmarks + excessOwed) ? cash - (otherEarmarks + excessOwed) : 0;

        uint256 maxW = vault.maxWithdraw(lp);

        assertLt(maxW, baselineNoEscrow, "escrow bucket strictly lowers the cap");
        assertApproxEqAbs(baselineNoEscrow - maxW, escrow, 2, "reduction equals escrow size");

        // End-to-end: after the LP exits at maxWithdraw, the vault still holds
        // enough to honor claimEscrow for the (now un-blacklisted) borrower.
        vault.withdraw(maxW, lp, lp);
        usdc.setBlacklisted(borrower, false);
        uint256 borrowerBalBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vault.claimEscrow();
        assertEq(
            usdc.balanceOf(borrower) - borrowerBalBefore,
            escrow,
            "borrower claims exactly the escrowed amount after LP exit"
        );
    }

    // =================================================================
    // Task 2.5 -- totalAssets() regression (wrapper split). Independently
    // compute expected NAV = cash + outstandingDebt - deductions and assert
    // totalAssets() matches, then confirm preview round-trips. Guards the
    // _navFromSim / _accrueFeeViewFromSim refactor from changing NAV.
    // =================================================================
    function test_totalAssets_matchesIndependentNav_andPreviewRoundTrips() public {
        // Build a mixed state: borrow, unvested premium, reward stream.
        _borrow(borrower, 2_000e6);
        _incentivize(800e6);
        _borrow(borrower2, 500e6);          // borrower2 needs debt before depositRewards
        _depositRewards(borrower2, 1_000e6);

        // Settle borrower2's stream after partial vest so some becomes excess
        // / debt reduction, exercising the reduction buckets too.
        vm.warp(EPOCH_5);
        vault.sync();
        vm.roll(block.number + 1);

        // Independent NAV reconstruction from public getters, mirroring
        // _navFromSim's definition (not its code path).
        uint256 cash = usdc.balanceOf(address(vault));
        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 reduction = vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();

        uint256 outstandingDebt;
        uint256 excessOwed;
        if (totalLoaned >= reduction) {
            outstandingDebt = totalLoaned - reduction;
        } else {
            excessOwed = reduction - totalLoaned;
        }
        uint256 deductions = vault.getUnvestedLenderPremium()
            + vault.getTotalUnsettledRewards()
            + excessOwed
            + vault.escrowedExcessTotal();
        uint256 gross = cash + outstandingDebt;
        uint256 expectedNav = gross > deductions ? gross - deductions : 0;

        assertEq(vault.totalAssets(), expectedNav, "totalAssets matches independent NAV reconstruction");

        // previewWithdraw/previewRedeem round-trip: previewRedeem(previewWithdraw(x))
        // should recover ~x for a withdrawable amount.
        uint256 free = vault.totalAssets() - outstandingDebt;
        uint256 sampleAssets = free / 4;
        if (sampleAssets > 0) {
            uint256 sharesForAssets = vault.previewWithdraw(sampleAssets);
            uint256 assetsBack = vault.previewRedeem(sharesForAssets);
            // Rounding: previewWithdraw rounds shares up, previewRedeem rounds
            // assets down, so assetsBack <= sampleAssets within 1 wei.
            assertApproxEqAbs(assetsBack, sampleAssets, 1, "preview round-trip within rounding");
            assertLe(assetsBack, sampleAssets, "redeem rounds in vault favor");
        }
    }

    // ----- internal: outstanding debt as _navFromSim defines it -----
    function _outstandingDebt() internal view returns (uint256) {
        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 reduction = vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();
        return totalLoaned > reduction ? totalLoaned - reduction : 0;
    }
}
