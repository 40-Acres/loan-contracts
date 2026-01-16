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
        vault.borrow(800e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 800e6, "Utilization should be less than 80%");
    }

    function testBorrowAndRepay() public {
        vm.startPrank(user1);
        vault.borrow(800e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 800e6, "Utilization should be less than 80%");

        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.repay(800e6);
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
        vault.borrow(800e6);
        vm.stopPrank();

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertLt(utilizationPercent, 800e6, "Utilization should be less than 80%");
        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.repay(800e6);
        vm.stopPrank();

        uint256 utilizationPercent2 = vault.getUtilizationPercent();
        assertEq(utilizationPercent2, 0, "Utilization should be 0% 3");
        
        vm.startPrank(user1);
        deal(address(usdc), user1, 800e6);
        usdc.approve(address(vault), 800e6);
        vault.deposit(800e6, user1);
        vm.stopPrank();

        uint256 utilizationPercent3 = vault.getUtilizationPercent();
        assertLt(utilizationPercent3, 800e6, "Utilization should be less than 80%");
        
        vm.startPrank(user1);
        vault.withdraw(800e6, user1, user1);
        vm.stopPrank();

        uint256 utilizationPercent4 = vault.getUtilizationPercent();
        assertEq(utilizationPercent4, 0, "Utilization should be 0% 2");
    }

    function testBorrowAndRepayWithRewards() public {
        vm.startPrank(user1);
        vault.borrow(400e6);
        vm.stopPrank();
        uint256 timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        uint256 utilizationPercent = vault.getUtilizationPercent();
        assertEq(utilizationPercent, 4000, "Utilization should be 40%");


        uint256 totalLoanedAssets = vault.totalLoanedAssets();
        assertEq(totalLoanedAssets, 400e6, "Total loaned assets should be 400e6");

        uint256 rate = vault.debtToken().getVaultRatioBps(utilizationPercent);
        assertEq(rate, 2000, "Ratio should be 20%");

        // warp to beginning of this epoch
        vm.warp(timestamp);

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
        assertEq(vault.totalLoanedAssets(), 50e6, "Total loaned assets should be 40e6");


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
}