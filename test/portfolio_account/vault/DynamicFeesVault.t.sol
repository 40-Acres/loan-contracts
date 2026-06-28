// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console, Vm} from "forge-std/Test.sol";
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
    function ownerOf(address portfolio) external pure override returns (address) { return portfolio; }
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
            address(usdc), "USDC Vault", "vUSDC", address(portfolioFactory), address(this), uint256(0)
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
        vault.borrowFromPortfolio(790e6);
        assertLt(vault.getUtilizationPercent(), 8000);
    }

    function testBorrowAndRepay() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(790e6);

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
        vault.borrowFromPortfolio(500e6);

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        vm.expectRevert();
        vault.withdraw(vaultBalance + 1, address(this), address(this));
    }

    function testTotalAssetsIncludesLoanedAssets() public {
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets should include loaned assets");
    }

    function testUtilizationCalculation() public {
        assertEq(vault.totalAssets(), 1000e6);
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);
        assertEq(vault.getUtilizationPercent(), 5000, "Utilization should be 50%");
    }

    function testMultipleUsersBorrow() public {
        address user2 = address(0x3);
        vm.prank(user1);
        vault.borrowFromPortfolio(300e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        assertEq(vault.getDebtBalance(user1), 300e6);
        assertEq(vault.getDebtBalance(user2), 200e6);
        assertEq(vault.totalLoanedAssets(), 500e6);
        assertEq(vault.getTotalDebtBalance(), 500e6);
    }

    function testOverRepayOnlyRepaysDebt() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(100e6);

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
        vault.borrowFromPortfolio(500e6);

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
        vault.borrowFromPortfolio(500e6);

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertEq(vaultBalance, 500e6);

        uint256 maxWithdrawable = vault.maxWithdraw(address(this));
        assertGt(maxWithdrawable, 0);
        assertLe(maxWithdrawable, vaultBalance);
    }

    function testCanBorrowWhenUtilizationUnder80Percent() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(700e6);

        address user2 = address(0x3);
        vm.prank(user2);
        vault.borrowFromPortfolio(50e6);

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
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Debt should NOT be reduced immediately — rewards are streaming
        assertEq(vault.getDebtBalance(user1), 500e6, "Debt should not change immediately");
        assertGt(vault.getActiveEpochRate(), 0, "Stream should be active");
        assertApproxEqAbs(vault.getTotalUnsettledRewards(), 100e6, 1e6, "Unsettled should be ~100");
    }

    function testRepayWithRewardsReducesDebtAfterVesting() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(300e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        // user1 deposits rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(100e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);
        vm.prank(user3);
        vault.borrowFromPortfolio(300e6);

        // Multiple reward deposits from different users
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 80e6);
        usdc.approve(address(vault), 80e6);
        vault.depositRewards(80e6);
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
        vault.borrowFromPortfolio(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.depositRewards(150e6);
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
        vault.borrowFromPortfolio(100e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
        vm.stopPrank();

        // Share price shouldn't decrease immediately
        uint256 sharePriceNow = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertGe(sharePriceNow, sharePriceBefore, "Share price should not decrease immediately");

        // Warp and settle to clear debt + excess
        _warpAndSettle(user1);
        assertEq(vault.getDebtBalance(user1), 0);

        // Premium extracted lazily at EPOCH_3 (settle path), routed to
        // vestingEpochPremium with vestStart=EPOCH_3, fully vested by EPOCH_4.
        // Warp to EPOCH_5 for safety margin.
        vm.warp(EPOCH_5);

        uint256 totalSupplyAfter = vault.totalSupply();
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = totalAssetsAfter * 1e18 / totalSupplyAfter;

        assertGe(sharePriceAfter, sharePriceBefore, "Share price should not decrease after vesting");
        assertEq(vault.balanceOf(user1), 0, "Borrower should not receive vault shares");
    }

    function testMultipleRepayWithRewardsAccumulate() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Deposit 3 times in same block — streams combine
        vm.startPrank(user1);
        deal(address(usdc), user1, 300e6);
        usdc.approve(address(vault), 300e6);
        vault.depositRewards(100e6);
        vault.depositRewards(100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // All 300 should be streaming
        assertApproxEqAbs(vault.getTotalUnsettledRewards(), 300e6, 2e6, "All 300 should be ~unsettled");

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
        vault.borrowFromPortfolio(300e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 150e6);
        usdc.approve(address(vault), 150e6);
        vault.depositRewards(150e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(100e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(150e6);
        vm.prank(user3);
        vault.borrowFromPortfolio(200e6);
        vm.prank(user4);
        vault.borrowFromPortfolio(100e6);

        assertEq(vault.totalLoanedAssets(), 550e6);
        assertEq(vault.getTotalDebtBalance(), 550e6);

        // Each user deposits their own rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 75e6);
        usdc.approve(address(vault), 75e6);
        vault.depositRewards(75e6);
        vm.stopPrank();

        vm.startPrank(user3);
        deal(address(usdc), user3, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user4);
        deal(address(usdc), user4, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
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
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(500e6);

        // First deposit at epoch start
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Warp to 50% and make second deposit
        uint256 halfwayPoint = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        vm.warp(halfwayPoint);

        vm.startPrank(user1);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(500e6);
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged after borrow");

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // totalAssets should be approximately unchanged (tiny dust from rate truncation)
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1e6, "totalAssets ~unchanged after reward deposit");
    }

    function testTotalAssetsIncreasesAfterLenderPremiumVests() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Warp to end of stream epoch — sync triggers global vesting
        // (single-bucket model). Premium routes to vestingEpochPremium with
        // vestStart = epochStart(now) = EPOCH_3. Vesting starts immediately
        // across EPOCH_3..EPOCH_4 and is fully realized by EPOCH_4.
        vm.warp(EPOCH_3);
        vault.sync();

        // At EPOCH_3 start, vesting just began (elapsed = 0). totalAssets
        // approximately unchanged because the unvested deduction equals the
        // freshly-routed premium.
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1e6, "totalAssets ~unchanged at start of vest epoch");

        // Halfway through the vest epoch (EPOCH_3 + WEEK/2): ~50% of premium
        // has bled into totalAssets. Warp further to EPOCH_4 + WEEK/2 (deep
        // into the next epoch) for fully-vested observation.
        vm.warp(EPOCH_4 + WEEK / 2);

        uint256 totalAssetsMid = vault.totalAssets();
        assertGt(totalAssetsMid, totalAssetsBefore, "totalAssets should increase as premium vests");

        // Warp to fully vested (well past EPOCH_4)
        vm.warp(EPOCH_5);

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
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // totalAssets approximately unchanged in deposit epoch (tiny dust from rate truncation)
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1e6, "totalAssets ~unchanged in deposit epoch");

        // Warp to end of stream and settle
        _warpAndSettle(user1);

        // Borrower debt reduction = 80% of 100 = 80
        uint256 debtReduction = 500e6 - vault.getDebtBalance(user1);
        assertApproxEqAbs(debtReduction, 80e6, 2e6, "Debt reduction should be ~80 USDC at 20% fee");

        // Premium routed to vestingEpochPremium at EPOCH_3 (single-bucket), fully vested by EPOCH_4. EPOCH_5 = safety margin.
        vm.warp(EPOCH_5);

        uint256 lenderPremium = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(lenderPremium, 20e6, 2e6, "Lender premium should be ~20 USDC at 20% fee after vesting");
    }

    function testFeeSplitAt50Percent() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(5000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Warp and settle
        _warpAndSettle(user1);

        uint256 debtReduction = 500e6 - vault.getDebtBalance(user1);
        assertApproxEqAbs(debtReduction, 50e6, 2e6, "Debt reduction should be ~50 USDC at 50% fee");

        // Premium routed to vestingEpochPremium at EPOCH_3 (single-bucket), fully vested by EPOCH_4. EPOCH_5 = safety margin.
        vm.warp(EPOCH_5);

        uint256 lenderPremium = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(lenderPremium, 50e6, 2e6, "Lender premium should be ~50 USDC at 50% fee after vesting");
    }

    function testFeeCalculatorSwapAffectsRewardSplit() public {
        FlatFeeCalculator lowFee = new FlatFeeCalculator(2000); // 20% lender
        vm.prank(owner);
        vault.setFeeCalculator(address(lowFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Deposit rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(100e6);
    }

    function testCannotRepayWhenPaused() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(100e6);
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
        vault.borrowFromPortfolio(100e6);
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(DynamicFeesVault.ContractPaused.selector);
        vault.depositRewards(100e6);
        vm.stopPrank();
    }

    function testCannotDepositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(); // maxDeposit returns 0 when paused → ERC4626ExceededMaxDeposit
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
        vault.borrowFromPortfolio(200e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(amount);
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
        vault.borrowFromPortfolio(borrowAmount);

        vm.startPrank(user1);
        deal(address(usdc), user1, rewardAmount);
        usdc.approve(address(vault), rewardAmount);
        vault.depositRewards(rewardAmount);
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
        vault.borrowFromPortfolio(300e6);
        assertEq(vault.getTotalDebtBalance(), 300e6);

        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);
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
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Before vesting, debt unchanged
        assertEq(vault.getTotalDebtBalance(), 500e6, "Total debt unchanged before vesting");

        // After vesting + settle
        _warpAndSettle(user1);

        uint256 debt = vault.getDebtBalance(user1);
        assertEq(vault.getTotalDebtBalance(), debt, "totalDebtBalance should match user debt after settle");
    }

    // ============ Edge Cases ============

    function testRepayWithRewardsNoDebt() public {
        // User has no debt — depositRewards should revert because there's nothing to repay
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert("No debt to repay");
        vault.depositRewards(100e6);
        vm.stopPrank();
    }

    function testExcessRewardsPaidAsUSDC() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(50e6);

        uint256 user1UsdcBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
        vm.stopPrank();

        // Warp and settle — excess sent as USDC
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");
        assertGt(usdc.balanceOf(user1), user1UsdcBefore, "Should receive USDC for excess");
    }

    function testMultipleUsersRepayWithRewardsEarlyRepayerGetsUSDC() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrowFromPortfolio(100e6);

        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        // User1 deposits 200 rewards against 100 debt
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
        vm.stopPrank();

        // Warp and settle user1 — should get excess
        _warpAndSettle(user1);

        assertEq(vault.getDebtBalance(user1), 0, "User1 debt should be fully paid");
        assertGt(usdc.balanceOf(user1), 0, "User1 should receive USDC for excess rewards");

        // User2 deposits 100 rewards against 200 debt
        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Warp and settle user2
        vm.warp(EPOCH_4);
        vault.settleRewards(user2);

        assertLt(vault.getDebtBalance(user2), 200e6, "User2 debt should be reduced");
        assertGt(vault.getDebtBalance(user2), 0, "User2 should still have remaining debt");
    }

    // ============ H-09 / H-10 Regression Tests ============

    /// @notice H-09: Ratio change between settlements doesn't skew distribution.
    ///         Two users deposit equal rewards. Utilization changes mid-epoch.
    ///         Both should receive approximately equal borrower credit.
    function testH09_UtilizationChangeDoesNotSkewFeeSplit() public {
        address user2 = address(0x3);

        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000); // 20% lender at low util
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        // Both users borrow 200 USDC each
        vm.prank(user1);
        vault.borrowFromPortfolio(200e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        // Both deposit 100 USDC rewards at epoch start
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 debtUser1Before = vault.getDebtBalance(user1);
        uint256 debtUser2Before = vault.getDebtBalance(user2);

        // Mid-epoch: settle user1, then change fee calculator to simulate ratio change
        uint256 midEpoch = EPOCH_2 + (WEEK / 2);
        vm.warp(midEpoch);
        vault.settleRewards(user1);

        // Switch to high fee calculator (60% lender) — simulates utilization-driven ratio change
        FlatFeeCalculator highFee = new FlatFeeCalculator(6000);
        vm.prank(owner);
        vault.setFeeCalculator(address(highFee));

        // End of epoch: settle both users
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);

        uint256 debtReduction1 = debtUser1Before - vault.getDebtBalance(user1);
        uint256 debtReduction2 = debtUser2Before - vault.getDebtBalance(user2);

        // Both users had equal rates over the same interval, so their borrower credit
        // should be approximately equal (within rounding tolerance)
        assertApproxEqAbs(
            debtReduction1,
            debtReduction2,
            1e6, // 1 USDC tolerance for rounding
            "H-09: Equal streams should receive equal borrower credit regardless of settlement timing"
        );

        // Both should have meaningful debt reduction
        assertGt(debtReduction1, 30e6, "User1 should have significant debt reduction");
        assertGt(debtReduction2, 30e6, "User2 should have significant debt reduction");
    }

    /// @notice H-10: globalBorrowerPending drains to ~0 when all users settle.
    ///         Three users deposit rewards, all settle at epoch end.
    function testH10_GlobalBorrowerPendingDrainsToZero() public {
        address user2 = address(0x3);
        address user3 = address(0x4);

        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        // Three users borrow
        vm.prank(user1);
        vault.borrowFromPortfolio(100e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);
        vm.prank(user3);
        vault.borrowFromPortfolio(300e6);

        // All three deposit rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 80e6);
        usdc.approve(address(vault), 80e6);
        vault.depositRewards(80e6);
        vm.stopPrank();

        vm.startPrank(user3);
        deal(address(usdc), user3, 120e6);
        usdc.approve(address(vault), 120e6);
        vault.depositRewards(120e6);
        vm.stopPrank();

        // Warp to epoch end, settle all
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);
        vault.settleRewards(user2);
        vault.settleRewards(user3);

        // globalBorrowerPending should be drained to ~0 (only rounding dust)
        uint256 residue = vault.getGlobalBorrowerPending();
        assertLe(residue, 3, "H-10: globalBorrowerPending should drain to ~0 after all users settle");
    }

    /// @notice Accumulator handles multiple _processGlobalVesting() calls with different ratios.
    ///         User deposits rewards, ratio changes mid-epoch, borrower credit reflects weighted average.
    function testAccumulatorConsistentAcrossMultipleVestingTicks() public {
        FlatFeeCalculator lowFee = new FlatFeeCalculator(2000); // 80% borrower
        vm.prank(owner);
        vault.setFeeCalculator(address(lowFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 debtBefore = vault.getDebtBalance(user1);

        // Warp to 25% through epoch → trigger global vesting at R1=2000 (80% borrower)
        uint256 quarter = EPOCH_2 + WEEK / 4;
        vm.warp(quarter);
        vault.sync(); // triggers _processGlobalVesting

        // Switch to 60% lender (40% borrower)
        FlatFeeCalculator highFee = new FlatFeeCalculator(6000);
        vm.prank(owner);
        vault.setFeeCalculator(address(highFee));

        // Warp to 75% through epoch → trigger global vesting at R2=6000 (40% borrower)
        uint256 threeQuarter = EPOCH_2 + 3 * WEEK / 4;
        vm.warp(threeQuarter);
        vault.sync(); // triggers _processGlobalVesting again

        // Warp to epoch end and settle
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        uint256 debtReduction = debtBefore - vault.getDebtBalance(user1);

        // Expected: 25% of epoch at 80% borrower + 50% of epoch at 40% borrower + 25% at 40% borrower
        // First 25%:  ~25 USDC vested * 80% = ~20 borrower credit
        // Next 50%:   ~50 USDC vested * 40% = ~20 borrower credit
        // Last 25%:   ~25 USDC vested * 40% = ~10 borrower credit
        // Total: ~50 USDC borrower credit
        // Note: rate truncation may cause slight variation
        uint256 expectedBorrowerCredit = 50e6; // weighted average
        assertApproxEqAbs(
            debtReduction,
            expectedBorrowerCredit,
            3e6, // 3 USDC tolerance for rate truncation
            "Borrower credit should reflect weighted average of different ratios"
        );

        // globalBorrowerPending should be ~0 after single user settles
        assertLe(vault.getGlobalBorrowerPending(), 1, "No residue after settle");
    }

    function testFeeRatioBoundsAfterBorrowAndRewards() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
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
        vault.borrowFromPortfolio(29_000e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(50_000e6);

        uint256 utilHigh = vault.getUtilizationPercent();
        assertEq(utilHigh, 7900, "Utilization should be 79%");

        uint256 feeRateHigh = vault.getCurrentVaultRatioBps();
        assertGt(feeRateHigh, 2000, "Fee rate at 79% util should exceed flat 20% zone");

        // --- Phase 2: Borrower1 deposits 100e6 rewards at HIGH utilization ---
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.depositRewards(200e6);
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

        // Warp to fully vest all premiums (single-bucket model: vest in deposit epoch).
        // EPOCH_6 is well past any vest epoch in this scenario.
        uint256 EPOCH_6 = 6 * WEEK;
        vm.warp(EPOCH_6);

        // Share price should exceed initial 1:1 ratio
        // With _decimalsOffset, share price base is different, so compare against initial
        uint256 initialSharePrice = 1e6 * 1e18 / (10 ** vault.decimals()); // 1 asset per share at 1:1
        uint256 sharePriceNow = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGt(sharePriceNow, initialSharePrice, "Share price should exceed 1:1 from lender premiums");
    }

    // ============ Epoch-Based Lender Premium Vesting Tests ============

    function testLenderPremiumNotAvailableInDepositEpoch() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // totalAssets should be approximately unchanged (tiny dust from rate truncation)
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1e6, "totalAssets ~unchanged in deposit epoch");

        // lenderPremiumUnlockedThisEpoch should be 0 (nothing vested globally yet)
        assertEq(vault.lenderPremiumUnlockedThisEpoch(), 0, "No premium unlocked in deposit epoch");
    }

    function testLenderPremiumVestsLinearly() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Lender premium = 20% of 100 = 20 USDC
        uint256 expectedPremium = 20e6;

        // Warp to end of stream epoch — sync finalizes the stream and routes
        // the lender premium into vestingEpochPremium with
        // vestStart = max(existing=0, epochStart(now)=EPOCH_3) = EPOCH_3.
        // Under the single-bucket current-epoch vesting model premium starts
        // releasing immediately and is fully realized by EPOCH_4.
        vm.warp(EPOCH_3);
        vault.sync();

        // At 25% elapsed in vesting epoch (EPOCH_3)
        vm.warp(EPOCH_3 + WEEK / 4);
        uint256 totalAssets25 = vault.totalAssets();
        uint256 vested25 = totalAssets25 - totalAssetsBefore;
        assertApproxEqAbs(vested25, expectedPremium / 4, 1e6, "25% should be vested at 25% elapsed");

        // At 50% elapsed
        vm.warp(EPOCH_3 + WEEK / 2);
        uint256 totalAssets50 = vault.totalAssets();
        uint256 vested50 = totalAssets50 - totalAssetsBefore;
        assertApproxEqAbs(vested50, expectedPremium / 2, 1e6, "50% should be vested at 50% elapsed");

        // At 100% elapsed (fully vested by start of EPOCH_4)
        vm.warp(EPOCH_4);
        uint256 totalAssets100 = vault.totalAssets();
        uint256 vested100 = totalAssets100 - totalAssetsBefore;
        assertApproxEqAbs(vested100, expectedPremium, 1e6, "100% should be vested after full epoch");
    }

    function testLenderPremiumFullyVestedAfterTwoEpochs() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // EPOCH_2: rewards deposited (streaming)
        // EPOCH_3: sync routes premium to vestingEpochPremium with vestStart=EPOCH_3
        // EPOCH_4: vesting epoch ends, premium fully realized into totalAssets
        // EPOCH_5: well past full vest (safety margin)
        vm.warp(EPOCH_3);
        vault.sync();
        vm.warp(EPOCH_5);

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
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        // Two reward deposits in same block
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // totalAssets approximately unchanged (tiny dust from rate truncation)
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 2e6, "totalAssets ~unchanged in deposit epoch");
        assertApproxEqAbs(vault.getTotalUnsettledRewards(), 200e6, 2e6, "Both deposits should be ~unsettled");

        // Warp, sync to route premium to vestingEpochPremium, then wait for full vest.
        // EPOCH_3: sync routes premium with vestStart=EPOCH_3 (single bucket)
        // EPOCH_4: fully realized into totalAssets
        // EPOCH_5: safety margin
        vm.warp(EPOCH_3);
        vault.sync();
        vm.warp(EPOCH_5);

        uint256 increase = vault.totalAssets() - totalAssetsBefore;
        assertApproxEqAbs(increase, 40e6, 2e6, "Full accumulated premium should vest (~20% of 200)");
    }

    function testLenderPremiumVestingPreventsFrontRunning() public {
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

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
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Share price should NOT have jumped meaningfully (tiny dust from rate truncation)
        uint256 sharePriceAfter = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertApproxEqRel(sharePriceAfter, sharePriceBefore, 1e15, "Share price should NOT jump immediately after rewards");

        // Front-runner tries to withdraw next block
        vm.roll(block.number + 1);
        vm.prank(frontRunner);
        uint256 assetsReceived = vault.redeem(frontRunnerShares, frontRunner, frontRunner);

        assertApproxEqAbs(assetsReceived, 1000e6, 1e6, "Front-runner should not capture lender premium");
    }

    // ============ View Function Tests ============

    function testGetPendingRewards() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(500e6);

        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(200e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);
        assertEq(vault.getUtilizationPercent(), 4000, "40% utilization");

        // Both deposit 100 USDC rewards at epoch start
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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
        vault.borrowFromPortfolio(200e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        // Both deposit 100 USDC rewards at epoch start
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.startPrank(user2);
        deal(address(usdc), user2, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
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

    // ============ Cross-Epoch Reward Isolation ============

    /// @notice An expired stream from epoch N must not earn credit from epoch N+1.
    ///         Regression test for the stale-accumulator bug where an unsettled
    ///         userRewardRate could multiply accumulator deltas it never contributed to.
    function testExpiredStreamCannotClaimCrossEpochCredit() public {
        address alice = address(0xA);
        address bob   = address(0xB);

        vm.prank(alice);
        vault.borrowFromPortfolio(200e6);
        vm.prank(bob);
        vault.borrowFromPortfolio(200e6);

        // Epoch 2: alice streams 50 USDC of rewards
        vm.startPrank(alice);
        deal(address(usdc), alice, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        uint256 aliceDebtAfterStream = vault.getDebtBalance(alice);

        // Cross into epoch 3 without settling alice
        vm.warp(EPOCH_3 + 1);
        vault.sync();

        // Epoch 3: bob streams 100 USDC of rewards
        vm.startPrank(bob);
        deal(address(usdc), bob, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 bobDebtBefore = vault.getDebtBalance(bob);

        // Let epoch 3 fully vest, then settle both
        vm.warp(EPOCH_4 + 1);

        vault.settleRewards(alice);
        uint256 aliceReduction = aliceDebtAfterStream - vault.getDebtBalance(alice);

        vault.settleRewards(bob);
        uint256 bobReduction = bobDebtBefore - vault.getDebtBalance(bob);

        // Alice deposited 50e6; at ~20% lender fee she should get ~40e6 max
        assertLe(aliceReduction, 50e6, "Alice must not exceed her own deposit");
        assertApproxEqAbs(aliceReduction, 40e6, 2e6, "Alice gets ~80% of her 50e6 deposit");

        // Bob deposited 100e6; he should get ~80e6
        assertApproxEqAbs(bobReduction, 80e6, 2e6, "Bob gets ~80% of his 100e6 deposit");
    }

    // ============ Public settleRewards Griefing ============

    /// @notice Attacker settles an expired user from epoch N while epoch N+1 is active.
    ///         activeEpochRate must not be corrupted — Bob's stream should vest normally.
    function testPublicSettleRewardsDoesNotCorruptActiveRate() public {
        address alice    = address(0xA);
        address bob      = address(0xB);
        address attacker = address(0xC);

        vm.prank(alice);
        vault.borrowFromPortfolio(200e6);
        vm.prank(bob);
        vault.borrowFromPortfolio(200e6);

        // Epoch 2: alice streams rewards
        vm.startPrank(alice);
        deal(address(usdc), alice, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Cross into epoch 3
        vm.warp(EPOCH_3 + 1);

        // Bob starts a stream in epoch 3
        vm.startPrank(bob);
        deal(address(usdc), bob, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 activeRateBefore = vault.getActiveEpochRate();
        assertGt(activeRateBefore, 0, "Bob's stream should be active");

        // Attacker grief-settles alice's expired stream — should NOT touch activeEpochRate
        vm.prank(attacker);
        vault.settleRewards(alice);

        uint256 activeRateAfter = vault.getActiveEpochRate();
        assertEq(activeRateAfter, activeRateBefore, "activeEpochRate must not change when settling an expired user");

        // Bob's stream should vest fully
        uint256 bobDebtBefore = vault.getDebtBalance(bob);
        vm.warp(EPOCH_4 + 1);
        vault.settleRewards(bob);
        uint256 bobReduction = bobDebtBefore - vault.getDebtBalance(bob);

        assertApproxEqAbs(bobReduction, 80e6, 2e6, "Bob gets full ~80% of his 100e6 deposit");
    }

    /// @notice Mass griefing: attacker settles many expired users in a new epoch.
    ///         The active user's rewards must remain intact.
    function testMassGriefSettleDoesNotDrainActiveRewards() public {
        address active   = address(0xF);
        address attacker = address(0xE);

        // 5 users borrow and stream in epoch 2
        address[5] memory stale;
        for (uint256 i = 0; i < 5; i++) {
            stale[i] = address(uint160(0x10 + i));
            vm.prank(stale[i]);
            vault.borrowFromPortfolio(100e6);

            vm.startPrank(stale[i]);
            deal(address(usdc), stale[i], 20e6);
            usdc.approve(address(vault), 20e6);
            vault.depositRewards(20e6);
            vm.stopPrank();
        }

        // Cross into epoch 3
        vm.warp(EPOCH_3 + 1);

        // Active user borrows and streams in epoch 3
        vm.prank(active);
        vault.borrowFromPortfolio(100e6);
        vm.startPrank(active);
        deal(address(usdc), active, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        uint256 activeRateBefore = vault.getActiveEpochRate();

        // Attacker settles all 5 expired users
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(attacker);
            vault.settleRewards(stale[i]);
        }

        uint256 activeRateAfter = vault.getActiveEpochRate();
        assertEq(activeRateAfter, activeRateBefore, "Settling 5 expired users must not reduce active rate");

        // Active user gets full rewards
        uint256 debtBefore = vault.getDebtBalance(active);
        vm.warp(EPOCH_4 + 1);
        vault.settleRewards(active);
        uint256 reduction = debtBefore - vault.getDebtBalance(active);

        assertApproxEqAbs(reduction, 80e6, 2e6, "Active user gets ~80% of their 100e6 deposit");
    }

    /// @notice Double-subtraction: attacker settles an active user mid-epoch, then
    ///         the user calls depositRewards. activeEpochRate must stay consistent.
    function testNoDoubleSubtractionOnSettleThenRepayWithRewards() public {
        address alice    = address(0xA);
        address bob      = address(0xB);
        address attacker = address(0xC);

        vm.prank(alice);
        vault.borrowFromPortfolio(200e6);
        vm.prank(bob);
        vault.borrowFromPortfolio(200e6);

        // Both stream 50e6 in epoch 2
        vm.startPrank(alice);
        deal(address(usdc), alice, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        vm.startPrank(bob);
        deal(address(usdc), bob, 50e6);
        usdc.approve(address(vault), 50e6);
        vault.depositRewards(50e6);
        vm.stopPrank();

        // Halfway through epoch 2
        uint256 midEpoch = EPOCH_2 + (EPOCH_3 - EPOCH_2) / 2;
        vm.warp(midEpoch);

        uint256 rateBefore = vault.getActiveEpochRate();

        // Attacker force-settles alice (stream still active, mid-epoch)
        vm.prank(attacker);
        vault.settleRewards(alice);

        // activeEpochRate should not have changed (active stream settle doesn't subtract)
        assertEq(vault.getActiveEpochRate(), rateBefore, "Settle of active stream must not change activeEpochRate");

        // Alice rolls her stream with new rewards — single subtract + add
        vm.startPrank(alice);
        deal(address(usdc), alice, 30e6);
        usdc.approve(address(vault), 30e6);
        vault.depositRewards(30e6);
        vm.stopPrank();

        // Rate should reflect: removed old alice rate, added new alice rate, bob unchanged
        uint256 rateAfter = vault.getActiveEpochRate();
        assertGt(rateAfter, 0, "Rate should be positive after stream rollover");

        // Let epoch finish, both settle, both should get meaningful debt reduction
        vm.warp(EPOCH_3 + 1);
        vault.settleRewards(alice);
        vault.settleRewards(bob);

        assertLt(vault.getDebtBalance(alice), 200e6, "Alice should have debt reduced");
        assertLt(vault.getDebtBalance(bob), 200e6, "Bob should have debt reduced");
    }

    // ============ Effective Utilization Tests ============
    // These tests verify that getUtilizationPercent() uses effective outstanding
    // debt (totalLoanedAssets - totalVestedRewardsApplied - globalBorrowerPending)
    // rather than raw totalLoanedAssets.

    /// @notice After rewards vest and settle, utilization should drop because
    ///         effective debt is lower, even though totalLoanedAssets is unchanged
    ///         until the actual repay call clears it.
    function testUtilizationDropsAfterRewardsVest() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Utilization before rewards: 500/1000 = 50%
        uint256 utilBefore = vault.getUtilizationPercent();
        assertEq(utilBefore, 5000, "Utilization should be 50% before rewards");

        // Deposit 200 USDC of rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
        vm.stopPrank();

        // Warp to end of epoch so rewards fully vest, then settle
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        // After settling, globalBorrowerPending should be drained to user,
        // but totalVestedRewardsApplied increases. Effective debt < 500.
        uint256 utilAfter = vault.getUtilizationPercent();
        assertLt(utilAfter, utilBefore, "Utilization should drop after rewards vest and settle");

        // Verify the components: totalLoanedAssets is still 500 but effective is lower
        uint256 rawLoaned = vault.totalLoanedAssets();
        assertEq(rawLoaned, 500e6, "Raw totalLoanedAssets unchanged until repay clears it");

        uint256 vestedApplied = vault.totalVestedRewardsApplied();
        assertGt(vestedApplied, 0, "Some rewards should have been applied to debt");
    }

    /// @notice Utilization should reflect globalBorrowerPending even before
    ///         per-user settlement, as long as global vesting has run.
    function testUtilizationReflectsGlobalBorrowerPending() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Deposit rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Warp to mid-epoch
        uint256 midEpoch = EPOCH_2 + (WEEK / 2);
        vm.warp(midEpoch);

        // Trigger global vesting via sync (does NOT settle per-user)
        vault.sync();

        uint256 globalPending = vault.getGlobalBorrowerPending();
        assertGt(globalPending, 0, "Global borrower pending should be > 0 after vesting");

        // Utilization should account for globalBorrowerPending
        uint256 utilization = vault.getUtilizationPercent();

        // Compute expected: effectiveLoaned = 500e6 - totalVestedApplied - globalPending
        uint256 vestedApplied = vault.totalVestedRewardsApplied();
        uint256 effectiveLoaned = 500e6 - vestedApplied - globalPending;
        uint256 expectedUtil = (effectiveLoaned * 10000) / vault.totalAssets();

        assertEq(utilization, expectedUtil, "Utilization should use effective loaned amount");
        assertLt(utilization, 5000, "Utilization should be below 50% due to pending rewards");
    }

    /// @notice When rewards exceed debt (excess paid out), utilization should
    ///         drop to 0 for that borrower's portion.
    function testUtilizationDropsToZeroWhenDebtFullyPaid() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(100e6);

        // Deposit more rewards than debt
        vm.startPrank(user1);
        deal(address(usdc), user1, 200e6);
        usdc.approve(address(vault), 200e6);
        vault.depositRewards(200e6);
        vm.stopPrank();

        // Vest and settle
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        // Debt should be 0, utilization should be 0
        assertEq(vault.getDebtBalance(user1), 0, "Debt should be fully paid");
        assertEq(vault.getUtilizationPercent(), 0, "Utilization should be 0 when all debt paid");
    }

    /// @notice With two borrowers, partial vesting for one should reduce
    ///         utilization proportionally.
    function testUtilizationWithMultipleBorrowersPartialVesting() public {
        address user2 = address(0x3);

        vm.prank(user1);
        vault.borrowFromPortfolio(300e6);
        vm.prank(user2);
        vault.borrowFromPortfolio(200e6);

        // 500/1000 = 50% utilization
        assertEq(vault.getUtilizationPercent(), 5000, "Initial utilization should be 50%");

        // Only user1 deposits rewards
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Vest and settle user1 only
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        uint256 util = vault.getUtilizationPercent();
        // Effective debt should be less than 500 but more than 200 (user2 still owes 200)
        assertLt(util, 5000, "Utilization should drop below 50%");
        assertGt(util, 0, "Utilization should be > 0 since user2 still has debt");
    }

    /// @notice Fuzz test: utilization should never exceed what raw totalLoanedAssets
    ///         would produce, since effective debt <= raw debt.
    function testFuzz_utilizationNeverExceedsRawLoanedRatio(uint256 borrowAmt, uint256 rewardAmt) public {
        borrowAmt = bound(borrowAmt, 1e6, 790e6);
        rewardAmt = bound(rewardAmt, 1e6, 500e6);

        vm.prank(user1);
        vault.borrowFromPortfolio(borrowAmt);

        uint256 utilBeforeRewards = vault.getUtilizationPercent();

        vm.startPrank(user1);
        deal(address(usdc), user1, rewardAmt);
        usdc.approve(address(vault), rewardAmt);
        vault.depositRewards(rewardAmt);
        vm.stopPrank();

        // Warp and settle
        vm.warp(EPOCH_3);
        vault.settleRewards(user1);

        uint256 utilAfterRewards = vault.getUtilizationPercent();
        assertLe(utilAfterRewards, utilBeforeRewards,
            "Utilization after rewards should never exceed utilization before rewards");
        assertLe(utilAfterRewards, 10000, "Utilization should never exceed 100%");
    }

    // ============================================================================
    // Bundle 1: EIP-4626 Preview Compliance Gates
    // ----------------------------------------------------------------------------
    // EIP-4626 mandates that previewWithdraw / previewRedeem MUST NOT revert.
    // The current `DynamicFeesVault` implementation requires `assets <= liquid`
    // and reverts with "Insufficient liquidity" (see DynamicFeesVault.sol:898
    // and :909) when the requested withdraw exceeds vault cash on hand.
    //
    // The two tests below ASSERT THE COMPLIANT BEHAVIOR — they will fail under
    // `forge test` today with the "Insufficient liquidity" revert. The failure
    // is the deliverable: it surfaces the spec deviation as a red signal in CI
    // until the require lines are removed. Once the fix lands (return the
    // unconstrained post-fee-accrual quote, matching the formulas already used
    // by `previewDeposit` / `previewMint`), these tests pass and become
    // regression guards.
    // ============================================================================

    /// @notice EIP-4626 compliance gate — currently FAILS, by design.
    /// @dev EIP-4626 §previewWithdraw: "MUST NOT revert." This test asserts the
    ///      compliant behavior: a quote MUST be returned even when assets
    ///      exceed liquid cash. Today the call reverts with
    ///      "Insufficient liquidity" — that revert IS the violation signal.
    ///      Once `require(assets <= liquid, "Insufficient liquidity")` is
    ///      removed from `DynamicFeesVault.sol:898`, this test passes.
    function test_PreviewWithdraw_DoesNotRevertWhenInsufficientLiquidity_EIP4626Compliance() public {
        // Drain liquid cash by borrowing — totalAssets stays at 1000e6 but
        // vault USDC balance drops to 210e6.
        vm.prank(user1);
        vault.borrowFromPortfolio(790e6);

        uint256 liquid = usdc.balanceOf(address(vault));
        assertEq(liquid, 210e6, "vault should hold 210e6 cash after 790e6 borrow");
        assertGt(vault.totalAssets(), liquid, "totalAssets should exceed liquid (loaned out)");

        // The user holds 100% of supply, so their share-equivalent assets are
        // ~totalAssets, well above `liquid`. EIP-4626 says this MUST be
        // quotable as a view.
        uint256 ownedAssets = vault.convertToAssets(vault.balanceOf(address(this)));
        assertGt(ownedAssets, liquid, "owner share-equivalent assets exceed liquid (precondition)");

        // EIP-4626 compliance: this call MUST NOT revert. Today it does.
        // The revert ("Insufficient liquidity") surfaced by forge is the
        // CI signal that DynamicFeesVault.previewWithdraw violates EIP-4626.
        uint256 quotedShares = vault.previewWithdraw(ownedAssets);

        // Once the require is removed, the unconstrained quote (post-fee-
        // accrual share math, mirroring previewDeposit/previewMint) is what
        // we expect. As an independently-derived spec reference we use
        // `convertToShares(assets)`. The two differ only by the pending fee
        // share component folded into the preview helpers; in this test
        // (single share holder, no time-driven lender premium accrual yet)
        // they are equal.
        uint256 expectedShares = vault.convertToShares(ownedAssets);
        assertEq(
            quotedShares,
            expectedShares,
            "EIP-4626 previewWithdraw must return unconstrained share quote when liquidity is insufficient"
        );
        assertGt(quotedShares, 0, "EIP-4626 previewWithdraw must return non-zero share quote");
    }

    /// @notice EIP-4626 compliance gate — currently FAILS, by design.
    /// @dev EIP-4626 §previewRedeem: "MUST NOT revert." Same root cause as
    ///      the previewWithdraw test above. Failing call site:
    ///      `DynamicFeesVault.sol:909`. Removing that require makes this pass.
    function test_PreviewRedeem_DoesNotRevertWhenInsufficientLiquidity_EIP4626Compliance() public {
        vm.prank(user1);
        vault.borrowFromPortfolio(790e6);

        uint256 ownedShares = vault.balanceOf(address(this));
        uint256 ownedAssets = vault.convertToAssets(ownedShares);
        uint256 liquid = usdc.balanceOf(address(vault));
        assertGt(ownedAssets, liquid, "owner share-equivalent assets exceed liquid (precondition)");

        // EIP-4626 compliance: this call MUST NOT revert. Today it reverts
        // with "Insufficient liquidity" — that revert IS the CI signal.
        uint256 quotedAssets = vault.previewRedeem(ownedShares);

        // Spec reference: `convertToAssets(shares)` is the unconstrained quote
        // semantics required by EIP-4626. Equality holds in this single-holder
        // pre-accrual setup; the implementation is free to use the post-fee-
        // accrual snapshot from `_accrueFeeView` (matching previewMint), which
        // produces an identical value here.
        uint256 expectedAssets = vault.convertToAssets(ownedShares);
        assertEq(
            quotedAssets,
            expectedAssets,
            "EIP-4626 previewRedeem must return unconstrained asset quote when liquidity is insufficient"
        );
        assertGt(quotedAssets, 0, "EIP-4626 previewRedeem must return non-zero asset quote");
    }

    /// @notice Positive control: previewWithdraw at maxWithdraw boundary does not revert.
    /// @dev maxWithdraw clamps to liquid, so this is always quotable today. The
    ///      same call must continue to be non-reverting after the EIP-4626 fix.
    function test_PreviewWithdraw_AtMaxWithdraw_DoesNotRevert() public {
        // Roll a block so the same-block flash-loan guard is satisfied.
        vm.roll(block.number + 1);

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 maxAssets = vault.maxWithdraw(address(this));
        assertGt(maxAssets, 0, "maxWithdraw should be positive");

        // Should not revert — assets <= liquid by construction of maxWithdraw.
        uint256 shares = vault.previewWithdraw(maxAssets);
        assertGt(shares, 0, "preview should return non-zero shares");
    }

    /// @notice Positive control: previewRedeem at maxRedeem boundary does not revert.
    function test_PreviewRedeem_AtMaxRedeem_DoesNotRevert() public {
        vm.roll(block.number + 1);

        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 maxShares = vault.maxRedeem(address(this));
        assertGt(maxShares, 0, "maxRedeem should be positive");

        uint256 assets = vault.previewRedeem(maxShares);
        assertGt(assets, 0, "preview should return non-zero assets");
    }

    // ============================================================================
    // Bundle 4: Current-Epoch Lender-Premium Vesting Regression Test
    // ----------------------------------------------------------------------------
    // Asserts the single-bucket, current-epoch vesting model in
    // `_processGlobalVesting`. When premium is extracted at time T in epoch N,
    // it routes to `vestingEpochPremium` with `vestingEpochStart =
    // max(existing, epochStart(now))` — vesting linearly across the REMAINDER
    // of the current epoch, fully realized into totalAssets() by epochStart(N+1).
    //
    // The prior staging design (currentEpochPremium → vestingEpochPremium one
    // epoch later → vest over a full epoch) imposed a 2-epoch settlement-to-
    // realization lag and was removed. The `currentEpochPremium` /
    // `currentEpochStart` storage slots are retained for ERC-7201 layout
    // compatibility but are never written.
    //
    // STALE-NAV FIX: previously, a lender depositing at time T inside an epoch
    // where premium had already been extracted captured the already-vested
    // fraction as a retroactive boost (a value transfer from existing LPs).
    // That was the "ACCEPTED TRADE-OFF" of the prior stale-NAV preview path.
    // It was fixed by simulating _processGlobalVesting inside totalAssets()
    // and the preview functions; the share price now reflects realized vesting
    // at view time. `test_LateSettlement_DepositorCapturesElapsedFraction`
    // below is now the regression gate asserting the boost is gone.
    //
    // The same-block flash-loan guard (`lastDepositBlock`) blocks
    // deposit-then-withdraw within one block; cross-block exploitation of the
    // OLD stale-NAV bug is no longer possible.
    // ============================================================================

    /// @notice REGRESSION GATE — premium vests linearly within the deposit
    ///         epoch under the single-bucket model.
    /// @dev Rewards deposited in epoch N (= EPOCH_2). Stream runs to EPOCH_3
    ///      (= start of N+1). Stream finalization happens at EPOCH_3 via the
    ///      late path (epochEnded == true); under the new model the premium
    ///      routes to vestingEpochPremium with vestingEpochStart = EPOCH_3
    ///      (max of endingEpoch and epochStart(now)). Vesting therefore runs
    ///      across EPOCH_3..EPOCH_4 and is fully realized by start of EPOCH_4.
    ///
    ///      EXPECTED BEHAVIOR (single-bucket, current-epoch vest):
    ///        - At EPOCH_3 (sync): vestingEpochPremium = 20e6,
    ///          vestingEpochStart = EPOCH_3, elapsed = 0, unlocked = 0.
    ///        - Mid epoch N+1 (EPOCH_3 + WEEK/2): linear unlock at ~50% → ~10e6;
    ///          totalAssets() reflects ~10e6 of the 20e6 premium.
    ///        - Just before EPOCH_4 (EPOCH_4 - 1): unlocked ~100% → ~20e6.
    ///        - At EPOCH_4 (post-sweep sync): unlocked-this-epoch view returns
    ///          0 because the vest epoch has passed; vestingEpochPremium and
    ///          vestingEpochStart are zeroed by the inline sweep; totalAssets()
    ///          reflects the full 20e6 lender premium gain.
    ///
    ///      NOTE on test name: this is the same regression gate previously
    ///      named `test_FirstRewardEpoch_VaultEarnsZero_SecondEpochEarnsFullPremium`
    ///      — the prior name described the staged 2-bucket model where the
    ///      vault earned 0 in the deposit epoch and the full premium in the
    ///      following epoch. Under the single-bucket model, premium starts
    ///      vesting in the SAME epoch the stream finalizes, so the lag is
    ///      one epoch (settlement → realization), not two.
    function test_RewardDeposit_PremiumVestsLinearlyInDepositEpoch_FullyRealizedNextEpoch() public {
        // Pin a known, predictable fee curve. 20% lender / 80% borrower.
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        // Borrower has debt so depositRewards passes the "No debt to repay" gate.
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        uint256 totalAssetsBaseline = vault.totalAssets();

        // Step 1: Deposit rewards in epoch N (= EPOCH_2). Stream activeEpochEnd = EPOCH_3.
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Step 2: Warp to start of epoch N+1 (= EPOCH_3) — exactly the
        // activeEpochEnd boundary. Sync triggers the late path in
        // _processGlobalVesting (epochEnded = true since block.timestamp >=
        // activeEpochEnd), routing premium directly into vestingEpochPremium
        // with vestingEpochStart = max(EPOCH_3, EPOCH_3) = EPOCH_3.
        vm.warp(EPOCH_3);
        vault.sync();

        // At the exact boundary, elapsed = 0, so unlocked = 0. The premium IS
        // already in the vesting slot, just hasn't started releasing yet.
        uint256 unlockedAtEpochNEnd = vault.lenderPremiumUnlockedThisEpoch();
        assertEq(
            unlockedAtEpochNEnd,
            0,
            "EPOCH_3 boundary: vesting just started, elapsed = 0"
        );

        // totalAssets unchanged at the boundary — premium is fully unvested
        // (deduction == premium), so balance gain is exactly offset.
        assertApproxEqAbs(
            vault.totalAssets(),
            totalAssetsBaseline,
            1e6,
            "totalAssets unchanged at EPOCH_3 boundary (premium fully unvested)"
        );

        // Step 3: Halfway through the vest epoch (EPOCH_3 + WEEK/2). Vesting
        // has been running for half a week from vestingEpochStart = EPOCH_3.
        // Linear unlock at ~50% — ~10e6 of the ~20e6 premium.
        //
        // (Pre-rewrite: under the staged 2-bucket model this read 0 — premium
        //  sat in currentEpochPremium until EPOCH_4 then vested across EPOCH_4.)
        uint256 midVestEpoch = EPOCH_3 + WEEK / 2;
        vm.warp(midVestEpoch);
        vault.sync();

        uint256 unlockedMidVest = vault.lenderPremiumUnlockedThisEpoch();
        assertApproxEqAbs(
            unlockedMidVest,
            10e6,
            1e6,
            "Mid vest epoch (EPOCH_3 + WEEK/2): ~50% of lender premium unlocked"
        );

        // totalAssets reflects half-vested premium: deduction shrinks from
        // full 20e6 to ~10e6, so totalAssets gain over baseline ~10e6.
        assertApproxEqAbs(
            vault.totalAssets() - totalAssetsBaseline,
            10e6,
            1e6,
            "Mid vest epoch: totalAssets reflects ~half-vested premium"
        );

        // Step 4: Just BEFORE the vest epoch boundary (EPOCH_4 - 1). Vesting
        // epoch (EPOCH_3..EPOCH_4) still active, elapsed ≈ WEEK − 1 →
        // unlocked ~100% (~20e6). No sync here — the unlocked-this-epoch view
        // must report the full amount while the vesting slot is still set.
        vm.warp(EPOCH_4 - 1);
        uint256 unlockedJustBeforeEnd = vault.lenderPremiumUnlockedThisEpoch();
        assertApproxEqAbs(
            unlockedJustBeforeEnd,
            20e6,
            1e6,
            "Just before EPOCH_4: full ~20e6 lender premium vested (slot still set)"
        );

        // Step 5: AT the EPOCH_4 boundary. The unlocked-this-epoch view returns
        // 0 because nowEpoch (EPOCH_4) > vestingEpochStart (EPOCH_3): the vest
        // epoch has passed and the premium is fully realized into totalAssets.
        // sync() then runs the inline stale-vesting sweep, zeroing
        // vestingEpochPremium / vestingEpochStart.
        vm.warp(EPOCH_4);

        // BEFORE sync — view already returns 0 (epoch comparison short-circuit).
        assertEq(
            vault.lenderPremiumUnlockedThisEpoch(),
            0,
            "EPOCH_4: unlocked view returns 0 once vest epoch has passed"
        );
        assertEq(
            vault.getUnvestedLenderPremium(),
            0,
            "EPOCH_4: unvested view returns 0 once vest epoch has passed"
        );

        vault.sync();

        // AFTER sync — sweep ran. The view still returns 0; the storage slots
        // are cleared (we observe this indirectly via getUnvestedLenderPremium
        // remaining 0, since a non-zero vestingEpochPremium / vestingEpochStart
        // would also produce non-zero readings if elapsed < WEEK).
        assertEq(
            vault.lenderPremiumUnlockedThisEpoch(),
            0,
            "EPOCH_4 post-sync: unlocked view still 0 after sweep"
        );
        assertEq(
            vault.getUnvestedLenderPremium(),
            0,
            "EPOCH_4 post-sync: unvested view still 0 after sweep (slots zeroed)"
        );

        // totalAssets reflects the full lender premium delta vs baseline.
        assertApproxEqAbs(
            vault.totalAssets() - totalAssetsBaseline,
            20e6,
            1e6,
            "EPOCH_4: totalAssets gain equals full lender premium (~20e6)"
        );
    }

    // ============================================================================
    // Bundle 4: Late-settlement depositor-captures-elapsed-fraction regression test
    // ----------------------------------------------------------------------------
    // Verifies the ACCEPTED retroactive-boost behavior under the single-bucket
    // current-epoch vesting model. When premium routes to vestingEpochPremium
    // with vestStart = max(existing, epochStart(now)), a lender depositing at
    // time T inside the vest epoch captures `(WEEK − elapsed_at_deposit) /
    // WEEK` of the premium they did not fund (the unvested-at-deposit portion).
    //
    // The depositor's gain over the rest of the epoch is bounded by their
    // share fraction of total supply: gain ≈ share_fraction × (1 − elapsed/WEEK)
    // × lenderPremium. For a balanced deposit (lender owns ~half of supply),
    // gain ≈ 0.5 × 0.75 × 20e6 = 7.5e6 in this configuration.
    //
    // This test intentionally REPLACES the prior `NoRetroactiveBoost` test
    // (which asserted no boost). Per the contract-level comment block in
    // _processGlobalVesting, the boost is an accepted product trade-off: the
    // prior staging design imposed a 1-epoch lag specifically to prevent it,
    // but that lag harmed passive lenders. The same-block flash-loan guard
    // (`lastDepositBlock`) blocks deposit-then-withdraw within one block;
    // cross-block exploitation remains possible and is accepted (rewards
    // source = veNFT yield, not flash-loanable).
    // ============================================================================

    /// @notice REGRESSION GATE — captures the accepted retroactive boost.
    /// @dev Deposit rewards in epoch N (= EPOCH_2). Skip deep into the future
    ///      (EPOCH_7) WITHOUT calling sync, so the stream is still pending.
    ///      A new lender deposits at EPOCH_7 + WEEK/4. The deposit runs
    ///      _processGlobalVesting internally and routes the stale premium to
    ///      vestingEpochPremium with vestStart = max(EPOCH_3, EPOCH_7) = EPOCH_7,
    ///      but the simulated totalAssets() the depositor's share price is
    ///      computed against ALSO reflects that same realization. So the
    ///      depositor pays a share price that already prices in the 25%
    ///      already-vested portion: their cost basis equals their deposit
    ///      (within ERC4626 floor-rounding).
    ///
    ///      Over the remaining 3*WEEK/4 of the vest epoch the unvested 75%
    ///      vests into totalAssets(). The new lender's value
    ///      (convertToAssets of their shares) rises only with the unvested
    ///      portion they did fund. The retroactive boost previously asserted
    ///      here was the symptom of stale-NAV previews and is gone.
    function test_LateSettlement_DepositorCapturesElapsedFraction() public {
        // Pin 20% lender / 80% borrower split.
        FlatFeeCalculator flatFee = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(flatFee));

        // Borrower with debt — depositRewards requires non-zero outstanding debt.
        vm.prank(user1);
        vault.borrowFromPortfolio(500e6);

        // Deposit rewards in epoch N (= EPOCH_2). Stream activeEpochEnd = EPOCH_3.
        vm.startPrank(user1);
        deal(address(usdc), user1, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Skip deep into the future — to start of epoch N+5 (= 7*WEEK from t=0).
        // No sync calls in between: stream finalizes lazily on next state-changing call.
        uint256 EPOCH_7 = 7 * WEEK;
        vm.warp(EPOCH_7);

        // Quarter into the late-settle epoch (= vest epoch under the new model).
        uint256 lateLenderTime = EPOCH_7 + WEEK / 4;
        vm.warp(lateLenderTime);

        // Set up a fresh late lender with a deposit comparable to the existing
        // supply so their share fraction is meaningful (~1/2 of supply).
        address lateLender = address(0xBAA1);
        uint256 lateDepositAssets = 1000e6; // matches initial setUp deposit
        deal(address(usdc), lateLender, lateDepositAssets);
        vm.startPrank(lateLender);
        usdc.approve(address(vault), lateDepositAssets);

        // The deposit itself triggers _processGlobalVesting → late path:
        //   epochEnded = true (block.timestamp >> activeEpochEnd = EPOCH_3)
        //   endingEpoch = EPOCH_3
        //   nowEpoch = epochStart(EPOCH_7 + WEEK/4) = EPOCH_7
        //   lateVestStart = max(EPOCH_3, EPOCH_7) = EPOCH_7
        // Premium goes to vestingEpochPremium with vestingEpochStart = EPOCH_7.
        // elapsed_at_deposit = WEEK/4 → 25% already mathematically vested into
        // totalAssets() at the moment shares are minted, so the lender pays a
        // share price reflecting the 25% already vested.
        uint256 lateLenderShares = vault.deposit(lateDepositAssets, lateLender);
        vm.stopPrank();

        // Snapshot the lender's value RIGHT AFTER deposit. With the
        // stale-NAV fix, totalAssets() simulates vesting in views, so the
        // share price the depositor pays already reflects the 25% already
        // vested. Cost basis equals deposit (within 1 wei floor-rounding).
        uint256 valueAtDeposit = vault.convertToAssets(lateLenderShares);

        // Post-fix: depositor does NOT capture the already-vested fraction.
        // Cost basis is equal to their deposit (within ERC4626 floor rounding
        // of 1 wei). This is the regression gate for the stale-NAV fix.
        assertLe(valueAtDeposit, lateDepositAssets, "Cost basis does not exceed deposit (no retroactive boost)");
        assertGe(
            valueAtDeposit,
            lateDepositAssets - 1,
            "Cost basis within ERC4626 floor-rounding of deposit"
        );

        // Warp to end of vest epoch (EPOCH_8 = start of N+6, one full WEEK
        // after vestingEpochStart=EPOCH_7). The remaining 75% of premium
        // bleeds into totalAssets across this interval, and the inline sweep
        // will run on the next state-changing call.
        uint256 EPOCH_8 = 8 * WEEK;
        vm.warp(EPOCH_8);

        uint256 valueAfterFullVest = vault.convertToAssets(lateLenderShares);

        // The lender captures the unvested-at-deposit fraction proportional
        // to their share of supply. lenderPremium = 20e6, unvested-at-deposit
        // fraction = 1 − WEEK/4/WEEK = 75% → 15e6 of premium vests AFTER
        // The depositor's share count was sized against a NAV that already
        // reflected the 25% already-vested portion, so they share only in the
        // remaining 75% (15e6) that vests after their deposit.
        //
        // Expected gain = share_fraction * unvested-at-deposit, where
        // share_fraction = lateLenderShares / supplyAfterDeposit.
        uint256 gain = valueAfterFullVest - valueAtDeposit;
        uint256 lenderPremium = 20e6;
        uint256 unvestedAtDeposit = (lenderPremium * 3) / 4; // 75% × 20e6 = 15e6

        assertGt(
            gain,
            1e6,
            "Late lender captures their share of the unvested-at-deposit portion"
        );
        assertLe(
            gain,
            unvestedAtDeposit,
            "Late lender gain bounded above by unvested-at-deposit premium fraction"
        );

        uint256 supplyAfterDeposit = vault.totalSupply();
        uint256 expectedGain = (lateLenderShares * unvestedAtDeposit) / supplyAfterDeposit;

        // 5% of premium tolerance (= 1e6) for share-conversion and
        // borrower-credit interaction noise.
        uint256 tolerance = lenderPremium / 20;
        assertApproxEqAbs(
            gain,
            expectedGain,
            tolerance,
            "Late lender gain ~= share_fraction * unvested-at-deposit * premium (5% tol)"
        );
    }

    // ============================================================================
    // pendingFeeShares() vs live _accrueFee() exact-equality cross-check
    // ============================================================================
    //
    // Bundle 3 only validated `pendingFeeShares()` for the `feeBps == 0` case
    // (where it must trivially be zero). The view path (`_accrueFeeView`) and
    // the live path (`_accrueFee`) share their math today, but evolved
    // separately and could drift; this test pins them together by asserting
    // bit-equality on a non-zero realized-interest path.
    //
    // The default `setUp` deploys a vault with `feeBps == 0` (no fee), so we
    // deploy a FRESH vault inside this test with `feeBps = 1000` (10%) and a
    // dedicated `feeRecipient` to keep the assertions independent of other tests.
    //
    // Stream chain mirrors the canonical scenario documented in
    // DynamicFeesVaultTreasury.t.sol: three 100e6 reward streams across
    // EPOCH_2 / EPOCH_3 / EPOCH_4 with a flat 20% lender ratio. The first
    // stream's lender premium becomes fully realized into `totalAssets()` only
    // at EPOCH_5 (the second reward epoch), per the documented first-epoch
    // zero-yield quirk. We sync at EPOCH_5 to observe the fee.
    // ============================================================================

    /// @dev Re-declared so we can `vm.expectEmit`/decode it from `getRecordedLogs()`.
    event FeeAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares);

    function test_PendingFeeShares_MatchesActualMint_WhenInterestAccrues() public {
        // ──────────────────────────────────────────────────────────────────
        // 1. Deploy a fresh, isolated vault with feeBps = 1000 (10%) and a
        //    non-zero feeRecipient. We use the same MockUSDC + factory as the
        //    suite-level setUp but stand up a brand-new proxy so the snapshot
        //    state is clean.
        // ──────────────────────────────────────────────────────────────────
        address feeRecipient = address(0xFEE);
        address borrower = address(0xB0BB1);
        address lp = address(0x71D); // separate LP to seed liquidity

        DynamicFeesVault freshImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory),
            feeRecipient,
            uint256(1000)          // feeBps = 10%
        );
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), initData);
        DynamicFeesVault freshVault = DynamicFeesVault(address(freshProxy));

        // Pin the fee curve to a flat 20% lender ratio so the realized interest
        // is deterministic (matches the canonical scenario in the Treasury test).
        FlatFeeCalculator flat = new FlatFeeCalculator(2000);
        // initialize() sets msg.sender (this contract) as owner; setFeeCalculator
        // is onlyOwner so we just call directly.
        freshVault.setFeeCalculator(address(flat));

        // ──────────────────────────────────────────────────────────────────
        // 2. Seed liquidity, open debt, and start the reward stream chain.
        //    setUp warped to EPOCH_2 already; we follow the canonical 3-stream
        //    timeline (EPOCH_2 → EPOCH_3 → EPOCH_4) and sync at EPOCH_5.
        // ──────────────────────────────────────────────────────────────────
        assertEq(block.timestamp, EPOCH_2, "setUp must place us at EPOCH_2");

        usdc.mint(lp, 10_000e6);
        vm.startPrank(lp);
        usdc.approve(address(freshVault), 10_000e6);
        freshVault.deposit(10_000e6, lp);
        vm.stopPrank();

        // 30% utilization
        vm.prank(borrower);
        freshVault.borrowFromPortfolio(3_000e6);

        // Stream #1 at EPOCH_2
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(freshVault), 100e6);
        freshVault.depositRewards(100e6);
        vm.stopPrank();

        // Stream #2 at EPOCH_3
        vm.warp(EPOCH_3);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(freshVault), 100e6);
        freshVault.depositRewards(100e6);
        vm.stopPrank();

        // Stream #3 at EPOCH_4
        vm.warp(EPOCH_4);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(freshVault), 100e6);
        freshVault.depositRewards(100e6);
        vm.stopPrank();

        // ──────────────────────────────────────────────────────────────────
        // 3. Warp into the SECOND reward epoch — first realized interest hits
        //    totalAssets() at EPOCH_5 thanks to the rebalance-checkpoint quirk
        //    documented at the top of the file (and mirrored in MEMORY.md).
        // ──────────────────────────────────────────────────────────────────
        vm.warp(EPOCH_5);

        // ──────────────────────────────────────────────────────────────────
        // 4. Snapshot the view: this is what _accrueFee() MUST mint exactly.
        // ──────────────────────────────────────────────────────────────────
        uint256 expectedFeeShares = freshVault.pendingFeeShares();
        assertGt(expectedFeeShares, 0, "test setup did not produce realized interest");

        uint256 recipientBalanceBefore = freshVault.balanceOf(feeRecipient);

        // ──────────────────────────────────────────────────────────────────
        // 5+6. Capture logs and trigger _accrueFee via sync(). sync() runs
        //      _processGlobalVesting() which ends with _accrueFee().
        // ──────────────────────────────────────────────────────────────────
        vm.recordLogs();
        freshVault.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // ──────────────────────────────────────────────────────────────────
        // 7. Pull feeShares out of the FeeAccrued event AND off the recipient
        //    balance delta.
        // ──────────────────────────────────────────────────────────────────
        bytes32 feeAccruedTopic = keccak256("FeeAccrued(address,uint256,uint256)");
        bytes32 expectedRecipientTopic = bytes32(uint256(uint160(feeRecipient)));

        bool found = false;
        uint256 eventFeeAssets;
        uint256 eventFeeShares;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(freshVault) &&
                logs[i].topics.length == 2 &&
                logs[i].topics[0] == feeAccruedTopic &&
                logs[i].topics[1] == expectedRecipientTopic
            ) {
                (eventFeeAssets, eventFeeShares) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeAccrued event should have been emitted");

        uint256 recipientBalanceAfter = freshVault.balanceOf(feeRecipient);
        uint256 balanceDelta = recipientBalanceAfter - recipientBalanceBefore;

        // ──────────────────────────────────────────────────────────────────
        // 8. The three values MUST be bit-equal — the live and view paths share
        //    the same math, and any divergence is a real-money discrepancy in
        //    fee preview vs settlement.
        // ──────────────────────────────────────────────────────────────────
        assertEq(eventFeeShares, expectedFeeShares, "view pendingFeeShares != event feeShares (drift)");
        assertEq(balanceDelta, expectedFeeShares, "view pendingFeeShares != recipient balance delta (drift)");
        assertEq(balanceDelta, eventFeeShares, "event feeShares != recipient balance delta (drift)");

        // Sanity: feeAssets in the event = feeBps * realized interest / 10000.
        // We don't assert exact value here (covered elsewhere) — just that the
        // log was non-trivial when feeShares > 0.
        assertGt(eventFeeAssets, 0, "feeAssets in event must be > 0 when feeShares > 0");

        // ──────────────────────────────────────────────────────────────────
        // 9. Snapshot must be bumped: a second pendingFeeShares() right after
        //    sync() must return 0 (no new realized interest since the snapshot
        //    we just refreshed).
        // ──────────────────────────────────────────────────────────────────
        assertEq(freshVault.pendingFeeShares(), 0, "snapshot not bumped - pending should be 0 immediately after accrual");
    }
}

