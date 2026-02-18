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
 */
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

/**
 * @title FlatFeeCalculator
 */
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flatRate;
    constructor(uint256 _flatRate) { flatRate = _flatRate; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flatRate; }
}

/**
 * @title HighFeeCalculator
 */
contract HighFeeCalculator is IFeeCalculator {
    function getVaultRatioBps(uint256 utilizationBps) external pure override returns (uint256) {
        if (utilizationBps <= 5000) return 6000;
        return 6000 + (utilizationBps - 5000) * 7 / 10;
    }
}

/**
 * @title DynamicFeesVaultTest
 * @notice Test suite for DynamicFeesVault with per-user reward streaming
 */
contract DynamicFeesVaultTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;
    address public owner;
    address public user1;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    // setUp warps to 2*WEEK, so epoch boundaries are at 2*WEEK, 3*WEEK, etc.
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    function setUp() public {
        vm.warp(EPOCH_2);

        owner = address(0x1);
        user1 = address(0x2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, address(this));
    }

    /// @dev Helper: warp to end of current epoch and settle rewards for a user
    function _warpAndSettle(address user) internal {
        vm.warp(EPOCH_3);
        vault.settleRewards(user);
    }

    /// @dev Helper: warp to a specific time and settle rewards for a user
    function _warpToAndSettle(uint256 timestamp, address user) internal {
        vm.warp(timestamp);
        vault.settleRewards(user);
    }

    // ============ Basic Borrow/Repay Tests ============

    function testBorrow() public {
        vm.prank(user1);
        vault.borrow(790e6);
        assertLt(vault.getUtilizationPercent(), 8000);
    }

    function testBorrowAndRepay() public {
        vm.prank(user1);
        vault.borrow(790e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 790e6);
        usdc.approve(address(vault), 790e6);
        vault.repay(790e6);
        vm.stopPrank();

        assertEq(vault.getUtilizationPercent(), 0);
    }

    function testDepositAndWithdraw() public {
        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.deposit(800e6, address(this));
        vm.stopPrank();
    }

    function testCannotWithdrawMoreThanLiquid() public {
        vm.prank(user1);
        vault.borrow(500e6);

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        vm.expectRevert();
        vault.withdraw(vaultBalance + 1, address(this), address(this));
    }

    function testTotalAssetsIncludesLoanedAssets() public {
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.prank(user1);
        vault.borrow(500e6);
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets should include loaned assets");
    }

    function testUtilizationCalculation() public {
        assertEq(vault.totalAssets(), 1000e6);
        vm.prank(user1);
        vault.borrow(500e6);
        assertEq(vault.getUtilizationPercent(), 5000, "Utilization should be 50%");
    }

    function testMultipleUsersBorrow() public {
        address user2 = address(0x3);
        vm.prank(user1);
        vault.borrow(300e6);
        vm.prank(user2);
        vault.borrow(200e6);

        assertEq(vault.getDebtBalance(user1), 300e6);
        assertEq(vault.getDebtBalance(user2), 200e6);
        assertEq(vault.totalLoanedAssets(), 500e6);
        assertEq(vault.getTotalDebtBalance(), 500e6);
    }

    function testOverRepayOnlyRepaysDebt() public {
        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repay(200e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0);
        assertEq(usdc.balanceOf(user1), 100e6);
    }

    function testPartialRepay() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repay(200e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 300e6);
    }

    function testRepayWithZeroDebt() public {
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repay(100e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0);
    }

    function testWithdrawLimitedByLiquidity() public {
        vm.roll(block.number + 1);
        vm.prank(user1);
        vault.borrow(500e6);

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertEq(vaultBalance, 500e6);

        uint256 maxWithdrawable = vault.maxWithdraw(address(this));
        assertGt(maxWithdrawable, 0);
        assertLe(maxWithdrawable, vaultBalance);
    }

    function testCannotBorrowWhenUtilizationAt80Percent() public {
        vm.prank(user1);
        vault.borrow(790e6);

        address user2 = address(0x3);
        vm.prank(user2);
        vm.expectRevert("Borrow would exceed 80% utilization");
        vault.borrow(100e6);
    }

    function testCanBorrowWhenUtilizationUnder80Percent() public {
        vm.prank(user1);
        vault.borrow(700e6);

        address user2 = address(0x3);
        vm.prank(user2);
        vault.borrow(50e6);

        assertEq(vault.totalLoanedAssets(), 750e6);
    }

    function testGetVaultRatioBps() public view {
        assertEq(vault.getVaultRatioBps(0), 500);
        assertEq(vault.getVaultRatioBps(1000), 2000);
        assertEq(vault.getVaultRatioBps(5000), 2000);
        assertEq(vault.getVaultRatioBps(9000), 4000);
        assertEq(vault.getVaultRatioBps(10000), 9500);
    }

    // ============ Reward Streaming Tests ============

    function testRepayWithRewardsDoesNotReduceDebtImmediately() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Debt should NOT be reduced immediately — rewards are streaming
        assertEq(vault.getDebtBalance(user1), 500e6, "Debt should not change immediately");
        assertGt(vault.getActiveEpochRate(), 0, "Stream should be active");
        assertEq(vault.getTotalUnsettledRewards(), 100e6, "Unsettled should be 100");
    }

    function testRepayWithRewardsReducesDebtAfterVesting() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to end of epoch and settle
        _warpAndSettle(user1);

        // Borrower share reduces sender's debt
        uint256 debtAfter = vault.getDebtBalance(user1);
        assertLt(debtAfter, 500e6, "Debt should be reduced after vesting + settle");
    }

    function testRewardsOnlyReduceDepositorDebt() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrow(300e6);
        vm.prank(user2);
        vault.borrow(200e6);

        // user1 deposits rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp and settle both users
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);

        // user1's debt should be reduced
        assertLt(vault.getDebtBalance(user1), 300e6, "Depositor debt should be reduced");
        // user2's debt should be UNCHANGED
        assertEq(vault.getDebtBalance(user2), 200e6, "Non-depositor debt should be unchanged");
    }

    function testTotalClaimedNeverExceedsTotalDeposited() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        vm.prank(user1);
        vault.borrow(100e6);
        vm.prank(user2);
        vault.borrow(200e6);
        vm.prank(user3);
        vault.borrow(300e6);

        // Multiple reward deposits from different users
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.repayWithRewards(50e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 80e6);
        usdc.approve(address(vault), 80e6);
        vault.repayWithRewards(80e6);
        vm.stopPrank();

        // Warp and settle all users
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);
        vault.settleRewards(user3);

        uint256 totalReduction = (100e6 - vault.getDebtBalance(user1))
            + (200e6 - vault.getDebtBalance(user2))
            + (300e6 - vault.getDebtBalance(user3));

        uint256 vestedApplied = vault.totalVestedRewardsApplied();
        assertEq(vestedApplied, totalReduction, "Vested should match reductions");

        // user3 never deposited, their debt should be unchanged
        assertEq(vault.getDebtBalance(user3), 300e6, "Non-depositor debt unchanged");
    }

    function testDebtFullyPaidByRewards() public {
        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.repayWithRewards(150e6);
        vm.stopPrank();

        // Warp and settle — excess should be sent as USDC
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");
        assertGt(usdc.balanceOf(user1), 0, "User should receive USDC for excess rewards");
    }

    function testExcessRewardsDoNotDiluteShareholders() public {
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;

        vm.prank(user1);
        vault.borrow(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Share price shouldn't decrease immediately
        uint256 sharePriceNow = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertGe(sharePriceNow, sharePriceBefore, "Share price should not decrease immediately");

        // Warp and settle to clear debt + excess
        _warpAndSettle(user1);
        assertEq(vault.getDebtBalance(user1), 0);

        // Premium extracted at EPOCH_3 → vests in same epoch → fully vested at EPOCH_4
        vm.warp(EPOCH_4);

        uint256 totalSupplyAfter = vault.totalSupply();
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = totalAssetsAfter * 1e18 / totalSupplyAfter;

        assertGe(sharePriceAfter, sharePriceBefore, "Share price should not decrease after vesting");
        assertEq(vault.balanceOf(user1), 0, "Borrower should not receive vault shares");
    }

    function testMultipleRepayWithRewardsAccumulate() public {
        vm.prank(user1);
        vault.borrow(500e6);

        // Deposit 3 times in same block — streams combine
        vm.startPrank(user1);
        deal(address(usdc), user1, 300e6);
        usdc.approve(address(vault), 300e6);
        vault.repayWithRewards(100e6);
        vault.repayWithRewards(100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // All 300 should be streaming
        assertEq(vault.getTotalUnsettledRewards(), 300e6, "All 300 should be unsettled");

        // Warp and settle — all rewards vest
        _warpAndSettle(user1);

        uint256 debtAfter = vault.getDebtBalance(user1);
        assertLt(debtAfter, 500e6, "Debt should be reduced after settling all rewards");

        // Borrower share of 300 should reduce debt significantly
        uint256 ratio = vault.getCurrentVaultRatioBps();
        uint256 expectedBorrowerShare = 300e6 - (300e6 * ratio / 10000);
        assertApproxEqAbs(500e6 - debtAfter, expectedBorrowerShare, 2e6, "Debt reduction should match borrower share");
    }

    function testMultipleUsersRepayWithRewards() public {
        address user2 = address(0x3);

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

        // Warp and settle both
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);

        assertLt(vault.getDebtBalance(user1), 300e6, "User1 debt should be reduced");
        assertLt(vault.getDebtBalance(user2), 200e6, "User2 debt should be reduced");
    }

    function testMultipleConcurrentBorrowersSettling() public {
        address user2 = address(0x3);
        address user3 = address(0x4);
        address user4 = address(0x5);

        vm.prank(user1);
        vault.borrow(100e6);
        vm.prank(user2);
        vault.borrow(150e6);
        vm.prank(user3);
        vault.borrow(200e6);
        vm.prank(user4);
        vault.borrow(100e6);

        assertEq(vault.totalLoanedAssets(), 550e6);
        assertEq(vault.getTotalDebtBalance(), 550e6);

        // Each user deposits their own rewards
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

        // Warp and settle all users
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);
        vault.settleRewards(user3);
        vault.settleRewards(user4);

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

        assertEq(vault.getTotalDebtBalance(), totalDebt, "totalDebtBalance should match sum of debts");
    }

    // ============ Partial Vesting Tests ============

    function testPartialVestingAt50Percent() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to 50% of epoch duration
        uint256 halfwayPoint = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        vm.warp(halfwayPoint);
        vault.settleRewards(user1);

        // ~50% of borrower share should be applied
        uint256 expectedBorrowerTotal = 80e6; // 80% of 100
        uint256 debtReduction = 500e6 - vault.getDebtBalance(user1);
        assertApproxEqAbs(debtReduction, expectedBorrowerTotal / 2, 1e6, "~50% of borrower share should be applied at halfway");
    }

    function testMidStreamDeposit() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        // First deposit at epoch start
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to 50% and make second deposit
        uint256 halfwayPoint = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        vm.warp(halfwayPoint);

        vm.startPrank(user1);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to end and settle
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        // Both deposits should contribute to debt reduction
        uint256 debtAfter = vault.getDebtBalance(user1);
        assertLt(debtAfter, 500e6, "Debt should be reduced");
        // Total borrower share: 80% of 200 = 160
        // But some rounding from rate computation
        uint256 debtReduction = 500e6 - debtAfter;
        assertApproxEqAbs(debtReduction, 160e6, 3e6, "Both deposits should contribute to ~160 debt reduction");
    }

    // ============ totalAssets Tests ============

    function testTotalAssetsUnchangedByRewardDeposit() public {
        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(user1);
        vault.borrow(500e6);
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged after borrow");

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // totalAssets should NOT increase (rewards are unsettled)
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged after reward deposit");
    }

    function testTotalAssetsIncreasesAfterLenderPremiumVests() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to end of stream epoch — triggers global vesting via sync
        // Premium deposited directly into vestingEpochPremium at EPOCH_3 (vests in same epoch)
        vm.warp(EPOCH_3);
        vault.sync();

        // At EPOCH_3 start, 0% elapsed in vesting epoch → premium is fully unvested
        // totalAssets should still equal totalAssetsBefore
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged at start of vesting epoch");

        // At EPOCH_3 + WEEK/2 = halfway through vesting
        vm.warp(EPOCH_3 + WEEK / 2);

        uint256 totalAssetsMid = vault.totalAssets();
        assertGt(totalAssetsMid, totalAssetsBefore, "totalAssets should increase as premium vests");

        // Warp to fully vested (end of EPOCH_3)
        vm.warp(EPOCH_4);

        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 increase = totalAssetsAfter - totalAssetsBefore;
        assertApproxEqAbs(increase, 20e6, 1e6, "Increase should be ~20 USDC (20% of 100)");
    }

    // ============ Fee Split Tests ============

    function testFeeSplitAtDifferentRates() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // totalAssets unchanged in deposit epoch
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged in deposit epoch");

        // Warp to end of stream and settle
        _warpAndSettle(user1);

        // Borrower debt reduction = 80% of 100 = 80
        uint256 debtReduction = 500e6 - vault.getDebtBalance(user1);
        assertApproxEqAbs(debtReduction, 80e6, 2e6, "Debt reduction should be ~80 USDC at 20% fee");

        // Premium extracted at EPOCH_3 → vests in same epoch → fully vested at EPOCH_4
        vm.warp(EPOCH_4);

        uint256 lenderPremium = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(lenderPremium, 20e6, 2e6, "Lender premium should be ~20 USDC at 20% fee after vesting");
    }

    function testFeeSplitAt50Percent() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(5000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp and settle
        _warpAndSettle(user1);

        uint256 debtReduction = 500e6 - vault.getDebtBalance(user1);
        assertApproxEqAbs(debtReduction, 50e6, 2e6, "Debt reduction should be ~50 USDC at 50% fee");

        // Premium extracted at EPOCH_3 → vests in same epoch → fully vested at EPOCH_4
        vm.warp(EPOCH_4);

        uint256 lenderPremium = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(lenderPremium, 50e6, 2e6, "Lender premium should be ~50 USDC at 50% fee after vesting");
    }

    function testFeeCalculatorSwapAffectsRewardSplit() public {
        FlatFeeCalculator lowFee = new FlatFeeCalculator(2000); // 20% lender
        vm.prank(owner);
        vault.setFeeCalculator(address(lowFee));

        vm.prank(user1);
        vault.borrow(500e6);

        // Deposit rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to 50% and settle — first half at 20% fee
        uint256 halfwayPoint = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        _warpToAndSettle(halfwayPoint, user1);

        uint256 debtAfterFirstHalf = vault.getDebtBalance(user1);
        uint256 firstHalfReduction = 500e6 - debtAfterFirstHalf;

        // Swap to high fee calculator (60%)
        FlatFeeCalculator highFee = new FlatFeeCalculator(6000);
        vm.prank(owner);
        vault.setFeeCalculator(address(highFee));

        // Warp to end and settle — second half at 60% fee
        _warpAndSettle(user1);

        uint256 secondHalfReduction = debtAfterFirstHalf - vault.getDebtBalance(user1);

        // First half: ~80% borrower = ~40 USDC debt reduction
        // Second half: ~40% borrower = ~20 USDC debt reduction
        assertGt(firstHalfReduction, secondHalfReduction, "Higher fee should give less to borrower");
    }

    // ============ Fee Calculator Tests ============

    function testFeeCalculatorAddressExposed() public view {
        assertNotEq(vault.feeCalculator(), address(0));
    }

    function testOnlyOwnerCanSetFeeCalculator() public {
        FeeCalculator newFeeCalc = new FeeCalculator();
        vm.prank(user1);
        vm.expectRevert();
        vault.setFeeCalculator(address(newFeeCalc));

        vm.prank(owner);
        vault.setFeeCalculator(address(newFeeCalc));
        assertEq(vault.feeCalculator(), address(newFeeCalc));
    }

    function testSwapFeeCalculator() public {
        FlatFeeCalculator flatFeeCalc = new FlatFeeCalculator(5000);

        assertEq(vault.getVaultRatioBps(5000), 2000);

        vm.prank(owner);
        vault.setFeeCalculator(address(flatFeeCalc));

        assertEq(vault.getVaultRatioBps(5000), 5000);
        assertEq(vault.getVaultRatioBps(1000), 5000);
        assertEq(vault.getVaultRatioBps(9000), 5000);
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

    // ============ Pause Mechanism Tests ============

    function testPauseByOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function testPauseByAuthorizedPauser() public {
        address pauser = address(0x999);
        vm.prank(owner);
        vault.addPauser(pauser);
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function testCannotPauseIfNotAuthorized() public {
        vm.prank(address(0x888));
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
        assertFalse(vault.paused());
    }

    function testAddAndRemovePauser() public {
        address pauser = address(0x999);
        vm.prank(owner);
        vault.addPauser(pauser);
        assertTrue(vault.isPauser(pauser));

        vm.prank(owner);
        vault.removePauser(pauser);
        assertFalse(vault.isPauser(pauser));
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
        vm.roll(block.number + 1);
        vm.prank(owner);
        vault.pause();
        vm.expectRevert();
        vault.withdraw(100e6, address(this), address(this));
    }

    function testCanSyncWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        vault.sync();
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
        assertEq(vault.feeCalculator(), feeCalcBefore);
    }

    function testVaultUpgradePreservesState() public {
        vm.prank(user1);
        vault.borrow(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Stream is active — debt not yet reduced
        uint256 debtBefore = vault.getDebtBalance(user1);
        uint256 totalDebtBefore = vault.getTotalDebtBalance();
        uint256 unsettledBefore = vault.getTotalUnsettledRewards();

        DynamicFeesVault newImpl = new DynamicFeesVault();
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.getDebtBalance(user1), debtBefore, "Debt preserved after upgrade");
        assertEq(vault.getTotalDebtBalance(), totalDebtBefore, "Total debt preserved");
        assertEq(vault.getTotalUnsettledRewards(), unsettledBefore, "Unsettled preserved");

        // Verify settle still works after upgrade
        _warpAndSettle(user1);
        assertLt(vault.getDebtBalance(user1), debtBefore, "Settlement should work after upgrade");
    }

    // ============ Fuzz Tests ============

    function testFuzzBorrowAndRepay(uint256 amount) public {
        amount = bound(amount, 1e6, 790e6);

        vm.prank(user1);
        vault.borrow(amount);
        assertEq(vault.getDebtBalance(user1), amount);

        vm.startPrank(user1);
        deal(address(usdc), user1, amount);
        usdc.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0);
    }

    function testFuzzRepayWithRewards(uint256 borrowAmount, uint256 rewardAmount) public {
        borrowAmount = bound(borrowAmount, 100e6, 500e6);
        rewardAmount = bound(rewardAmount, 10e6, 200e6);

        vm.prank(user1);
        vault.borrow(borrowAmount);

        vm.startPrank(user1);
        deal(address(usdc), user1, rewardAmount);
        usdc.approve(address(vault), rewardAmount);
        vault.repayWithRewards(rewardAmount);
        vm.stopPrank();

        // Debt not reduced yet — streaming
        assertEq(vault.getDebtBalance(user1), borrowAmount, "Debt unchanged before vesting");

        // Warp and settle
        _warpAndSettle(user1);

        assertLt(vault.getDebtBalance(user1), borrowAmount, "Debt should be reduced after vesting");
    }

    function testFuzzVaultRatioBps(uint256 utilization) public view {
        utilization = bound(utilization, 0, 10000);
        uint256 rate = vault.getVaultRatioBps(utilization);
        assertGe(rate, 500);
        assertLe(rate, 9500);
    }

    // ============ TotalDebtBalance Tracking Tests ============

    function testTotalDebtBalanceTracksCorrectly() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrow(300e6);
        assertEq(vault.getTotalDebtBalance(), 300e6);

        vm.prank(user2);
        vault.borrow(200e6);
        assertEq(vault.getTotalDebtBalance(), 500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repay(100e6);
        vm.stopPrank();

        assertEq(vault.getTotalDebtBalance(), 400e6);
    }

    function testTotalDebtBalanceAfterRewardDistribution() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Before vesting, debt unchanged
        assertEq(vault.getTotalDebtBalance(), 500e6, "Total debt unchanged before vesting");

        // After vesting + settle
        _warpAndSettle(user1);

        uint256 debt = vault.getDebtBalance(user1);
        assertEq(vault.getTotalDebtBalance(), debt, "totalDebtBalance should match user debt after settle");
    }

    function testTransferDebtDoesNotChangeTotal() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrow(300e6);

        uint256 totalBefore = vault.getTotalDebtBalance();

        vm.prank(user1);
        vault.transferDebt(user1, user2, 100e6);

        assertEq(vault.getTotalDebtBalance(), totalBefore, "Total debt unchanged after transfer");
        assertEq(vault.getDebtBalance(user1), 200e6);
        assertEq(vault.getDebtBalance(user2), 100e6);
    }

    // ============ Edge Cases ============

    function testRepayWithRewardsNoDebt() public {
        // User has no debt — should not revert, rewards stream and excess paid on settle
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        assertEq(vault.getDebtBalance(user1), 0, "Still no debt");

        // After vesting, excess should be returned
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "Still no debt after settle");
        // Borrower portion returned as excess USDC
        assertGt(usdc.balanceOf(user1), 0, "Should receive borrower portion as excess");
    }

    function testExcessRewardsPaidAsUSDC() public {
        vm.prank(user1);
        vault.borrow(50e6);

        uint256 user1UsdcBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Warp and settle — excess sent as USDC
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");
        assertGt(usdc.balanceOf(user1), user1UsdcBefore, "Should receive USDC for excess");
    }

    function testMultipleUsersRepayWithRewardsEarlyRepayerGetsUSDC() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrow(100e6);

        vm.prank(user2);
        vault.borrow(200e6);

        // User1 deposits 200 rewards against 100 debt
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Warp and settle user1 — should get excess
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "User1 debt should be fully paid");
        assertGt(usdc.balanceOf(user1), 0, "User1 should receive USDC for excess rewards");

        // User2 deposits 100 rewards against 200 debt
        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp and settle user2
        vm.warp(EPOCH_4);
        vault.settleRewards(user2);

        assertLt(vault.getDebtBalance(user2), 200e6, "User2 debt should be reduced");
        assertGt(vault.getDebtBalance(user2), 0, "User2 should still have remaining debt");
    }

    function testFeeRatioBoundsAfterBorrowAndRewards() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Fee ratio should stay within bounds
        uint256 utilization = vault.getUtilizationPercent();
        uint256 feeRatio = vault.getVaultRatioBps(utilization);
        assertGe(feeRatio, 500, "Fee ratio should be at least 5%");
        assertLe(feeRatio, 9500, "Fee ratio should be at most 95%");

        // Settle and check after partial repay
        _warpAndSettle(user1);

        vm.startPrank(user1);
        uint256 debt = vault.getDebtBalance(user1);
        deal(address(usdc), user1, debt / 2);
        usdc.approve(address(vault), debt / 2);
        vault.repay(debt / 2);
        vm.stopPrank();

        utilization = vault.getUtilizationPercent();
        feeRatio = vault.getVaultRatioBps(utilization);
        assertGe(feeRatio, 500, "Fee ratio should be at least 5% after repay");
        assertLe(feeRatio, 9500, "Fee ratio should be at most 95% after repay");
    }

    function testTwoBorrowersHighUtilThenLowUtil() public {
        address user2 = address(0x3);
        address depositor = address(0x4);

        // --- Phase 0: Scale up vault ---
        usdc.mint(address(this), 99_000e6);
        usdc.approve(address(vault), 99_000e6);
        vault.deposit(99_000e6, address(this));

        // --- Phase 1: Both borrowers borrow → ~79% utilization ---
        vm.prank(user1);
        vault.borrow(29_000e6);
        vm.prank(user2);
        vault.borrow(50_000e6);

        uint256 utilHigh = vault.getUtilizationPercent();
        assertEq(utilHigh, 7900, "Utilization should be 79%");

        uint256 feeRateHigh = vault.getCurrentVaultRatioBps();
        assertGt(feeRateHigh, 2000, "Fee rate at 79% util should exceed flat 20% zone");

        // --- Phase 2: Borrower1 deposits 100e6 rewards at HIGH utilization ---
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp and settle to see debt reduction at high util
        _warpAndSettle(user1);

        uint256 borrower1DebtAfter = vault.getDebtBalance(user1);
        uint256 borrower1DebtReduction = 29_000e6 - borrower1DebtAfter;
        uint256 lenderPremium1 = 100e6 - borrower1DebtReduction;

        // At high utilization, lender gets MORE than flat 20%
        uint256 flatLenderPremium1 = 100e6 * 2000 / 10000;
        assertGt(lenderPremium1, flatLenderPremium1, "Lender premium at high util should exceed flat 20%");

        // --- Phase 3: Depositor adds liquidity → util drops ---
        usdc.mint(depositor, 200_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, depositor);
        vm.stopPrank();

        uint256 utilLow = vault.getUtilizationPercent();
        uint256 feeRateLow = vault.getCurrentVaultRatioBps();
        assertLt(utilLow, 7000, "Utilization should be below 70%");
        assertEq(feeRateLow, 2000, "Fee rate should be flat 20% in 10-70% zone");

        // --- Phase 4: Borrower2 deposits 200e6 rewards at LOW utilization ---
        vm.startPrank(user2);
        deal(address(usdc), user2, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(200e6);
        vm.stopPrank();

        // Warp and settle
        vm.warp(EPOCH_4);
        vault.settleRewards(user2);

        uint256 borrower2DebtAfter = vault.getDebtBalance(user2);
        uint256 borrower2DebtReduction = 50_000e6 - borrower2DebtAfter;
        uint256 lenderPremium2 = 200e6 - borrower2DebtReduction;

        // At low utilization, lender gets ~20%
        assertApproxEqAbs(lenderPremium2, 200e6 * 2000 / 10000, 1e6, "Lender premium at low util should be ~20%");

        // --- Phase 5: Verify key relationships ---
        uint256 borrower1EffectiveBps = (borrower1DebtReduction * 10000) / 100e6;
        uint256 borrower2EffectiveBps = (borrower2DebtReduction * 10000) / 200e6;
        assertLt(borrower1EffectiveBps, borrower2EffectiveBps,
            "High-util borrower should keep less per reward dollar");

        uint256 lenderRate1 = (lenderPremium1 * 10000) / 100e6;
        uint256 lenderRate2 = (lenderPremium2 * 10000) / 200e6;
        assertGt(lenderRate1, lenderRate2, "Lender premium rate should be higher at high utilization");

        // Warp to fully vest all premiums
        vm.warp(EPOCH_5);

        // Share price should exceed 1:1
        uint256 sharePriceNow = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGt(sharePriceNow, 1e18, "Share price should exceed 1:1 from lender premiums");
    }

    // ============ Epoch-Based Lender Premium Vesting Tests ============

    function testLenderPremiumNotAvailableInDepositEpoch() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // totalAssets should NOT increase (rewards are unsettled)
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets should NOT increase in deposit epoch");

        // lenderPremiumUnlockedThisEpoch should be 0 (nothing vested globally yet)
        assertEq(vault.lenderPremiumUnlockedThisEpoch(), 0, "No premium unlocked in deposit epoch");
    }

    function testLenderPremiumVestsLinearly() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Lender premium = 20% of 100 = 20 USDC
        uint256 expectedPremium = 20e6;

        // Warp to end of stream epoch — global vesting extracts premium into vestingEpochPremium
        // Premium vests in the SAME epoch it's extracted (EPOCH_3)
        vm.warp(EPOCH_3);
        vault.sync();

        // At 25% elapsed in vesting epoch (EPOCH_3)
        vm.warp(EPOCH_3 + WEEK / 4);
        uint256 totalAssets25 = vault.totalAssets();
        uint256 vested25 = totalAssets25 - totalAssetsBefore;
        assertApproxEqAbs(vested25, expectedPremium / 4, 1e5, "25% should be vested at 25% elapsed");

        // At 50% elapsed
        vm.warp(EPOCH_3 + WEEK / 2);
        uint256 totalAssets50 = vault.totalAssets();
        uint256 vested50 = totalAssets50 - totalAssetsBefore;
        assertApproxEqAbs(vested50, expectedPremium / 2, 1e5, "50% should be vested at 50% elapsed");

        // At 100% elapsed (fully vested)
        vm.warp(EPOCH_4);
        uint256 totalAssets100 = vault.totalAssets();
        uint256 vested100 = totalAssets100 - totalAssetsBefore;
        assertApproxEqAbs(vested100, expectedPremium, 1e5, "100% should be vested after full epoch");
    }

    function testLenderPremiumFullyVestedAfterTwoEpochs() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // EPOCH_2: rewards deposited (streaming)
        // EPOCH_3: sync extracts premium → vestingEpochPremium (vests in same epoch)
        // EPOCH_4: fully vested
        vm.warp(EPOCH_3);
        vault.sync();
        vm.warp(EPOCH_4);

        // Premium should be fully vested
        assertEq(vault.getUnvestedLenderPremium(), 0, "All premium should be vested");

        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 increase = totalAssetsAfter - totalAssetsBefore;
        assertApproxEqAbs(increase, 20e6, 1e6, "Full lender premium should be reflected in totalAssets");
    }

    function testMultipleDepositsInSameEpochAccumulate() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        // Two reward deposits in same block
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.repayWithRewards(100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // totalAssets unchanged
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged in deposit epoch");
        assertEq(vault.getTotalUnsettledRewards(), 200e6, "Both deposits should be unsettled");

        // Warp, sync to extract premium, then wait for full vesting
        // EPOCH_3: sync extracts premium → vestingEpochPremium (vests in same epoch)
        // EPOCH_4: fully vested
        vm.warp(EPOCH_3);
        vault.sync();
        vm.warp(EPOCH_4);

        uint256 increase = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(increase, 40e6, 2e6, "Full accumulated premium should vest (~20% of 200)");
    }

    function testLenderPremiumVestingPreventsFrontRunning() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        // Front-runner deposits into the vault right before rewards
        address frontRunner = address(0x999);
        deal(address(usdc), frontRunner, 1000e6);
        vm.startPrank(frontRunner);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, frontRunner);
        vm.stopPrank();

        uint256 frontRunnerShares = vault.balanceOf(frontRunner);
        uint256 sharePriceBefore = vault.totalAssets() * 1e18 / vault.totalSupply();

        // Rewards deposited
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Share price should NOT have jumped (rewards are unsettled)
        uint256 sharePriceAfter = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertEq(sharePriceAfter, sharePriceBefore, "Share price should NOT jump immediately after rewards");

        // Front-runner tries to withdraw next block
        vm.roll(block.number + 1);
        vm.prank(frontRunner);
        uint256 assetsReceived = vault.redeem(frontRunnerShares, frontRunner, frontRunner);

        assertApproxEqAbs(assetsReceived, 1000e6, 1e6, "Front-runner should not capture lender premium");
    }

    // ============ View Function Tests ============

    function testGetPendingRewards() public {
        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Pending should be approximately the full amount (minus rounding from rate)
        uint256 pending = vault.getPendingRewards(user1);
        assertApproxEqAbs(pending, 100e6, 1e6, "Pending should be ~100");

        // Vested pending should be 0 (same block)
        assertEq(vault.getVestedPendingRewards(user1), 0, "Nothing vested yet");

        // Warp halfway
        vm.warp(EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2);
        uint256 vested = vault.getVestedPendingRewards(user1);
        assertApproxEqAbs(vested, 50e6, 1e6, "~50% should be vested at halfway");
    }

    function testGlobalVestingOnDeposit() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrow(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.repayWithRewards(100e6);
        vm.stopPrank();

        // Warp to end of epoch
        vm.warp(EPOCH_3);

        // A lender deposit triggers _processGlobalVesting
        address lender = address(0x777);
        deal(address(usdc), lender, 100e6);
        vm.startPrank(lender);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, lender);
        vm.stopPrank();

        // Global vesting should have processed — lender premium extracted
        // globalBorrowerPending should be > 0 (borrower credit accumulated but not per-user settled)
        assertGt(vault.getGlobalBorrowerPending(), 0, "Global borrower pending should be > 0 after deposit triggers vesting");
    }

    // ============ Sync Frequency Equivalence Tests ============

    /// @notice Two users deposit equal rewards at epoch start. User1 syncs at mid-epoch + end,
    ///         user2 syncs only at end. A large lender deposit mid-epoch drops utilization
    ///         significantly, changing the fee ratio. Both users should receive approximately
    ///         equal debt reduction despite different sync frequencies.
    function testDailySyncVsEndOfEpochSync_EqualRewards() public {
        address user2 = address(0x3);

        // Both users borrow 200 USDC each (40% utilization → ratio = 2000 bps in flat zone)
        vm.prank(user1);
        vault.borrow(200e6);
        vm.prank(user2);
        vault.borrow(200e6);
        assertEq(vault.getUtilizationPercent(), 4000, "40% utilization");

        // Both deposit 100 USDC rewards at epoch start
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

        uint256 debtUser1Before = vault.getDebtBalance(user1);
        uint256 debtUser2Before = vault.getDebtBalance(user2);
        assertEq(debtUser1Before, 200e6);
        assertEq(debtUser2Before, 200e6);

        // === Mid-epoch: User1 syncs, then utilization drops ===
        uint256 midEpoch = EPOCH_2 + (WEEK / 2);
        vm.warp(midEpoch);

        // User1 settles at mid-epoch (triggers global vesting for first half at high util)
        vault.settleRewards(user1);
        uint256 debtUser1AtMid = vault.getDebtBalance(user1);
        assertLt(debtUser1AtMid, debtUser1Before, "User1 debt should decrease at mid-epoch");

        // A large lender deposit drops utilization from ~40% to ~4%
        address bigLender = address(0x888);
        deal(address(usdc), bigLender, 9000e6);
        vm.startPrank(bigLender);
        usdc.approve(address(vault), 9000e6);
        vault.deposit(9000e6, bigLender);
        vm.stopPrank();

        // Verify utilization dropped significantly
        assertLt(vault.getUtilizationPercent(), 1000, "Utilization should be < 10%");

        // === End of epoch: Both users settle ===
        vm.warp(EPOCH_3);

        // User1 settles again (second half at lower utilization ratio)
        vault.settleRewards(user1);

        // User2 settles for the first time (full stream, capped at globalBorrowerPending)
        vault.settleRewards(user2);

        // Compare debt reductions
        uint256 debtReduction1 = debtUser1Before - vault.getDebtBalance(user1);
        uint256 debtReduction2 = debtUser2Before - vault.getDebtBalance(user2);

        // Both should receive approximately the same debt reduction
        // Difference is only from minor ratio drift between _processGlobalVesting and _settleRewards
        assertApproxEqAbs(
            debtReduction1,
            debtReduction2,
            1e6, // 1 USDC tolerance for ratio drift dust
            "Both users should receive approximately equal debt reduction regardless of sync frequency"
        );

        // Both should have meaningful debt reduction (not zero)
        assertGt(debtReduction1, 50e6, "User1 should have significant debt reduction");
        assertGt(debtReduction2, 50e6, "User2 should have significant debt reduction");
    }

    /// @notice Same setup but with 7 daily syncs for user1 to simulate actual daily settlement.
    ///         Verifies the principle holds with more granular sync frequency.
    function testSevenDailySyncsVsSingleSync_EqualRewards() public {
        address user2 = address(0x3);

        // Both users borrow 200 USDC each
        vm.prank(user1);
        vault.borrow(200e6);
        vm.prank(user2);
        vault.borrow(200e6);

        // Both deposit 100 USDC rewards at epoch start
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

        uint256 debtUser1Before = vault.getDebtBalance(user1);
        uint256 debtUser2Before = vault.getDebtBalance(user2);

        uint256 dayDuration = WEEK / 7; // ~86400 seconds

        // User1 syncs every day. On day 3, a big deposit drops utilization.
        for (uint256 i = 1; i <= 7; i++) {
            uint256 dayTime = EPOCH_2 + (dayDuration * i);
            vm.warp(dayTime);

            // User1 settles daily
            vault.settleRewards(user1);

            // On day 3: big lender deposit drops utilization
            if (i == 3) {
                address bigLender = address(0x888);
                deal(address(usdc), bigLender, 9000e6);
                vm.startPrank(bigLender);
                usdc.approve(address(vault), 9000e6);
                vault.deposit(9000e6, bigLender);
                vm.stopPrank();
            }
        }

        // User2 settles only once at end of epoch
        vault.settleRewards(user2);

        uint256 debtReduction1 = debtUser1Before - vault.getDebtBalance(user1);
        uint256 debtReduction2 = debtUser2Before - vault.getDebtBalance(user2);

        assertApproxEqAbs(
            debtReduction1,
            debtReduction2,
            1e6,
            "Daily syncer and end-of-epoch syncer should receive approximately equal debt reduction"
        );

        assertGt(debtReduction1, 50e6, "User1 should have significant debt reduction");
        assertGt(debtReduction2, 50e6, "User2 should have significant debt reduction");
    }
}
