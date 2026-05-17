// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";
import {MockBlacklistableERC20} from "../../mocks/MockBlacklistableERC20.sol";

// ============ Issue Summary ============
// Testing the escrow mechanism in DynamicFeesVault that handles USDC-blacklisted borrowers.
//
// Key behaviors under test:
//   1. _transferOrEscrow: low-level call to IERC20.transfer, escrows on failure
//   2. claimEscrow: pulls escrowed funds, reverts on zero, uses safeTransfer (can still fail)
//   3. globalBorrowerPending is decremented even on escrow (no share price depression)
//
// Potential concern identified:
//   - claimEscrow uses safeTransfer which will revert if user is still blacklisted.
//     The escrow amount is zeroed BEFORE the safeTransfer, so if safeTransfer reverts,
//     the entire tx reverts and the zero is rolled back. This is SAFE (state is consistent).
//     But the user cannot claim until un-blacklisted. This is documented behavior.

/**
 * @title MockPortfolioFactory
 */
contract MockPortfolioFactoryEscrow is IPortfolioFactory {
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

/**
 * @title DynamicFeesVaultEscrowTest
 * @notice Tests the escrow mechanism for USDC-blacklisted borrowers in DynamicFeesVault.
 *
 * Uses MockBlacklistableERC20 as the vault asset to simulate real USDC blacklisting
 * behavior where transfers to/from blacklisted addresses revert.
 */
contract DynamicFeesVaultEscrowTest is Test {
    DynamicFeesVault public vault;
    MockBlacklistableERC20 public usdc;
    MockPortfolioFactoryEscrow public portfolioFactory;
    address public owner;
    address public borrower;
    address public borrower2;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // setUp warps to 2*WEEK, so epoch boundaries are at 2*WEEK, 3*WEEK, etc.
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    // Re-declare events for vm.expectEmit
    event ExcessRewardsPaid(address indexed borrower, uint256 amount);
    event ExcessRewardsEscrowed(address indexed borrower, uint256 amount);
    event EscrowClaimed(address indexed borrower, uint256 amount);
    event DebtBalanceUpdated(address indexed borrower, uint256 oldBalance, uint256 newBalance, uint256 rewardsApplied);

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        borrower = address(0x2);
        borrower2 = address(0x3);

        usdc = new MockBlacklistableERC20("USD Coin", "USDC", 6);
        portfolioFactory = new MockPortfolioFactoryEscrow();

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory), address(this), uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Seed vault with liquidity from test contract (lender)
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, address(this));
    }

    // ============ Helpers ============

    /// @dev Borrower borrows `amount` from vault.
    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        vault.borrowFromPortfolio(amount);
    }

    /// @dev Borrower deposits `amount` as rewards into vault.
    function _depositRewards(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.mint(user, amount);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    // ============ Normal Excess Transfer (Not Blacklisted) ============

    /// @notice Verifies excess rewards are transferred directly when borrower is not blacklisted
    function test_settleRewards_excessTransferredDirectly_whenNotBlacklisted() public {
        // Borrow 100, deposit 200 rewards -> excess after debt payoff
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 200e6);

        uint256 balBefore = usdc.balanceOf(borrower);

        // Warp to epoch end and settle
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        assertEq(vault.getDebtBalance(borrower), 0, "Debt should be fully paid");
        assertGt(usdc.balanceOf(borrower), balBefore, "Borrower should receive excess USDC directly");
    }

    /// @notice Verifies ExcessRewardsPaid event is emitted (not Escrowed) for normal transfers
    function test_settleRewards_emitsExcessRewardsPaid_whenNotBlacklisted() public {
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        vm.warp(EPOCH_3);

        // Expect ExcessRewardsPaid to be emitted for the borrower
        // We check topic1 (borrower address) but not the exact amount (depends on fee split)
        vm.expectEmit(true, false, false, false, address(vault));
        emit ExcessRewardsPaid(borrower, 0); // amount doesn't matter, just checking event type + borrower
        vault.settleRewards(borrower);
    }

    // ============ Blacklisted User Gets Escrowed ============

    /// @notice Core test: settlement does NOT revert when borrower is blacklisted;
    ///         excess is escrowed, debt is cleared, and claimable after un-blacklisting.
    function test_settleRewards_escrowed_whenBlacklisted() public {
        // Borrow 100, deposit 300 rewards (will have excess)
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);

        // Blacklist borrower BEFORE settlement
        usdc.setBlacklisted(borrower, true);

        uint256 balBefore = usdc.balanceOf(borrower);

        // Warp and settle -- should NOT revert
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Debt should be cleared (internal accounting, no transfer needed for debt reduction)
        assertEq(vault.getDebtBalance(borrower), 0, "Debt should be cleared even when blacklisted");

        // No USDC transferred to borrower (blacklisted)
        assertEq(usdc.balanceOf(borrower), balBefore, "No USDC should be transferred to blacklisted borrower");

        // Verify escrow was credited by trying to claim (after un-blacklisting)
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), balBefore, "Borrower should receive escrowed amount after un-blacklisting");
    }

    /// @notice Verify ExcessRewardsEscrowed event is emitted when transfer fails
    function test_settleRewards_emitsExcessRewardsEscrowed_whenBlacklisted() public {
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);

        // Expect ExcessRewardsEscrowed to be emitted
        vm.expectEmit(true, false, false, false, address(vault));
        emit ExcessRewardsEscrowed(borrower, 0);
        vault.settleRewards(borrower);
    }

    /// @notice globalBorrowerPending is decremented even when transfer fails (escrowed)
    function test_settleRewards_globalBorrowerPendingDecremented_whenBlacklisted() public {
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);

        // Before settlement, globalBorrowerPending should be 0 (not yet vested)
        assertEq(vault.getGlobalBorrowerPending(), 0, "No pending before vesting");

        vault.settleRewards(borrower);

        // After settlement, globalBorrowerPending should be decremented (nearly 0).
        // Rounding dust of up to 1 wei is expected from the Synthetix-style accumulator math.
        assertLe(vault.getGlobalBorrowerPending(), 1, "globalBorrowerPending should be ~0 after full settlement");
    }

    /// @notice When borrower has no debt, all rewards are excess and get escrowed
    function test_settleRewards_noDebt_allRewardsEscrowed_whenBlacklisted() public {
        // Borrow first so depositRewards doesn't revert with "No debt to repay"
        _borrow(borrower, 1e6);
        _depositRewards(borrower, 100e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Debt should be fully paid, excess escrowed
        assertEq(vault.getDebtBalance(borrower), 0, "Debt should be fully paid");

        // All borrower portion should be escrowed
        // Verify by un-blacklisting and claiming
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), 0, "All borrower rewards should be escrowed and claimable");
    }

    // ============ claimEscrow ============

    /// @notice Happy path: claim escrowed funds after un-blacklisting
    function test_claimEscrow_success() public {
        // Setup: create escrow by blacklisting during settlement
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Un-blacklist and claim
        usdc.setBlacklisted(borrower, false);

        uint256 balBefore = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vault.claimEscrow();

        uint256 balAfter = usdc.balanceOf(borrower);
        assertGt(balAfter, balBefore, "Should receive escrowed USDC");

        // Verify second claim reverts (escrow cleared)
        vm.prank(borrower);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.claimEscrow();
    }

    /// @notice Verify EscrowClaimed event is emitted on successful claim
    function test_claimEscrow_emitsEscrowClaimed() public {
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        usdc.setBlacklisted(borrower, false);

        vm.expectEmit(true, false, false, false, address(vault));
        emit EscrowClaimed(borrower, 0);
        vm.prank(borrower);
        vault.claimEscrow();
    }

    /// @notice claimEscrow reverts with ZeroAmount when no escrow exists
    function test_claimEscrow_revertsOnZero() public {
        vm.prank(borrower);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.claimEscrow();
    }

    /// @notice claimEscrow reverts on second call (escrow already drained)
    function test_claimEscrow_revertsOnZero_afterAlreadyClaimed() public {
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);
        usdc.setBlacklisted(borrower, false);

        // First claim succeeds
        vm.prank(borrower);
        vault.claimEscrow();

        // Second claim reverts
        vm.prank(borrower);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.claimEscrow();
    }

    /// @notice claimEscrow reverts if user is still blacklisted (safeTransfer fails),
    ///         but escrow amount remains intact for future claim.
    function test_claimEscrow_revertsIfStillBlacklisted() public {
        // Setup escrow
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Try to claim while still blacklisted -- safeTransfer should revert
        vm.prank(borrower);
        vm.expectRevert(); // safeTransfer will revert due to blacklist
        vault.claimEscrow();

        // After un-blacklisting, claim should work (escrow amount intact because revert rolled back)
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), 0, "Should claim after un-blacklisting");
    }

    // ============ totalAssets Accounting ============

    /// @notice The key accounting benefit: totalAssets and share price are not depressed
    ///         when excess goes to escrow because globalBorrowerPending is still decremented.
    function test_totalAssets_notDepressed_whenExcessEscrowed() public {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 sharePriceBefore = (totalAssetsBefore * 1e18) / totalSupplyBefore;

        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Share price should not be depressed after escrowed settlement
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = (totalAssetsAfter * 1e18) / totalSupplyBefore;

        // Share price should be >= what it was before (lender premium may increase it)
        assertGe(sharePriceAfter, sharePriceBefore - 1, "Share price should not be depressed after escrow");
    }

    /// @notice globalBorrowerPending is cleared in both the blacklisted and non-blacklisted paths
    function test_totalAssets_globalPendingCleared_whetherBlacklistedOrNot() public {
        // --- Blacklisted path ---
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);
        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        uint256 globalPendingBlacklisted = vault.getGlobalBorrowerPending();

        // --- Non-blacklisted path (borrower2) ---
        _borrow(borrower2, 100e6);
        _depositRewards(borrower2, 300e6);

        vm.warp(EPOCH_4);
        vault.settleRewards(borrower2);

        uint256 globalPendingAfterBoth = vault.getGlobalBorrowerPending();

        // Both settlements should clear globalBorrowerPending for their respective users.
        // Up to 1 wei of rounding dust is expected from the Synthetix-style accumulator.
        assertLe(globalPendingBlacklisted, 1, "Blacklisted path should clear globalBorrowerPending");
        assertLe(globalPendingAfterBoth, 2, "Non-blacklisted path should also clear globalBorrowerPending (2 borrowers = up to 2 wei dust)");
    }

    // ============ Escrow Accumulation ============

    /// @notice Escrow accumulates across multiple settlement epochs
    function test_escrow_accumulates_acrossMultipleSettlements() public {
        // First epoch: borrow, deposit excess, blacklist, settle -> escrow credited
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);
        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Second epoch: borrow again so depositRewards doesn't revert with "No debt to repay",
        // then deposit more rewards (still blacklisted, debt is 0 after first settle)
        usdc.setBlacklisted(borrower, false);
        _borrow(borrower, 1e6);
        _depositRewards(borrower, 100e6);
        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_4);
        vault.settleRewards(borrower);

        // Un-blacklist and claim -- should get accumulated escrow from both epochs
        usdc.setBlacklisted(borrower, false);
        uint256 balBefore = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vault.claimEscrow();

        uint256 claimed = usdc.balanceOf(borrower) - balBefore;
        assertGt(claimed, 0, "Should claim accumulated escrow from multiple epochs");
    }

    // ============ Mixed Scenarios ============

    /// @notice Two borrowers: one blacklisted, one not. Both debts cleared, only non-blacklisted
    ///         gets direct transfer, blacklisted gets escrow.
    function test_settleRewards_oneBlacklistedOneNot() public {
        _borrow(borrower, 100e6);
        _borrow(borrower2, 100e6);

        _depositRewards(borrower, 300e6);
        _depositRewards(borrower2, 300e6);

        usdc.setBlacklisted(borrower, true);
        // borrower2 is NOT blacklisted

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);   // should escrow
        vault.settleRewards(borrower2);  // should transfer directly

        // borrower: only has the USDC from the original borrow (100e6), no excess received
        assertEq(usdc.balanceOf(borrower), 100e6, "Blacklisted borrower only has borrow proceeds, no excess");

        // borrower2: received excess USDC
        assertGt(usdc.balanceOf(borrower2), 0, "Non-blacklisted borrower gets excess USDC");

        // Both debts cleared
        assertEq(vault.getDebtBalance(borrower), 0, "Blacklisted borrower debt cleared");
        assertEq(vault.getDebtBalance(borrower2), 0, "Non-blacklisted borrower debt cleared");

        // borrower can claim after un-blacklisting
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), 0, "Blacklisted borrower can claim escrow after un-blacklisting");
    }

    /// @notice When rewards < debt, no excess is generated, so no escrow or transfer.
    function test_settleRewards_debtExceedsRewards_noExcess_noEscrow() public {
        _borrow(borrower, 500e6);
        _depositRewards(borrower, 100e6);

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // Debt partially reduced, but no excess
        assertGt(vault.getDebtBalance(borrower), 0, "Debt should still remain");

        // No escrow because there's no excess
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.claimEscrow();
    }

    // ============ Edge Case: Blacklist During Partial Epoch ============

    /// @notice Mid-epoch settlement with blacklisted user: partial vesting still escrowed correctly
    function test_settleRewards_midEpoch_blacklisted_partialVesting() public {
        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);

        usdc.setBlacklisted(borrower, true);

        // Warp to mid-epoch (only ~50% vested)
        uint256 midEpoch = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        vm.warp(midEpoch);
        vault.settleRewards(borrower);

        // Warp to epoch end and settle remaining
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        assertEq(vault.getDebtBalance(borrower), 0, "Debt should be fully cleared by epoch end");

        // Claim escrowed excess
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), 0, "Should have escrowed excess from one or both settlements");
    }

    // ============ Access Control ============

    /// @notice claimEscrow is per-sender: borrower2 cannot claim borrower's escrow
    function test_claimEscrow_onlyMsgSender() public {
        // Setup escrow for borrower
        _borrow(borrower, 50e6);
        _depositRewards(borrower, 200e6);

        usdc.setBlacklisted(borrower, true);
        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);
        usdc.setBlacklisted(borrower, false);

        // borrower2 tries to claim -- should get ZeroAmount (no escrow for them)
        vm.prank(borrower2);
        vm.expectRevert(DynamicFeesVault.ZeroAmount.selector);
        vault.claimEscrow();

        // borrower can claim their own
        vm.prank(borrower);
        vault.claimEscrow();
        assertGt(usdc.balanceOf(borrower), 0, "Borrower should claim own escrow");
    }

    // ============ Vault Balance Consistency ============

    /// @notice Vault USDC balance is consistent: escrowed amounts stay in the vault
    ///         until claimed, preserving liquidity for lender withdrawals.
    function test_vaultBalance_escrowedAmountsRemainInVault() public {
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        _borrow(borrower, 100e6);
        _depositRewards(borrower, 300e6);

        uint256 vaultBalAfterDeposit = usdc.balanceOf(address(vault));
        // Vault has: initial liquidity - borrowed + rewards deposited
        assertEq(vaultBalAfterDeposit, vaultBalBefore - 100e6 + 300e6, "Vault balance after borrow+deposit");

        usdc.setBlacklisted(borrower, true);

        vm.warp(EPOCH_3);
        vault.settleRewards(borrower);

        // The escrowed excess remains in the vault (transfer failed, so USDC stays)
        uint256 vaultBalAfterSettle = usdc.balanceOf(address(vault));
        // Debt cleared: 100e6 of the rewards applied to debt (stays in vault)
        // Lender premium: stays in vault
        // Excess: would have been sent out but was escrowed, so stays in vault
        // Therefore vault balance should equal: afterDeposit (nothing left)
        assertEq(vaultBalAfterSettle, vaultBalAfterDeposit, "Escrowed excess stays in vault");

        // After claim, vault loses the escrowed amount
        usdc.setBlacklisted(borrower, false);
        vm.prank(borrower);
        vault.claimEscrow();

        uint256 vaultBalAfterClaim = usdc.balanceOf(address(vault));
        assertLt(vaultBalAfterClaim, vaultBalAfterSettle, "Vault balance decreases after escrow claim");
    }
}
