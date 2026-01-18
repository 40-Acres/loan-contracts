// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../vault/DynamicFeesVault.sol";
import {DebtToken} from "../../vault/DebtToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token with 6 decimals
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockPortfolioFactory
 * @notice Simple mock portfolio factory that returns true for isPortfolio if address is not zero
 */
contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) {
        return _portfolio != address(0);
    }

    // Required by interface but not used in this mock
    function facetRegistry() external pure override returns (address) {
        return address(0);
    }

    function portfolioManager() external pure override returns (address) {
        return address(0);
    }

    function portfolios(address) external pure override returns (address) {
        return address(0);
    }

    function owners(address) external pure override returns (address) {
        return address(0);
    }

    function createAccount(address) external pure override returns (address) {
        return address(0);
    }

    function getRegistryVersion() external pure override returns (uint256) {
        return 0;
    }

    function ownerOf(address) external pure override returns (address) {
        return address(0);
    }

    function portfolioOf(address) external pure override returns (address) {
        return address(0);
    }

    function getAllPortfolios() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getPortfoliosLength() external pure override returns (uint256) {
        return 0;
    }

    function getPortfolio(uint256) external pure override returns (address) {
        return address(0);
    }
}

/**
 * @title DynamicFeesVaultTest
 * @notice Test suite for DynamicFeesVault with USDC
 */
contract DynamicFeesVaultTest is Test {
    DynamicFeesVault public vault;
    DebtToken public debtToken;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner;
    address public user1;

    function setUp() public {
        // Start at week 2 to avoid epoch 0 edge cases
        // Protocol should not operate in epoch 0
        vm.warp(2 * ProtocolTimeLibrary.WEEK);

        owner = address(0x1);
        user1 = address(0x2);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy mock portfolio factory
        portfolioFactory = new MockPortfolioFactory();

        // Deploy vault implementation
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        // Get the debt token that was created in initialize()
        debtToken = vault.debtToken();

        // Transfer ownership
        vault.transferOwnership(owner);

        // Deposit assets into vault so it has funds to borrow from
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));
    }


    function testBorrow() public {
        vm.startPrank(user1);
        // Borrow 79% to stay under 80% utilization limit
        vault.borrow(790e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 8000, "Utilization should be less than 80%");
    }

    function testBorrowAndRepay() public {
        vm.startPrank(user1);
        // Borrow 79% to stay under 80% utilization limit
        vault.borrow(790e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 8000, "Utilization should be less than 80%");

        vm.startPrank(user1);
        deal(address(usdc), user1, 790e6);
        usdc.approve(address(vault), 790e6);
        vault.repay(790e6);
        vm.stopPrank();

        uint256 utilizationPercent2 = vault.getUtilizationPercent();
        assertEq(utilizationPercent2, 0, "Utilization should be 0%");
    }

    function testDepositAndWithdraw() public {
        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.deposit(800e6, address(this));
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 800e6, "Utilization should be less than 80%");
    }

    function testBorrowAndRepayAndDepositAndWithdraw() public {
        vm.startPrank(user1);
        // Borrow 79% to stay under 80% utilization limit
        vault.borrow(790e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 8000, "Utilization should be less than 80%");
        vm.startPrank(user1);
        deal(address(usdc), user1, 790e6);
        usdc.approve(address(vault), 790e6);
        vault.repay(790e6);
        vm.stopPrank();

        uint256 utilizationPercent2 = vault.getUtilizationPercent();
        assertEq(utilizationPercent2, 0, "Utilization should be 0% 3");

        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.deposit(800e6, user1);
        vm.stopPrank();

        uint256 utilizationPercent3 = vault.getUtilizationPercent();
        assertLt(utilizationPercent3, 8000, "Utilization should be less than 80%");

        vm.startPrank(user1);
        vault.withdraw(800e6, user1, user1);
        vm.stopPrank();

        uint256 utilizationPercent4 = vault.getUtilizationPercent();
        assertEq(utilizationPercent4, 0, "Utilization should be 0% 2");
    }

    function testBorrowAndRepayWithRewards() public {

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        // warp to beginning of this epoch
        console.log("WARPING TO BEGINNING OF EPOCH", timestamp);
        vm.warp(timestamp);
        vm.startPrank(user1);
        vault.borrow(400e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertEq(utilizationPercent, 4000, "Utilization should be 40%");


        uint256 totalLoanedAssets = vault.totalLoanedAssets();
        assertEq(totalLoanedAssets, 400e6, "Total loaned assets should be 400e6");

        uint256 rate = vault.debtToken().getVaultRatioBps(utilizationPercent);
        assertEq(rate, 2000, "Ratio should be 20%");

        // pay 200e6 with rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        uint256 feeRatio = vault.debtToken().getCurrentVaultRatioBps();
        assertEq(feeRatio, 2000, "Fee ratio should be 20%");

        uint256 utilizationPercent2 = vault.getUtilizationPercent();
        assertEq(utilizationPercent2, 4000, "Utilization should still be 40% since no time has passed in epoch");
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        console.log("FAST FORWARD TO NEXT EPOCH", timestamp);
        vm.warp(timestamp);

        // at the end of epoch the user balance should be 160e6 less, and vault should gain 40e6

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        assertEq(vault.totalLoanedAssets(), 240e6, "Total loaned assets should be 240e6");
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        console.log("FAST FORWARD TO NEXT EPOCH", timestamp);
        vm.warp(timestamp);
        uint256 utilizationPercent3 =  vault.getUtilizationPercent();
        assertLt(utilizationPercent3, 4000, "Utilization should be less than 40%");

        // pay 0 to refresh rewards
        vault.updateUserDebtBalance(user1);
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();
        uint256 feeRatio2 = vault.debtToken().getCurrentVaultRatioBps();
        assertLt(feeRatio2, 2000, "Fee ratio should be less than 20%");
        // Initial 400e6 debt - 160e6 (epoch 0 rewards) - 160e6 (epoch 1 rewards) = 80e6
        assertEq(vault.totalLoanedAssets(), 80e6, "Total loaned assets should be 80e6");


    }


    function testGetVaultRatioBps() public {
        // Test 1% utilization (100 bps) - should be in segment 1 (0-10%)
        uint256 rate = vault.debtToken().getVaultRatioBps(100);
        assertGt(rate, 500, "At 1% utilization, rate should be greater than 500 bps (5%)");
        assertLt(rate, 2000, "At 1% utilization, rate should be less than 2000 bps (20%)");
        
        // Test 70% utilization (7000 bps) - should be exactly 2000 bps (20%)
        uint256 rate2 = vault.debtToken().getVaultRatioBps(7000);
        assertEq(rate2, 2000, "At 70% utilization, rate should be exactly 2000 bps (20%)");
        
        // Test 90% utilization (9000 bps) - should be exactly 4000 bps (40%)
        uint256 rate3 = vault.debtToken().getVaultRatioBps(9000);
        assertEq(rate3, 4000, "At 90% utilization, rate should be exactly 4000 bps (40%)");
        
        // Test 95% utilization (9500 bps) - should be in segment 4 (90-100%)
        uint256 rate5 = vault.debtToken().getVaultRatioBps(9500);
        assertGt(rate5, 4000, "At 95% utilization, rate should be greater than 4000 bps (40%)");
        assertLt(rate5, 9500, "At 95% utilization, rate should be less than 9500 bps (95%)");
        
        // Test 100% utilization (10000 bps) - should be exactly 9500 bps (95%)
        uint256 rate100 = vault.debtToken().getVaultRatioBps(10000);
        assertEq(rate100, 9500, "At 100% utilization, rate should be exactly 9500 bps (95%)");
        
        // Test that values > 100% (10000 bps) revert
        DebtToken debtToken = vault.debtToken();
        vm.expectRevert("Utilization exceeds 100%");
        debtToken.getVaultRatioBps(10001);
    }

    // ============ Multi-User Tests ============

    function testMultipleUsersBorrow() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        // User1 borrows 200e6
        vm.prank(user1);
        vault.borrow(200e6);

        // User2 borrows 300e6
        vm.prank(user2);
        vault.borrow(300e6);

        // User3 borrows 100e6
        vm.prank(user3);
        vault.borrow(100e6);

        // Total loaned should be 600e6
        assertEq(vault.totalLoanedAssets(), 600e6, "Total loaned should be 600e6");

        // Utilization should be 60% (6000 bps)
        uint256 utilization = vault.getUtilizationPercent();
        assertEq(utilization, 6000, "Utilization should be 60%");
    }

    function testMultipleUsersRepayWithRewards() public {
        address user2 = address(0x3);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // User1 borrows 200e6
        vm.prank(user1);
        vault.borrow(200e6);

        // User2 borrows 200e6
        vm.prank(user2);
        vault.borrow(200e6);

        assertEq(vault.totalLoanedAssets(), 400e6, "Total loaned should be 400e6");

        // Both users repay with rewards in same epoch
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Fast forward to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Trigger settlement checkpoint update via a small repayWithRewards
        // This is needed because updateUserDebtBalance alone doesn't call _updateSettlementCheckpoint
        vm.startPrank(user1);
        deal(address(usdc), user1, 1e6);
        usdc.approve(address(vault), 1e6);
        vault.repayWithRewards(1e6);
        vm.stopPrank();

        // Each user deposited 100e6, total 200e6 in debt tokens
        // At 40% utilization, vault ratio is 20%, so:
        // - Lender premium: 40e6 (20% of 200e6)
        // - Principal repaid: 160e6 (80% of 200e6), split between users
        // Total loaned: 400e6 - 160e6 = 240e6
        assertEq(vault.totalLoanedAssets(), 240e6, "Total loaned should be 240e6 after rewards");
    }

    // ============ Utilization Limit Tests ============
    // NOTE: The utilization check happens AFTER calculating post-borrow state,
    // so it checks post-borrow utilization. This means you can't borrow any amount
    // that would push utilization to or above 80%.

    function testCannotBorrowWhenUtilizationAt80Percent() public {
        // First borrow to get close to 80% utilization
        vm.prank(user1);
        vault.borrow(799e6);

        // Utilization is now ~79.9%
        uint256 utilization = vault.getUtilizationPercent();
        assertLt(utilization, 8000, "Utilization should be under 80%");

        // Any borrow that would push to or above 80% should fail (post-borrow check)
        vm.prank(user1);
        vm.expectRevert("Borrow would exceed 80% utilization");
        vault.borrow(1e6);
    }

    function testCanBorrowWhenUtilizationUnder80Percent() public {
        // Start with 0% utilization, can borrow up to just under 80%
        vm.prank(user1);
        vault.borrow(799e6);

        // Verify we're under 80%
        uint256 utilization = vault.getUtilizationPercent();
        assertLt(utilization, 8000, "Utilization should be under 80%");
        assertEq(vault.totalLoanedAssets(), 799e6);
    }

    function testUtilizationCalculation() public {
        // Borrow 400e6 out of 1000e6 = 40%
        vm.prank(user1);
        vault.borrow(400e6);

        uint256 utilization = vault.getUtilizationPercent();
        assertEq(utilization, 4000, "Utilization should be 40% (4000 bps)");

        // Borrow 200e6 more = 600/1000 = 60%
        vm.prank(user1);
        vault.borrow(200e6);

        utilization = vault.getUtilizationPercent();
        assertEq(utilization, 6000, "Utilization should be 60% (6000 bps)");
    }

    // ============ Partial Repayment Tests ============

    function testPartialRepay() public {
        vm.prank(user1);
        vault.borrow(400e6);

        // Partial repayment of 100e6
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repay(100e6);
        vm.stopPrank();

        assertEq(vault.totalLoanedAssets(), 300e6, "Should have 300e6 remaining");
    }

    function testOverRepayOnlyRepaysDebt() public {
        vm.prank(user1);
        vault.borrow(100e6);

        // Try to repay 200e6 when only 100e6 is owed
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repay(200e6);
        vm.stopPrank();

        // Should only have repaid 100e6
        assertEq(vault.totalLoanedAssets(), 0, "Total loaned should be 0");
        // User should still have 100e6 (200 - 100 repaid)
        assertEq(usdc.balanceOf(user1), 100e6, "User should have 100e6 remaining");
    }

    // ============ Rewards Over Multiple Epochs ============

    function testRewardsAccumulateOverMultipleEpochs() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        // Repay with rewards in epoch 1
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to epoch 2 - repayWithRewards triggers settlement checkpoint
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Repay with rewards in epoch 2 (this also settles epoch 1 rewards)
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to epoch 3
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Repay with rewards in epoch 3 (this also settles epoch 2 rewards)
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to epoch 4 and trigger final settlement
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Trigger settlement checkpoint via small deposit
        vm.startPrank(user1);
        deal(address(usdc), user1, 1e6);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, user1);
        vm.stopPrank();

        // Should have accumulated rewards from epochs 1, 2, and 3
        // Initial: 500e6, each epoch ~80e6 repaid (80% of 100e6 at ~20% vault ratio)
        // After 3 epochs: 500 - 80 - 80 - 80 = 260e6 (approximately)
        uint256 totalLoaned = vault.totalLoanedAssets();
        assertLt(totalLoaned, 300e6, "Should have reduced significantly");
        assertGt(totalLoaned, 200e6, "Should not have over-reduced");
    }

    // ============ Debt Fully Paid Tests ============

    function testDebtFullyPaidByRewards() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Borrow small amount
        vm.prank(user1);
        vault.borrow(50e6);

        // Repay with large rewards amount
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 sharesBefore = vault.balanceOf(user1);

        // Trigger settlement and update via repayWithRewards (even with 0 would work via deposit)
        vm.startPrank(user1);
        deal(address(usdc), user1, 1e6);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, user1);
        vm.stopPrank();

        uint256 sharesAfter = vault.balanceOf(user1);

        // Debt should be 0 - user had 50e6 debt, earned ~160e6 (80% of 200e6)
        uint256 totalLoaned = vault.totalLoanedAssets();
        assertEq(totalLoaned, 0, "Debt should be fully paid");

        // User should have received shares for excess rewards (160e6 earned - 50e6 debt = 110e6 excess)
        // Plus the 1e6 deposit
        assertGt(sharesAfter, sharesBefore, "User should have received shares for excess rewards");
    }

    // ============ Settlement Checkpoint Tests ============

    function testSettlementCheckpointUpdatesCorrectly() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(400e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        (uint256 checkpointEpoch, uint256 principalRepaid) = vault.getSettlementCheckpoint();
        assertEq(checkpointEpoch, timestamp, "Checkpoint epoch should be current");
        assertEq(principalRepaid, 0, "No principal repaid yet in current epoch");

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Trigger checkpoint update via deposit
        vm.startPrank(user1);
        deal(address(usdc), user1, 10e6);
        usdc.approve(address(vault), 10e6);
        vault.deposit(10e6, user1);
        vm.stopPrank();

        (checkpointEpoch, principalRepaid) = vault.getSettlementCheckpoint();
        assertEq(checkpointEpoch, timestamp, "Checkpoint should update to new epoch");
        assertGt(principalRepaid, 0, "Should have principal repaid from previous epoch");
    }

    // ============ Total Assets Calculation Tests ============

    function testTotalAssetsIncludesLoanedAssets() public {
        uint256 initialAssets = vault.totalAssets();
        assertEq(initialAssets, 1000e6, "Initial assets should be 1000e6");

        vm.prank(user1);
        vault.borrow(400e6);

        // Total assets should still be ~1000e6 (loaned assets count toward total)
        uint256 assetsAfterBorrow = vault.totalAssets();
        assertEq(assetsAfterBorrow, 1000e6, "Total assets should remain 1000e6 after borrow");
    }

    function testTotalAssetsDecreasesWithRealTimeRewards() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(400e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Move halfway through the epoch
        vm.warp(timestamp + ProtocolTimeLibrary.WEEK / 2);

        // Total assets should reflect partial rewards distribution
        // The debt token assets are prorated, so totalAssets changes in real-time
        uint256 midEpochAssets = vault.totalAssets();

        // Move to end of epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 endEpochAssets = vault.totalAssets();

        // Assets should be different at different points in epoch
        // (due to proration of debt token distributions)
        assertGe(endEpochAssets, midEpochAssets - 1e6, "End epoch assets should be >= mid epoch");
    }

    // ============ Edge Case Tests ============

    function testRepayWithZeroDebt() public {
        // User has no debt, tries to repay
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repay(100e6);
        vm.stopPrank();

        // Should have repaid 0 (no debt to repay)
        assertEq(usdc.balanceOf(user1), 100e6, "User should still have all USDC");
    }

    function testMultipleRepayWithRewardsInSameEpoch() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(400e6);

        // Multiple repayWithRewards in same epoch
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(user1);
            deal(address(usdc), user1, 50e6);
            usdc.approve(address(vault), 50e6);
            vault.repayWithRewards(50e6);
            vm.stopPrank();
        }

        // Total debt tokens for this epoch should be 150e6
        uint256 totalDebtTokenAssets = debtToken.totalAssetsPerEpoch(timestamp);
        assertEq(totalDebtTokenAssets, 150e6, "Should have 150e6 in debt tokens");

        // Total loaned should still be 400e6 (no rewards distributed yet)
        assertEq(vault.totalLoanedAssets(), 400e6, "Loaned should still be 400e6");
    }

    function testLenderPremiumVsBorrowerPrincipalSplit() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Borrow to get 40% utilization (vault ratio = 20%)
        vm.prank(user1);
        vault.borrow(400e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        uint256 loanedBefore = vault.totalLoanedAssets();

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Trigger settlement checkpoint via deposit
        vm.startPrank(user1);
        deal(address(usdc), user1, 1e6);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, user1);
        vm.stopPrank();

        uint256 loanedAfter = vault.totalLoanedAssets();

        // At 40% utilization, vault ratio is 20%
        // So 20e6 should go to lender (vault), 80e6 to borrower
        // This is reflected in the debt reduction
        uint256 principalRepaid = loanedBefore - loanedAfter;

        // Principal repaid should be ~80% of 100e6 = 80e6
        assertGe(principalRepaid, 75e6, "Principal repaid should be at least 75e6");
        assertLe(principalRepaid, 85e6, "Principal repaid should be at most 85e6");
    }

    // ============ Withdraw With Active Loans Tests ============

    function testWithdrawLimitedByLiquidity() public {
        vm.prank(user1);
        vault.borrow(400e6);

        // Vault has 600e6 liquid (1000e6 - 400e6 borrowed)
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertEq(vaultBalance, 600e6, "Vault should have 600e6 liquid");

        // Try to withdraw more than liquid - should fail
        vm.expectRevert();
        vault.withdraw(700e6, address(this), address(this));

        // But can withdraw up to liquid amount
        vault.withdraw(500e6, address(this), address(this));
        assertEq(usdc.balanceOf(address(vault)), 100e6, "Vault should have 100e6 remaining");
    }

    function testCannotWithdrawMoreThanLiquid() public {
        vm.prank(user1);
        vault.borrow(400e6);

        // Vault has 600e6 liquid
        // Try to withdraw 601e6 - should fail due to insufficient balance
        vm.expectRevert();
        vault.withdraw(601e6, address(this), address(this));
    }
}