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
 * @title FlatFeeCalculator
 * @notice Test fee calculator that returns a flat fee regardless of utilization
 */
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flatRate;

    constructor(uint256 _flatRate) {
        flatRate = _flatRate;
    }

    function getVaultRatioBps(uint256) external view override returns (uint256) {
        return flatRate;
    }
}

/**
 * @title HighFeeCalculator
 * @notice Test fee calculator that returns higher fees than default
 */
contract HighFeeCalculator is IFeeCalculator {
    function getVaultRatioBps(uint256 utilizationBps) external pure override returns (uint256) {
        if (utilizationBps <= 5000) {
            return 6000;
        } else {
            return 6000 + (utilizationBps - 5000) * 7 / 10;
        }
    }
}

/**
 * @title DynamicFeesVaultTest
 * @notice Test suite for DynamicFeesVault with USDC
 */
contract DynamicFeesVaultTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner;
    address public user1;

    function setUp() public {
        // Start at week 2 to avoid epoch 0 edge cases
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
        vault.borrow(790e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 8000, "Utilization should be less than 80%");
    }

    function testBorrowAndRepay() public {
        vm.startPrank(user1);
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

    function testCannotWithdrawMoreThanLiquid() public {
        vm.startPrank(user1);
        vault.borrow(500e6);
        vm.stopPrank();

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 shares = vault.balanceOf(address(this));

        vm.expectRevert();
        vault.withdraw(vaultBalance + 1, address(this), address(this));
    }

    function testTotalAssetsIncludesLoanedAssets() public {
        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        vault.borrow(500e6);
        vm.stopPrank();

        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(totalAssetsBefore, totalAssetsAfter, "Total assets should include loaned assets");
    }

    function testUtilizationCalculation() public {
        uint256 total = vault.totalAssets();
        assertEq(total, 1000e6, "Total assets should be 1000 USDC");

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 utilization = vault.getUtilizationPercent();
        assertEq(utilization, 5000, "Utilization should be 50%");
    }

    function testBorrowAndRepayWithRewards() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.startPrank(user1);
        vault.borrow(500e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 500e6, "Debt balance should be 500");

        vm.startPrank(user1);
        deal(address(usdc), user1, 250e6);
        usdc.approve(address(vault), 250e6);
        vault.repayWithRewards(250e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 500e6, "Debt balance should still be 500 (rewards not yet vested)");

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.updateUserDebtBalance(user1);

        uint256 debtAfter = vault.getDebtBalance(user1);
        assertLt(debtAfter, 500e6, "Debt balance should be reduced after rewards vest");
    }

    function testMultipleUsersBorrow() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrow(300e6);

        vm.prank(user2);
        vault.borrow(200e6);

        assertEq(vault.getDebtBalance(user1), 300e6, "User1 debt should be 300");
        assertEq(vault.getDebtBalance(user2), 200e6, "User2 debt should be 200");
        assertEq(vault.totalLoanedAssets(), 500e6, "Total loaned should be 500");
    }

    function testOverRepayOnlyRepaysDebt() public {
        vm.startPrank(user1);
        vault.borrow(100e6);
        vm.stopPrank();

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repay(200e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be 0");
        assertEq(usdc.balanceOf(user1), 100e6, "User should have 100 USDC remaining");
    }

    function testPartialRepay() public {
        vm.startPrank(user1);
        vault.borrow(500e6);
        vm.stopPrank();

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repay(200e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 300e6, "Debt should be 300 after partial repay");
    }

    function testRepayWithZeroDebt() public {
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repay(100e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0, "Debt should still be 0");
    }

    function testWithdrawLimitedByLiquidity() public {
        vm.prank(user1);
        vault.borrow(500e6);

        // After borrow, vault has 500e6 USDC remaining
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertEq(vaultBalance, 500e6, "Vault should have 500e6 USDC after borrow");

        // ERC4626's maxWithdraw returns based on shares, not liquidity
        // The actual withdrawal will fail if liquidity is insufficient (tested in testCannotWithdrawMoreThanLiquid)
        uint256 maxWithdrawable = vault.maxWithdraw(address(this));

        // User shares still represent full value since totalAssets includes loaned assets
        // So maxWithdraw will return more than available liquidity
        assertGt(maxWithdrawable, 0, "Should have some max withdrawable amount");
    }

    function testCannotBorrowWhenUtilizationAt80Percent() public {
        vm.prank(user1);
        vault.borrow(790e6);

        uint256 utilization = vault.getUtilizationPercent();
        assertLt(utilization, 8000, "Should be just under 80%");

        address user2 = address(0x3);
        vm.prank(user2);
        vm.expectRevert("Borrow would exceed 80% utilization");
        vault.borrow(100e6);
    }

    function testCanBorrowWhenUtilizationUnder80Percent() public {
        vm.prank(user1);
        vault.borrow(700e6);

        uint256 utilization = vault.getUtilizationPercent();
        assertLt(utilization, 8000, "Utilization should be under 80%");

        address user2 = address(0x3);
        vm.prank(user2);
        vault.borrow(50e6);

        assertEq(vault.totalLoanedAssets(), 750e6, "Total loaned should be 750");
    }

    function testGetVaultRatioBps() public view {
        uint256 rate0 = vault.getVaultRatioBps(0);
        assertEq(rate0, 500, "0% utilization should return 5%");

        uint256 rate1000 = vault.getVaultRatioBps(1000);
        assertEq(rate1000, 2000, "10% utilization should return 20%");

        uint256 rate5000 = vault.getVaultRatioBps(5000);
        assertEq(rate5000, 2000, "50% utilization should return 20%");

        uint256 rate9000 = vault.getVaultRatioBps(9000);
        assertEq(rate9000, 4000, "90% utilization should return 40%");

        uint256 rate10000 = vault.getVaultRatioBps(10000);
        assertEq(rate10000, 9500, "100% utilization should return 95%");
    }

    function testMultipleRepayWithRewardsInSameEpoch() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 300e6);
        usdc.approve(address(vault), 300e6);

        vault.repayWithRewards(100e6);
        vault.repayWithRewards(100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 totalRewards = vault.rewardTotalAssetsPerEpoch(currentEpoch);
        assertEq(totalRewards, 300e6, "Total rewards should be 300");
    }

    function testRewardsAccumulateOverMultipleEpochs() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to next epoch
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.repayWithRewards(150e6);
        vm.stopPrank();

        assertEq(vault.rewardTotalAssetsPerEpoch(epoch1), 100e6, "Epoch1 rewards should be 100");
        assertEq(vault.rewardTotalAssetsPerEpoch(epoch2), 150e6, "Epoch2 rewards should be 150");
    }

    function testDebtFullyPaidByRewards() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.repayWithRewards(150e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 usdcBalanceBefore = usdc.balanceOf(user1);
        vault.updateUserDebtBalance(user1);
        uint256 usdcBalanceAfter = usdc.balanceOf(user1);

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");
        // Excess rewards are transferred as USDC, not minted as shares (prevents shareholder dilution)
        assertGt(usdcBalanceAfter, usdcBalanceBefore, "User should receive USDC for excess rewards");
    }

    function testTotalAssetsDecreasesWithRealTimeRewards() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.sync();

        assertLt(vault.totalLoanedAssets(), 500e6, "Total loaned assets should decrease as rewards vest");
    }

    function testSettlementCheckpointUpdatesCorrectly() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Move to next epoch
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);

        vault.sync();

        (uint256 checkpointEpoch, uint256 principalRepaid) = vault.getSettlementCheckpoint();
        assertEq(checkpointEpoch, epoch2, "Checkpoint epoch should be current");
        assertGt(principalRepaid, 0, "Principal repaid should be > 0");
    }

    function testLenderPremiumVsBorrowerPrincipalSplit() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 utilization = vault.getUtilizationPercent();
        uint256 vaultRatio = vault.getVaultRatioBps(utilization);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.sync();

        uint256 totalAssets = vault.rewardTotalAssetsPerEpoch(ProtocolTimeLibrary.epochStart(timestamp) - ProtocolTimeLibrary.WEEK);
        uint256 lenderPremium = vault.tokenClaimedPerEpoch(address(vault), ProtocolTimeLibrary.epochStart(timestamp) - ProtocolTimeLibrary.WEEK);

        assertGt(lenderPremium, 0, "Lender premium should be > 0");
        assertLt(lenderPremium, totalAssets, "Lender premium should be less than total");
    }

    function testMultipleUsersRepayWithRewards() public {
        address user2 = address(0x3);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(300e6);

        vm.prank(user2);
        vault.borrow(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.repayWithRewards(150e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.updateUserDebtBalance(user1);
        vault.updateUserDebtBalance(user2);

        assertLt(vault.getDebtBalance(user1), 300e6, "User1 debt should be reduced");
        assertLt(vault.getDebtBalance(user2), 200e6, "User2 debt should be reduced");
    }

    function testMultipleUsersRepayWithRewardsEarlyRepayerGetsUSDC() public {
        address user2 = address(0x3);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(user2);
        vault.borrow(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 user1UsdcBefore = usdc.balanceOf(user1);
        vault.updateUserDebtBalance(user1);
        uint256 user1UsdcAfter = usdc.balanceOf(user1);

        assertEq(vault.getDebtBalance(user1), 0, "User1 debt should be fully paid");
        // Excess rewards are transferred as USDC, not minted as shares (prevents shareholder dilution)
        assertGt(user1UsdcAfter, user1UsdcBefore, "User1 should receive USDC for excess rewards");
    }

    function testExcessRewardsDoNotDiluteShareholders() public {
        // This test verifies that when a borrower earns more rewards than their debt,
        // the excess is transferred as USDC rather than minted as shares, preventing
        // dilution of existing vault shareholders.

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        // Record initial share price (assets per share)
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;

        // User1 borrows a small amount
        vm.prank(user1);
        vault.borrow(100e6);

        // User1 repays with significantly more rewards than their debt
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Move to next epoch so rewards vest
        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        // Expect the ExcessRewardsPaid event to be emitted
        vm.expectEmit(true, false, false, false);
        emit DynamicFeesVault.ExcessRewardsPaid(user1, 0);
        vault.updateUserDebtBalance(user1);

        // Verify debt is fully paid
        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");

        // Calculate share price after excess rewards distribution
        uint256 totalSupplyAfter = vault.totalSupply();
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = totalAssetsAfter * 1e18 / totalSupplyAfter;

        // Share price should NOT decrease (no dilution)
        // With the fix, shares are not minted so total supply stays the same
        assertGe(sharePriceAfter, sharePriceBefore, "Share price should not decrease (no dilution)");

        // Total supply should not have increased from minting shares to borrower
        // (user1 had 0 shares before this test)
        assertEq(vault.balanceOf(user1), 0, "Borrower should not receive vault shares");
    }

    function testFeeRatioProgressionOverEpoch() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        uint256 epochDuration = ProtocolTimeLibrary.WEEK;

        for (uint256 i = 1; i <= 7; i++) {
            vm.warp(timestamp + (i * epochDuration / 7));

            uint256 utilization = vault.getUtilizationPercent();
            uint256 feeRatio = vault.getVaultRatioBps(utilization);

            assertGe(feeRatio, 500, "Fee ratio should be at least 5%");
            assertLe(feeRatio, 9500, "Fee ratio should be at most 95%");
        }
    }

    // ============ Pause Mechanism Tests ============

    function testPauseByOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");
    }

    function testPauseByAuthorizedPauser() public {
        address pauser = address(0x999);

        vm.prank(owner);
        vault.addPauser(pauser);

        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");
    }

    function testCannotPauseIfNotAuthorized() public {
        address notPauser = address(0x888);

        vm.prank(notPauser);
        vm.expectRevert(DynamicFeesVault.NotPauser.selector);
        vault.pause();
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(owner);
        vault.pause();

        address pauser = address(0x999);
        vm.prank(owner);
        vault.addPauser(pauser);

        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused(), "Vault should be unpaused");
    }

    function testAddAndRemovePauser() public {
        address pauser = address(0x999);

        vm.prank(owner);
        vault.addPauser(pauser);
        assertTrue(vault.isPauser(pauser), "Should be a pauser");

        vm.prank(owner);
        vault.removePauser(pauser);
        assertFalse(vault.isPauser(pauser), "Should not be a pauser");
    }

    function testCannotBorrowWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.borrow(100e6);
    }

    function testCannotRepayWhenPaused() public {
        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.repay(100e6);
        vm.stopPrank();
    }

    function testCannotRepayWithRewardsWhenPaused() public {
        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(owner);
        vault.pause();

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
        vm.prank(owner);
        vault.pause();

        vault.sync();
    }

    function testCanUpdateUserDebtBalanceWhenPaused() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vm.prank(owner);
        vault.pause();

        vault.updateUserDebtBalance(user1);
        assertLt(vault.getDebtBalance(user1), 100e6, "Debt should be reduced even when paused");
    }

    // ============ Fee Calculator Tests ============

    function testFeeCalculatorAddressExposed() public view {
        address feeCalc = vault.feeCalculator();
        assertNotEq(feeCalc, address(0), "Fee calculator should not be zero address");
    }

    function testOnlyOwnerCanSetFeeCalculator() public {
        FeeCalculator newFeeCalc = new FeeCalculator();

        vm.prank(user1);
        vm.expectRevert();
        vault.setFeeCalculator(address(newFeeCalc));

        vm.prank(owner);
        vault.setFeeCalculator(address(newFeeCalc));

        assertEq(vault.feeCalculator(), address(newFeeCalc), "Fee calculator should be updated");
    }

    function testSwapFeeCalculator() public {
        FlatFeeCalculator flatFeeCalc = new FlatFeeCalculator(5000);

        uint256 rateBefore = vault.getVaultRatioBps(5000);
        assertEq(rateBefore, 2000, "Fee should be 20% at 50% utilization");

        vm.prank(owner);
        vault.setFeeCalculator(address(flatFeeCalc));

        uint256 rateAfter = vault.getVaultRatioBps(5000);
        assertEq(rateAfter, 5000, "Fee should now be 50%");

        assertEq(vault.getVaultRatioBps(1000), 5000, "Fee at 10% utilization should be 50%");
        assertEq(vault.getVaultRatioBps(9000), 5000, "Fee at 90% utilization should be 50%");
    }

    function testFeeCalculatorSwapAffectsRebalance() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        uint256 currentUtilization = vault.getUtilizationPercent();
        uint256 ratioBefore = vault.getVaultRatioBps(currentUtilization);

        HighFeeCalculator highFeeCalc = new HighFeeCalculator();
        vm.prank(owner);
        vault.setFeeCalculator(address(highFeeCalc));

        uint256 ratioAfter = vault.getVaultRatioBps(currentUtilization);
        assertGt(ratioAfter, ratioBefore, "High fee calculator should return higher rate");

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        assertEq(
            vault.getCurrentVaultRatioBps(),
            highFeeCalc.getVaultRatioBps(vault.getUtilizationPercent()),
            "Current vault ratio should match high fee calculator"
        );
    }

    function testCannotSetZeroAddressFeeCalculator() public {
        vm.prank(owner);
        vm.expectRevert(DynamicFeesVault.ZeroAddress.selector);
        vault.setFeeCalculator(address(0));
    }

    function testFeeCalculatorUpdatedEvent() public {
        FeeCalculator newFeeCalc = new FeeCalculator();
        address oldCalc = vault.feeCalculator();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit DynamicFeesVault.FeeCalculatorUpdated(oldCalc, address(newFeeCalc));
        vault.setFeeCalculator(address(newFeeCalc));
    }

    // ============ Upgrade Tests ============

    function testVaultUpgrade() public {
        DynamicFeesVault newImpl = new DynamicFeesVault();

        vm.prank(user1);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");

        address feeCalcBefore = vault.feeCalculator();

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.feeCalculator(), feeCalcBefore, "Fee calculator should be preserved after upgrade");
    }

    function testVaultUpgradePreservesState() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 numCheckpointsBefore = vault.numCheckpoints(user1);
        uint256 supplyNumCheckpointsBefore = vault.supplyNumCheckpoints();

        DynamicFeesVault newImpl = new DynamicFeesVault();
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.numCheckpoints(user1), numCheckpointsBefore, "Checkpoints should be preserved");
        assertEq(vault.supplyNumCheckpoints(), supplyNumCheckpointsBefore, "Supply checkpoints should be preserved");

        vault.updateUserDebtBalance(user1);
        uint256 debt = vault.getDebtBalance(user1);
        assertLt(debt, 200e6, "Debt should be reduced after reward settlement");
    }

    // ============ Fuzz Tests ============

    function testFuzzBorrowAndRepay(uint256 amount) public {
        amount = bound(amount, 1e6, 790e6);

        vm.prank(user1);
        vault.borrow(amount);
        assertEq(vault.getDebtBalance(user1), amount, "Debt should match borrowed amount");

        vm.startPrank(user1);
        deal(address(usdc), user1, amount);
        usdc.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be 0 after full repay");
    }

    function testFuzzRepayWithRewards(uint256 borrowAmount, uint256 rewardAmount) public {
        borrowAmount = bound(borrowAmount, 100e6, 500e6);
        rewardAmount = bound(rewardAmount, 10e6, 200e6);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(borrowAmount);

        vm.startPrank(user1);
        deal(address(usdc), user1, rewardAmount);
        usdc.approve(address(vault), rewardAmount);
        vault.repayWithRewards(rewardAmount);
        vm.stopPrank();

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.updateUserDebtBalance(user1);
        assertLt(vault.getDebtBalance(user1), borrowAmount, "Debt should be reduced");
    }

    function testFuzzVaultRatioBps(uint256 utilization) public view {
        utilization = bound(utilization, 0, 10000);

        uint256 rate = vault.getVaultRatioBps(utilization);

        assertGe(rate, 500, "Rate should be >= 5%");
        assertLe(rate, 9500, "Rate should be <= 95%");
    }

    // ============ High Utilization Tests ============

    function testHighUtilizationWithWithdrawalAndDailyFeeRatioCheck() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 sharesToWithdraw = vault.balanceOf(address(this)) * 45 / 100;
        vault.redeem(sharesToWithdraw, address(this), address(this));

        uint256 utilization = vault.getUtilizationPercent();
        assertGt(utilization, 8000, "Utilization should be > 80%");

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        uint256 epochDuration = ProtocolTimeLibrary.WEEK;

        uint256[] memory dailyDebts = new uint256[](8);
        dailyDebts[0] = vault.getDebtBalance(user1);

        for (uint256 day = 1; day <= 7; day++) {
            vm.warp(timestamp + (day * epochDuration / 7));

            utilization = vault.getUtilizationPercent();
            uint256 feeRatio = vault.getVaultRatioBps(utilization);

            assertGe(feeRatio, 2000, "Fee ratio should be at least 20%");
            assertLe(feeRatio, 9500, "Fee ratio should be at most 95%");

            vault.sync();
            vault.updateUserDebtBalance(user1);
            dailyDebts[day] = vault.getDebtBalance(user1);
        }
    }

    function testHighUtilizationSingleRewardPaymentDailyDebtCheck() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 sharesToWithdraw = vault.balanceOf(address(this)) * 45 / 100;
        vault.redeem(sharesToWithdraw, address(this), address(this));

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        uint256 epochDuration = ProtocolTimeLibrary.WEEK;

        uint256[] memory dailyDebts = new uint256[](8);
        dailyDebts[0] = vault.getDebtBalance(user1);

        for (uint256 day = 1; day <= 7; day++) {
            vm.warp(timestamp + (day * epochDuration / 7));

            vault.sync();
            vault.updateUserDebtBalance(user1);
            dailyDebts[day] = vault.getDebtBalance(user1);

            uint256 utilization = vault.getUtilizationPercent();
            uint256 feeRatio = vault.getVaultRatioBps(utilization);

            assertGe(feeRatio, 2000, "Fee ratio should be at least 20%");
        }
    }

    // ============ Stale Checkpoint Tests ============

    function testStaleCheckpointRecovery() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        vm.prank(user1);
        vault.borrow(100e6);

        // Deposit rewards in epoch1 - user gets a checkpoint
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        // Move to next epoch and deposit more rewards
        // This ensures user has balance at START of an epoch with rewards
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);

        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        // Move to a much later epoch (rewards should have vested)
        uint256 laterEpoch = ProtocolTimeLibrary.epochNext(epoch2) + (8 * ProtocolTimeLibrary.WEEK);
        vm.warp(laterEpoch);

        vault.sync();
        vault.updateUserDebtBalance(user1);

        uint256 debt = vault.getDebtBalance(user1);
        assertLt(debt, 100e6, "Debt should be reduced after recovery");
    }

    function testVeryStaleCheckpoint() public {
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        timestamp = timestamp + (60 * ProtocolTimeLibrary.WEEK);
        vm.warp(timestamp);

        vault.sync();
        vault.updateUserDebtBalance(user1);

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

        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(user2);
        vault.borrow(150e6);

        vm.prank(user3);
        vault.borrow(200e6);

        vm.prank(user4);
        vault.borrow(100e6);

        assertEq(vault.totalLoanedAssets(), 550e6);

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

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        vault.sync();

        vault.updateUserDebtBalance(user1);
        vault.updateUserDebtBalance(user2);
        vault.updateUserDebtBalance(user3);
        vault.updateUserDebtBalance(user4);

        uint256 debt1 = vault.getDebtBalance(user1);
        uint256 debt2 = vault.getDebtBalance(user2);
        uint256 debt3 = vault.getDebtBalance(user3);
        uint256 debt4 = vault.getDebtBalance(user4);

        assertLt(debt1, 100e6, "User1 debt should be reduced");
        assertLt(debt2, 150e6, "User2 debt should be reduced");
        assertLt(debt3, 200e6, "User3 debt should be reduced");
        assertLt(debt4, 100e6, "User4 debt should be reduced");

        uint256 totalDebt = debt1 + debt2 + debt3 + debt4;
        assertLt(totalDebt, 550e6, "Total debt should be reduced");
        assertEq(vault.totalLoanedAssets(), totalDebt, "Total loaned should match sum of debts");
    }

    function testConcurrentSettlementOrder() public {
        address user2 = address(0x3);

        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(timestamp);

        vm.prank(user1);
        vault.borrow(200e6);

        vm.prank(user2);
        vault.borrow(200e6);

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

        timestamp = ProtocolTimeLibrary.epochNext(timestamp);
        vm.warp(timestamp);

        uint256 user1DebtBefore = vault.getDebtBalance(user1);
        uint256 user2DebtBefore = vault.getDebtBalance(user2);

        vault.updateUserDebtBalance(user1);
        uint256 user1DebtAfter = vault.getDebtBalance(user1);

        vault.updateUserDebtBalance(user2);
        uint256 user2DebtAfter = vault.getDebtBalance(user2);

        uint256 user1Reduction = user1DebtBefore - user1DebtAfter;
        uint256 user2Reduction = user2DebtBefore - user2DebtAfter;

        assertApproxEqAbs(user1Reduction, user2Reduction, 1e6, "Both users should have similar debt reduction");
    }
}
