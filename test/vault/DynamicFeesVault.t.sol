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

        // Transfer ownership (Ownable2Step requires acceptance)
        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

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
        DebtToken _debtToken = vault.debtToken();
        vm.expectRevert("Utilization exceeds 100%");
        _debtToken.getVaultRatioBps(10001);
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

    // ============ Multi-User Rewards with Early Repayment Tests ============

    function testMultipleUsersRepayWithRewardsEarlyRepayerGetsShares() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // User1 borrows 50e6 (small loan, will repay early with excess)
        vm.prank(user1);
        vault.borrow(50e6);

        // User2 borrows 200e6
        vm.prank(user2);
        vault.borrow(200e6);

        // User3 borrows 200e6
        vm.prank(user3);
        vault.borrow(200e6);

        // Total loaned: 450e6, utilization: 45%
        assertEq(vault.totalLoanedAssets(), 450e6, "Total loaned should be 450e6");
        uint256 utilization = vault.getUtilizationPercent();
        assertEq(utilization, 4500, "Utilization should be 45%");

        // All users repay with rewards in same epoch
        // User1 repays with 200e6 (way more than their 50e6 debt)
        // At 45% utilization, vault ratio is 20%, so user1 earns 80% of 200e6 = 160e6
        // Since debt is only 50e6, user1 should get 110e6 as vault shares
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // User2 repays with 100e6
        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // User3 repays with 100e6
        vm.startPrank(user3);
        deal(address(usdc), user3, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Record user1 shares before epoch change
        uint256 user1SharesBefore = vault.balanceOf(user1);
        console.log("User1 shares before epoch change:", user1SharesBefore);

        // Fast forward to next epoch to settle rewards
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Update user1's debt balance to trigger reward settlement
        // This is when excess rewards are converted to vault shares
        vault.updateUserDebtBalance(user1);

        uint256 user1SharesAfter = vault.balanceOf(user1);
        console.log("User1 shares after settlement:", user1SharesAfter);

        // User1 deposited 200e6 in rewards, at 45% utilization vault ratio is 20%
        // So user1 earns 80% of 200e6 = 160e6 towards their 50e6 debt
        // That leaves 110e6 excess which should be minted as vault shares
        assertGt(user1SharesAfter, user1SharesBefore, "User1 should receive shares for excess rewards");

        // User1's debt should be 0
        assertEq(vault.getDebtBalance(user1), 0, "User1 debt should be fully paid");

        // Update and check user2's debt (should still have debt remaining)
        vault.updateUserDebtBalance(user2);
        uint256 user2Debt = vault.getDebtBalance(user2);
        assertGt(user2Debt, 0, "User2 should still have debt");
        assertLt(user2Debt, 200e6, "User2 debt should be reduced by rewards");

        // Update and check user3's debt
        vault.updateUserDebtBalance(user3);
        uint256 user3Debt = vault.getDebtBalance(user3);
        assertGt(user3Debt, 0, "User3 should still have debt");
        assertLt(user3Debt, 200e6, "User3 debt should be reduced by rewards");

        console.log("User1 shares gained:", user1SharesAfter - user1SharesBefore);
        console.log("User2 remaining debt:", user2Debt);
        console.log("User3 remaining debt:", user3Debt);
    }

    // ============ 100% Utilization with Daily Fee Ratio Tests ============

    function testHighUtilizationWithWithdrawalAndDailyFeeRatioCheck() public {
        address depositor = address(this);
        address borrower = user1;

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Initial state: depositor has 1000e6 in vault
        // Vault currently has 1000e6 from setUp()

        // Borrower takes a loan for ~80% utilization
        vm.prank(borrower);
        vault.borrow(799e6); // Just under 80% to pass the check

        uint256 initialDebt = vault.getDebtBalance(borrower);
        assertEq(initialDebt, 799e6, "Initial debt should be 799e6");

        uint256 utilization = vault.getUtilizationPercent();
        assertGe(utilization, 7900, "Utilization should be ~79.9%");
        assertLt(utilization, 8000, "Utilization should be under 80%");

        console.log("Post-borrow utilization:", utilization);
        console.log("Initial borrower debt:", initialDebt);

        // Depositor withdraws some funds to push utilization to ~90%
        // At 90% utilization, fee ratio should be 40% (4000 bps)
        vault.withdraw(112e6, depositor, depositor);

        uint256 utilizationAfterWithdraw = vault.getUtilizationPercent();
        console.log("Post-withdraw utilization:", utilizationAfterWithdraw);

        // Should be around 90% utilization now
        assertGe(utilizationAfterWithdraw, 8900, "Utilization should be >=89%");
        assertLe(utilizationAfterWithdraw, 9100, "Utilization should be <=91%");

        // Check fee ratio at high utilization
        uint256 feeRatio = vault.debtToken().getCurrentVaultRatioBps();
        console.log("Fee ratio at high utilization:", feeRatio);

        // At ~90% utilization, fee ratio should be ~40% (4000 bps)
        assertGe(feeRatio, 3800, "Fee ratio should be >=38% at ~90% utilization");
        assertLe(feeRatio, 4200, "Fee ratio should be <=42%");

        // Now borrower starts repaying with rewards over the week
        // Check fee ratio and debt daily as utilization changes
        uint256 dailyRewardAmount = 50e6;
        uint256 totalRewardsDeposited = 0;
        uint256 previousDebt = initialDebt;

        // Track cumulative expected debt reduction
        // At the fee ratio, borrower keeps (100% - feeRatio) of rewards
        // e.g., at 40% fee ratio, borrower gets 60% of rewards towards debt

        for (uint256 day = 1; day <= 7; day++) {
            // Advance 1 day
            vm.warp(timestamp + (day * 1 days));

            // Get current state before repayment
            uint256 currentUtilization = vault.getUtilizationPercent();
            uint256 currentFeeRatio = vault.debtToken().getCurrentVaultRatioBps();
            uint256 expectedFeeRatio = vault.debtToken().getVaultRatioBps(currentUtilization);

            // Update user debt balance to apply vested rewards
            // Rewards vest linearly over the epoch, so debt decreases over time
            vault.updateUserDebtBalance(borrower);
            uint256 currentDebt = vault.getDebtBalance(borrower);

            console.log("--- Day", day, "---");
            console.log("  Utilization:", currentUtilization);
            console.log("  Fee ratio:", currentFeeRatio);
            console.log("  Borrower debt:", currentDebt);

            // Fee ratio should match the expected ratio for current utilization
            assertEq(currentFeeRatio, expectedFeeRatio, "Fee ratio should match utilization-based rate");

            // Debt should be decreasing or stable as rewards vest
            // (It may not decrease every day if no new rewards have vested yet)
            assertLe(currentDebt, previousDebt, "Debt should not increase");

            // Borrower repays with rewards
            vm.startPrank(borrower);
            deal(address(usdc), borrower, dailyRewardAmount);
            usdc.approve(address(vault), dailyRewardAmount);
            vault.repayWithRewards(dailyRewardAmount);
            vm.stopPrank();

            totalRewardsDeposited += dailyRewardAmount;
            previousDebt = currentDebt;
        }

        console.log("Total rewards deposited:", totalRewardsDeposited);

        // Fast forward to next epoch to settle all rewards
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Trigger final settlement
        vault.updateUserDebtBalance(borrower);

        uint256 finalUtilization = vault.getUtilizationPercent();
        uint256 finalFeeRatio = vault.debtToken().getCurrentVaultRatioBps();
        uint256 finalDebt = vault.getDebtBalance(borrower);

        console.log("--- After epoch settlement ---");
        console.log("  Final utilization:", finalUtilization);
        console.log("  Final fee ratio:", finalFeeRatio);
        console.log("  Final borrower debt:", finalDebt);

        // Utilization should have decreased from rewards
        assertLt(finalUtilization, utilizationAfterWithdraw, "Utilization should decrease after repayments");

        // Fee ratio should match the new utilization
        uint256 expectedFinalRatio = vault.debtToken().getVaultRatioBps(finalUtilization);
        assertEq(finalFeeRatio, expectedFinalRatio, "Final fee ratio should match utilization");

        // Debt should be reduced
        assertLe(finalDebt, initialDebt, "Debt should not increase");

        // Calculate actual debt reduction
        uint256 debtReduction = initialDebt - finalDebt;
        console.log("  Total debt reduction:", debtReduction);

        // Verify the debt reduction is at least some portion of rewards
        // Borrower should receive roughly 60-80% of rewards (depending on varying fee ratio)
        uint256 minExpectedReduction = (totalRewardsDeposited * 50) / 100; // At least 50%
        assertGe(debtReduction, minExpectedReduction, "Debt reduction should be at least 50% of rewards");

        // If debt went to 0, check if user received vault shares for excess
        if (finalDebt == 0) {
            uint256 borrowerShares = vault.balanceOf(borrower);
            console.log("  Borrower vault shares:", borrowerShares);
            // Borrower should have received shares if rewards exceeded debt
            if (debtReduction < initialDebt) {
                // This shouldn't happen - if debt is 0, debtReduction should equal initialDebt
                revert("Inconsistent state: debt is 0 but debtReduction < initialDebt");
            }
            // The excess rewards beyond debt become vault shares
            // earned = borrower's share of rewards, if earned > debt, excess becomes shares
        }
    }

    function testHighUtilizationSingleRewardPaymentDailyDebtCheck() public {
        address depositor = address(this);
        address borrower = user1;

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Borrower takes a loan for ~80% utilization
        vm.prank(borrower);
        vault.borrow(799e6);

        uint256 initialDebt = vault.getDebtBalance(borrower);
        assertEq(initialDebt, 799e6, "Initial debt should be 799e6");

        console.log("Initial borrower debt:", initialDebt);

        // Depositor withdraws almost all liquid funds to push utilization to ~100%
        // After borrow: 799e6 loaned, 1000e6 total, 201e6 liquid
        // Withdraw 200e6 to leave only 1e6 liquid -> utilization = 799/800 = 99.875%
        uint256 liquidBalance = usdc.balanceOf(address(vault));
        console.log("Liquid balance before withdraw:", liquidBalance);
        vault.withdraw(liquidBalance - 1e6, depositor, depositor);

        uint256 utilizationAfterWithdraw = vault.getUtilizationPercent();
        console.log("Post-withdraw utilization:", utilizationAfterWithdraw);
        assertGe(utilizationAfterWithdraw, 9900, "Utilization should be >=99%");

        // Get initial fee ratio at ~100% utilization (should be close to 95%)
        uint256 initialFeeRatio = vault.debtToken().getCurrentVaultRatioBps();
        console.log("Initial fee ratio:", initialFeeRatio);
        assertGe(initialFeeRatio, 9000, "Fee ratio should be >=90% at ~100% utilization");

        // Borrower repays with ALL rewards at the beginning of the week (single payment)
        uint256 totalRewardAmount = 350e6;
        vm.startPrank(borrower);
        deal(address(usdc), borrower, totalRewardAmount);
        usdc.approve(address(vault), totalRewardAmount);
        vault.repayWithRewards(totalRewardAmount);
        vm.stopPrank();

        console.log("Rewards deposited at start of epoch:", totalRewardAmount);
        console.log("");

        // Track debt each day as rewards vest linearly over the epoch
        uint256 previousDebt = initialDebt;

        for (uint256 day = 0; day <= 7; day++) {
            // Warp to this day of the epoch
            vm.warp(timestamp + (day * 1 days));

            // Update vault state to sync settlement checkpoint, then update user's debt
            vault.sync();
            vault.updateUserDebtBalance(borrower);

            uint256 currentDebt = vault.getDebtBalance(borrower);
            uint256 currentUtilization = vault.getUtilizationPercent();
            uint256 currentFeeRatio = vault.debtToken().getCurrentVaultRatioBps();

            // Calculate how much of the epoch has passed (for reference)
            uint256 epochProgress = (day * 100) / 7; // percentage

            console.log("--- Day", day, "---");
            console.log("  Epoch progress:", epochProgress, "%");
            console.log("  Utilization:", currentUtilization);
            console.log("  Fee ratio:", currentFeeRatio);
            console.log("  Borrower debt:", currentDebt);

            if (day > 0) {
                uint256 debtReduction = previousDebt > currentDebt ? previousDebt - currentDebt : 0;
                console.log("  Debt reduced since yesterday:", debtReduction);
            }

            // Fee ratio should match the expected ratio for current utilization
            uint256 expectedFeeRatio = vault.debtToken().getVaultRatioBps(currentUtilization);
            assertEq(currentFeeRatio, expectedFeeRatio, "Fee ratio should match utilization-based rate");

            // Debt should be decreasing or stable as rewards vest
            assertLe(currentDebt, previousDebt, "Debt should not increase");

            // After day 0, debt should start decreasing as rewards vest
            if (day >= 2) {
                assertLt(currentDebt, initialDebt, "Debt should be less than initial after rewards vest");
            }

            previousDebt = currentDebt;
        }

        // Fast forward to next epoch to fully settle
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Final settlement - update vault first, then user's debt
        vault.sync();
        vault.updateUserDebtBalance(borrower);

        uint256 finalDebt = vault.getDebtBalance(borrower);
        uint256 finalUtilization = vault.getUtilizationPercent();
        uint256 finalFeeRatio = vault.debtToken().getCurrentVaultRatioBps();

        console.log("");
        console.log("--- After epoch settlement ---");
        console.log("  Final utilization:", finalUtilization);
        console.log("  Final fee ratio:", finalFeeRatio);
        console.log("  Final borrower debt:", finalDebt);

        uint256 totalDebtReduction = initialDebt - finalDebt;
        console.log("  Total debt reduction:", totalDebtReduction);

        // Calculate borrower's effective share of rewards
        uint256 borrowerSharePercent = (totalDebtReduction * 100) / totalRewardAmount;
        console.log("  Borrower received", borrowerSharePercent, "% of rewards toward debt");

        // Verify debt was reduced
        assertLt(finalDebt, initialDebt, "Debt should be reduced");

        // At ~90% initial utilization (~40% fee), borrower should get ~60% of rewards
        // As utilization drops, borrower gets more (up to 80% at 20% fee)
        // So borrower should receive roughly 50-75% of rewards toward debt
        uint256 minExpectedReduction = (totalRewardAmount * 45) / 100; // At least 45%
        assertGe(totalDebtReduction, minExpectedReduction, "Debt reduction should be at least 45% of rewards");

        // Verify fee ratio dropped as utilization decreased
        assertLt(finalFeeRatio, initialFeeRatio, "Fee ratio should decrease as utilization drops");
    }

    function testFeeRatioProgressionOverEpoch() public {
        // Test that verifies fee ratio correctly tracks utilization as it decreases
        address depositor = address(this);
        address borrower = user1;

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Setup: Start with 500e6 total assets
        vault.withdraw(500e6, depositor, depositor);
        assertEq(vault.totalAssets(), 500e6, "Total assets should be 500e6");

        // Borrow to get 60% utilization
        vm.prank(borrower);
        vault.borrow(300e6); // 60% utilization

        uint256 initialUtilization = vault.getUtilizationPercent();
        console.log("Initial utilization:", initialUtilization);
        assertEq(initialUtilization, 6000, "Should be 60%");

        // At 60% utilization, fee ratio should be 20% (flat segment 10-70%)
        uint256 initialFeeRatio = vault.debtToken().getCurrentVaultRatioBps();
        assertEq(initialFeeRatio, 2000, "Fee ratio should be 20% at 60% utilization");

        // Record utilization and fee ratio at each daily checkpoint
        uint256[] memory dailyUtilizations = new uint256[](7);
        uint256[] memory dailyFeeRatios = new uint256[](7);

        for (uint256 day = 0; day < 7; day++) {
            // Move forward in time (but stay in same epoch)
            vm.warp(timestamp + (day * 1 days));

            dailyUtilizations[day] = vault.getUtilizationPercent();
            dailyFeeRatios[day] = vault.debtToken().getCurrentVaultRatioBps();

            console.log("Day", day);
            console.log("  Utilization:", dailyUtilizations[day]);
            console.log("  Fee ratio:", dailyFeeRatios[day]);

            // Verify fee ratio matches expected for utilization
            uint256 expected = vault.debtToken().getVaultRatioBps(dailyUtilizations[day]);
            assertEq(dailyFeeRatios[day], expected, "Fee ratio should match utilization curve");

            // Borrower repays with rewards to gradually add assets to vault
            vm.startPrank(borrower);
            deal(address(usdc), borrower, 30e6);
            usdc.approve(address(vault), 30e6);
            vault.repayWithRewards(30e6);
            vm.stopPrank();
        }

        // Move to next epoch and settle
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);
        vault.updateUserDebtBalance(borrower);

        uint256 finalUtilization = vault.getUtilizationPercent();
        uint256 finalFeeRatio = vault.debtToken().getCurrentVaultRatioBps();

        console.log("Final utilization:", finalUtilization);
        console.log("Final fee ratio:", finalFeeRatio);

        // Utilization should have decreased (debt reduced, assets increased)
        assertLt(finalUtilization, initialUtilization, "Utilization should decrease after epoch");

        // Fee ratio should match the new utilization
        uint256 expectedFinal = vault.debtToken().getVaultRatioBps(finalUtilization);
        assertEq(finalFeeRatio, expectedFinal, "Final fee ratio should match utilization");

        // Borrower's debt should be reduced
        uint256 finalDebt = vault.getDebtBalance(borrower);
        assertLt(finalDebt, 300e6, "Debt should be reduced");
        console.log("Final debt:", finalDebt);
    }

    // ============ Pause Mechanism Tests ============

    function testPauseByOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");
    }

    function testPauseByAuthorizedPauser() public {
        address pauser = address(0x5);

        // Add pauser
        vm.prank(owner);
        vault.addPauser(pauser);
        assertTrue(vault.isPauser(pauser), "Should be a pauser");

        // Pause as pauser
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");
    }

    function testCannotPauseIfNotAuthorized() public {
        address notPauser = address(0x6);

        vm.prank(notPauser);
        vm.expectRevert(DynamicFeesVault.NotPauser.selector);
        vault.pause();
    }

    function testOnlyOwnerCanUnpause() public {
        // Pause the vault
        vm.prank(owner);
        vault.pause();

        // Add a pauser
        address pauser = address(0x5);
        vm.prank(owner);
        vault.addPauser(pauser);

        // Pauser cannot unpause
        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();

        // Owner can unpause
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused(), "Vault should be unpaused");
    }

    function testCannotBorrowWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.borrow(100e6);
    }

    function testCannotRepayWhenPaused() public {
        // First borrow
        vm.prank(user1);
        vault.borrow(100e6);

        // Pause
        vm.prank(owner);
        vault.pause();

        // Cannot repay
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.repay(100e6);
        vm.stopPrank();
    }

    function testCannotRepayWithRewardsWhenPaused() public {
        // First borrow
        vm.prank(user1);
        vault.borrow(100e6);

        // Pause
        vm.prank(owner);
        vault.pause();

        // Cannot repay with rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.repayWithRewards(100e6);
        vm.stopPrank();
    }

    function testCannotDepositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.deposit(100e6, user1);
        vm.stopPrank();
    }

    function testCannotWithdrawWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.withdraw(100e6, address(this), address(this));
    }

    function testCanSyncWhenPaused() public {
        // Sync should still work when paused (for settlement purposes)
        vm.prank(owner);
        vault.pause();

        // This should not revert
        vault.sync();
    }

    function testCanUpdateUserDebtBalanceWhenPaused() public {
        // First borrow and repay with rewards
        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        // Pause
        vm.prank(owner);
        vault.pause();

        // Should still be able to update debt balance (for settlement)
        vault.updateUserDebtBalance(user1);
    }

    function testAddAndRemovePauser() public {
        address pauser = address(0x5);

        // Add pauser
        vm.prank(owner);
        vault.addPauser(pauser);
        assertTrue(vault.isPauser(pauser));

        // Cannot add same pauser again
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.AlreadyPauser.selector);
        vault.addPauser(pauser);

        // Remove pauser
        vm.prank(owner);
        vault.removePauser(pauser);
        assertFalse(vault.isPauser(pauser));

        // Cannot remove non-pauser
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.NotAPauser.selector);
        vault.removePauser(pauser);
    }

    // ============ Fuzz Tests ============

    function testFuzzBorrowAndRepay(uint256 borrowAmount) public {
        // Bound to reasonable values (1 USDC to 79% of vault)
        borrowAmount = bound(borrowAmount, 1e6, 790e6);

        vm.prank(user1);
        vault.borrow(borrowAmount);

        assertEq(vault.getDebtBalance(user1), borrowAmount, "Debt should match borrow amount");
        assertEq(vault.totalLoanedAssets(), borrowAmount, "Total loaned should match");

        // Repay full amount
        vm.startPrank(user1);
        deal(address(usdc), user1, borrowAmount);
        usdc.approve(address(vault), borrowAmount);
        vault.repay(borrowAmount);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be 0 after repay");
        assertEq(vault.totalLoanedAssets(), 0, "Total loaned should be 0");
    }

    function testFuzzRepayWithRewards(uint256 borrowAmount, uint256 rewardAmount) public {
        // Bound to reasonable values
        borrowAmount = bound(borrowAmount, 10e6, 500e6);
        rewardAmount = bound(rewardAmount, 1e6, 200e6);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(borrowAmount);

        uint256 initialDebt = vault.getDebtBalance(user1);

        // Repay with rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, rewardAmount);
        usdc.approve(address(vault), rewardAmount);
        vault.repayWithRewards(rewardAmount);
        vm.stopPrank();

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Settle
        vault.updateUserDebtBalance(user1);

        uint256 finalDebt = vault.getDebtBalance(user1);

        // Debt should decrease (or go to 0)
        assertLe(finalDebt, initialDebt, "Debt should not increase after rewards");

        // If rewards were enough to pay off debt, check for shares
        if (finalDebt == 0 && rewardAmount > borrowAmount) {
            // User might have received shares for excess
            uint256 shares = vault.balanceOf(user1);
            // Just verify no revert occurred
        }
    }

    function testFuzzVaultRatioBps(uint256 utilizationBps) public view {
        // Bound to 0-100%
        utilizationBps = bound(utilizationBps, 0, 10000);

        uint256 ratio = vault.debtToken().getVaultRatioBps(utilizationBps);

        // Verify ratio is within expected bounds
        assertGe(ratio, 500, "Ratio should be at least 5%");
        assertLe(ratio, 9500, "Ratio should be at most 95%");

        // Verify specific ranges
        if (utilizationBps <= 1000) {
            // 0-10%: 5% to 20%
            assertLe(ratio, 2000, "Ratio should be <= 20% for low utilization");
        } else if (utilizationBps <= 7000) {
            // 10-70%: Flat at 20%
            assertEq(ratio, 2000, "Ratio should be 20% for mid utilization");
        } else if (utilizationBps <= 9000) {
            // 70-90%: 20% to 40%
            assertGe(ratio, 2000, "Ratio should be >= 20%");
            assertLe(ratio, 4000, "Ratio should be <= 40%");
        } else {
            // 90-100%: 40% to 95%
            assertGe(ratio, 4000, "Ratio should be >= 40%");
        }
    }

    // ============ Stale Checkpoint Test ============

    function testStaleCheckpointRecovery() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // User borrows and repays with rewards
        vm.prank(user1);
        vault.borrow(400e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to next epoch - this is when rewards from first epoch vest
        // User needs to have deposited in previous epoch to earn in this one
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Deposit more rewards in this epoch (user had balance from previous epoch)
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Now fast forward 10 weeks without any interaction
        timestamp = timestamp + (10 * ProtocolTimeLibrary.WEEK);
        vm.warp(timestamp);

        // Sync should still work and process up to MAX_EPOCH_ITERATIONS
        vault.sync();

        // Should be able to continue normal operations
        vault.updateUserDebtBalance(user1);

        uint256 debt = vault.getDebtBalance(user1);
        // Debt should have been reduced from the rewards
        // User deposited 200e6 total, at ~40% utilization they get ~80% = ~160e6 toward debt
        // Initial debt 400e6 - 160e6 = ~240e6
        assertLt(debt, 400e6, "Debt should be reduced after stale recovery");
        console.log("Debt after stale recovery:", debt);
    }

    function testVeryStaleCheckpoint() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // User borrows and repays with rewards
        vm.prank(user1);
        vault.borrow(400e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Fast forward 60 weeks (beyond MAX_EPOCH_ITERATIONS of 52)
        timestamp = timestamp + (60 * ProtocolTimeLibrary.WEEK);
        vm.warp(timestamp);

        // Sync should still work (limited by MAX_EPOCH_ITERATIONS)
        vault.sync();

        // Should still be operational
        vault.updateUserDebtBalance(user1);

        // The system should have processed some rewards even if not all epochs
        uint256 debt = vault.getDebtBalance(user1);
        console.log("Debt after very stale recovery:", debt);
    }

    // ============ Multiple Concurrent Borrowers Test ============

    function testMultipleConcurrentBorrowersSettling() public {
        address user2 = address(0x3);
        address user3 = address(0x4);
        address user4 = address(0x5);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Multiple users borrow different amounts
        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(user2);
        vault.borrow(150e6);

        vm.prank(user3);
        vault.borrow(200e6);

        vm.prank(user4);
        vault.borrow(100e6);

        // Total borrowed: 550e6, utilization: 55%
        assertEq(vault.totalLoanedAssets(), 550e6);

        // All users repay with rewards in the same epoch
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 75e6);
        usdc.approve(address(vault), 75e6);
        vault.repayWithRewards(75e6);
        vm.stopPrank();

        vm.startPrank(user3);
        deal(address(usdc), user3, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user4);
        deal(address(usdc), user4, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Sync vault state
        vault.sync();

        // All users settle in the same block
        vault.updateUserDebtBalance(user1);
        vault.updateUserDebtBalance(user2);
        vault.updateUserDebtBalance(user3);
        vault.updateUserDebtBalance(user4);

        // Verify all debts are reduced
        uint256 debt1 = vault.getDebtBalance(user1);
        uint256 debt2 = vault.getDebtBalance(user2);
        uint256 debt3 = vault.getDebtBalance(user3);
        uint256 debt4 = vault.getDebtBalance(user4);

        console.log("User1 debt:", debt1);
        console.log("User2 debt:", debt2);
        console.log("User3 debt:", debt3);
        console.log("User4 debt:", debt4);

        assertLt(debt1, 100e6, "User1 debt should be reduced");
        assertLt(debt2, 150e6, "User2 debt should be reduced");
        assertLt(debt3, 200e6, "User3 debt should be reduced");
        assertLt(debt4, 100e6, "User4 debt should be reduced");

        // Total debt should be reduced
        uint256 totalDebt = debt1 + debt2 + debt3 + debt4;
        assertLt(totalDebt, 550e6, "Total debt should be reduced");
        assertEq(vault.totalLoanedAssets(), totalDebt, "Total loaned should match sum of debts");
    }

    function testConcurrentSettlementOrder() public {
        address user2 = address(0x3);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Both users borrow
        vm.prank(user1);
        vault.borrow(200e6);

        vm.prank(user2);
        vault.borrow(200e6);

        // Both repay with same amount of rewards
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

        // Move to next epoch
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Get debt before any settlement
        uint256 user1DebtBefore = vault.getDebtBalance(user1);
        uint256 user2DebtBefore = vault.getDebtBalance(user2);

        // Settle user1 first
        vault.updateUserDebtBalance(user1);
        uint256 user1DebtAfter = vault.getDebtBalance(user1);

        // Settle user2 second
        vault.updateUserDebtBalance(user2);
        uint256 user2DebtAfter = vault.getDebtBalance(user2);

        // Both should have same reduction since they deposited same rewards
        uint256 user1Reduction = user1DebtBefore - user1DebtAfter;
        uint256 user2Reduction = user2DebtBefore - user2DebtAfter;

        console.log("User1 reduction:", user1Reduction);
        console.log("User2 reduction:", user2Reduction);

        // Reductions should be equal (or very close due to rounding)
        assertApproxEqAbs(user1Reduction, user2Reduction, 1e6, "Both users should have similar debt reduction");
    }
}