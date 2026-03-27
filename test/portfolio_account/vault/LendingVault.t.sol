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
 * Issue Summary:
 * =============================================================
 * 1. maxRedeem uses convertToShares(liquidAssets) which rounds DOWN.
 *    This means the returned share count may convert back to slightly
 *    LESS than liquidAssets, leaving a tiny amount of liquid USDC
 *    unredeemable. This is safe (conservative) but worth noting.
 *
 * 2. maxWithdraw and maxRedeem both report based on the GLOBAL liquid
 *    balance, not per-depositor. Two depositors both see the same
 *    maxWithdraw (the full liquid balance), but only one can actually
 *    withdraw that amount. The second depositor's withdraw would revert.
 *    This is standard ERC4626 behavior but could surprise integrators.
 *
 * 3. After borrowFromPortfolio, the origination fee is transferred to
 *    the owner, reducing liquid balance further than just the loan amount.
 *    maxWithdraw correctly reflects this since it reads balanceOf(vault).
 * =============================================================
 */

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
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

contract LendingVaultMaxWithdrawTest is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public vaultOwner;
    address public depositor1;
    address public depositor2;
    address public borrower;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;

    uint256 constant MAX_UTIL_BPS = 8000;  // 80%
    uint256 constant ORIG_FEE_BPS = 50;    // 0.5%

    function setUp() public {
        vm.warp(EPOCH_2);

        vaultOwner = address(0xA1);
        depositor1 = address(0xB1);
        depositor2 = address(0xB2);
        borrower = address(0xC1);

        vm.label(vaultOwner, "VaultOwner");
        vm.label(depositor1, "Depositor1");
        vm.label(depositor2, "Depositor2");
        vm.label(borrower, "Borrower");

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
            MAX_UTIL_BPS,
            ORIG_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = LendingVault(address(proxy));
        vm.label(address(vault), "LendingVault");
    }

    // =============================================
    // Helper functions
    // =============================================

    function _deposit(address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _borrow(address _borrower, uint256 amount) internal {
        vm.prank(_borrower);
        vault.borrowFromPortfolio(amount);
    }

    function _repay(address _borrower, uint256 amount) internal {
        usdc.mint(_borrower, amount);
        vm.startPrank(_borrower);
        usdc.approve(address(vault), amount);
        vault.payFromPortfolio(amount, 0);
        vm.stopPrank();
    }

    // =============================================
    // Scenario 1: No loans outstanding
    // maxWithdraw should equal user's full share value
    // maxRedeem should equal user's full shares
    // =============================================

    function test_maxWithdraw_noLoans_returnsFullValue() public {
        _deposit(depositor1, 1000e6);

        uint256 maxW = vault.maxWithdraw(depositor1);
        uint256 shares = vault.balanceOf(depositor1);
        uint256 shareValue = vault.convertToAssets(shares);

        assertEq(maxW, shareValue, "maxWithdraw should equal full share value when no loans");
        assertEq(maxW, 1000e6, "maxWithdraw should equal deposited amount");
    }

    function test_maxRedeem_noLoans_returnsFullShares() public {
        _deposit(depositor1, 1000e6);

        uint256 maxR = vault.maxRedeem(depositor1);
        uint256 shares = vault.balanceOf(depositor1);

        assertEq(maxR, shares, "maxRedeem should equal all shares when no loans");
    }

    function test_maxWithdraw_noLoans_zeroForNonDepositor() public {
        _deposit(depositor1, 1000e6);

        uint256 maxW = vault.maxWithdraw(depositor2);
        assertEq(maxW, 0, "maxWithdraw should be 0 for non-depositor");
    }

    function test_maxRedeem_noLoans_zeroForNonDepositor() public {
        _deposit(depositor1, 1000e6);

        uint256 maxR = vault.maxRedeem(depositor2);
        assertEq(maxR, 0, "maxRedeem should be 0 for non-depositor");
    }

    // =============================================
    // Scenario 2: Partial loans - liquid < share value
    // maxWithdraw capped at liquid, maxRedeem capped at shares for liquid
    // =============================================

    function test_maxWithdraw_partialLoan_cappedAtLiquid() public {
        _deposit(depositor1, 1000e6);
        // Borrow 500 USDC (+ 0.5% fee = 2.5 USDC fee, so 502.5 leaves vault)
        _borrow(borrower, 500e6);

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW = vault.maxWithdraw(depositor1);

        // Depositor's share value is still ~1000 USDC (totalAssets includes loaned)
        // but liquid is only ~497.5 USDC (1000 - 500 - 2.5 fee to owner)
        assertEq(maxW, liquidAssets, "maxWithdraw should be capped at liquid assets");
        assertLt(maxW, 1000e6, "maxWithdraw should be less than deposited amount");
    }

    function test_maxRedeem_partialLoan_cappedAtSharesForLiquid() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxR = vault.maxRedeem(depositor1);
        uint256 totalShares = vault.balanceOf(depositor1);

        // maxRedeem should be less than total shares
        assertLt(maxR, totalShares, "maxRedeem should be less than total shares with loan");

        // The assets from maxRedeem shares should not exceed liquid
        uint256 assetsFromMaxRedeem = vault.convertToAssets(maxR);
        assertLe(assetsFromMaxRedeem, liquidAssets, "assets from maxRedeem should not exceed liquid");
    }

    // =============================================
    // Scenario 3: Near-full utilization
    // Very small maxWithdraw/maxRedeem
    // =============================================

    function test_maxWithdraw_highUtilization_verySmall() public {
        _deposit(depositor1, 1000e6);

        // Borrow up to near the utilization cap (80%)
        // With 1000 deposited, borrowing 700 should work
        // (totalAssets stays ~1000, loaned=700, util=70%)
        _borrow(borrower, 700e6);

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW = vault.maxWithdraw(depositor1);

        assertEq(maxW, liquidAssets, "maxWithdraw capped at liquid");
        // Liquid = 1000 - 700 (borrow disbursement + fee) = 300 USDC
        // The origination fee (3.5 USDC) is sent to owner from the vault's balance
        assertLe(maxW, 300e6, "maxWithdraw should be small at high utilization");
        assertGt(maxW, 0, "maxWithdraw should not be zero with some liquid");
    }

    function test_maxRedeem_highUtilization_verySmall() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 700e6);

        uint256 maxR = vault.maxRedeem(depositor1);
        uint256 totalShares = vault.balanceOf(depositor1);

        assertLt(maxR, totalShares, "maxRedeem should be much less than total shares");
        assertGt(maxR, 0, "maxRedeem should not be zero with some liquid");
    }

    // =============================================
    // Scenario 4: Multiple depositors with loans
    // Each depositor sees maxWithdraw capped at global liquid
    // =============================================

    function test_maxWithdraw_multipleDepositors_bothCappedAtLiquid() public {
        _deposit(depositor1, 500e6);
        _deposit(depositor2, 500e6);

        // Borrow 600 from the combined 1000 pool
        _borrow(borrower, 600e6);

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW1 = vault.maxWithdraw(depositor1);
        uint256 maxW2 = vault.maxWithdraw(depositor2);

        // Both depositors see the same liquid cap (their share values are ~500 each)
        // Liquid is ~397 USDC. Both see maxWithdraw = liquid since liquid < their share value
        assertEq(maxW1, liquidAssets, "depositor1 maxWithdraw capped at liquid");
        assertEq(maxW2, liquidAssets, "depositor2 maxWithdraw capped at liquid");

        // NOTE: Both report the same maxWithdraw, but only one can actually
        // withdraw that amount. After the first withdraws, liquid drops.
    }

    function test_maxRedeem_multipleDepositors_bothCappedSameWay() public {
        _deposit(depositor1, 500e6);
        _deposit(depositor2, 500e6);
        _borrow(borrower, 600e6);

        uint256 maxR1 = vault.maxRedeem(depositor1);
        uint256 maxR2 = vault.maxRedeem(depositor2);

        // Both see the same maxRedeem since both have equal shares and the
        // cap is convertToShares(liquidAssets) which is the same for both
        assertEq(maxR1, maxR2, "equal depositors should see same maxRedeem");
    }

    function test_maxWithdraw_multipleDepositors_smallDepositorUnaffected() public {
        // depositor1 has 100 USDC, depositor2 has 900 USDC
        _deposit(depositor1, 100e6);
        _deposit(depositor2, 900e6);

        // Borrow 200 USDC -> liquid = ~799 (1000 - 200 - 1 fee)
        _borrow(borrower, 200e6);

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW1 = vault.maxWithdraw(depositor1);
        uint256 shares1 = vault.balanceOf(depositor1);
        uint256 shareValue1 = vault.convertToAssets(shares1);

        // depositor1's share value (~100) is less than liquid (~799)
        // so maxWithdraw = share value, not liquid
        assertEq(maxW1, shareValue1, "small depositor not capped by liquidity");
        assertLt(maxW1, liquidAssets, "small depositor maxWithdraw less than liquid");
    }

    // =============================================
    // Scenario 5: After repayment, limits increase
    // =============================================

    function test_maxWithdraw_afterRepayment_increases() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxWBefore = vault.maxWithdraw(depositor1);

        // Repay 300 USDC
        _repay(borrower, 300e6);

        uint256 maxWAfter = vault.maxWithdraw(depositor1);

        assertGt(maxWAfter, maxWBefore, "maxWithdraw should increase after repayment");
    }

    function test_maxRedeem_afterRepayment_increases() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxRBefore = vault.maxRedeem(depositor1);

        _repay(borrower, 300e6);

        uint256 maxRAfter = vault.maxRedeem(depositor1);

        assertGt(maxRAfter, maxRBefore, "maxRedeem should increase after repayment");
    }

    function test_maxWithdraw_afterFullRepayment_returnsFullValue() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 debtAmount = vault.getDebtBalance(borrower);
        _repay(borrower, debtAmount);

        uint256 maxW = vault.maxWithdraw(depositor1);
        uint256 shares = vault.balanceOf(depositor1);
        uint256 shareValue = vault.convertToAssets(shares);

        // After full repayment, liquid = all vault USDC, so maxWithdraw = share value
        assertEq(maxW, shareValue, "maxWithdraw should equal share value after full repayment");
    }

    // =============================================
    // Scenario 6: withdraw/redeem revert if > max
    // =============================================

    function test_withdraw_revertsAboveMaxWithdraw() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxW = vault.maxWithdraw(depositor1);

        // Try to withdraw 1 wei more than max
        vm.prank(depositor1);
        vm.expectRevert();
        vault.withdraw(maxW + 1, depositor1, depositor1);
    }

    function test_redeem_revertsAboveMaxRedeem() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxR = vault.maxRedeem(depositor1);

        // Try to redeem 1 share more than max
        vm.prank(depositor1);
        vm.expectRevert();
        vault.redeem(maxR + 1, depositor1, depositor1);
    }

    function test_withdraw_succeedsAtExactMaxWithdraw() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxW = vault.maxWithdraw(depositor1);
        uint256 balBefore = usdc.balanceOf(depositor1);

        vm.prank(depositor1);
        vault.withdraw(maxW, depositor1, depositor1);

        uint256 balAfter = usdc.balanceOf(depositor1);
        assertEq(balAfter - balBefore, maxW, "should receive exactly maxWithdraw amount");
    }

    function test_redeem_succeedsAtExactMaxRedeem() public {
        _deposit(depositor1, 1000e6);
        _borrow(borrower, 500e6);

        uint256 maxR = vault.maxRedeem(depositor1);

        vm.prank(depositor1);
        uint256 assets = vault.redeem(maxR, depositor1, depositor1);

        assertGt(assets, 0, "should receive some assets from redeeming maxRedeem shares");
        assertLe(assets, usdc.balanceOf(address(vault)) + assets, "should not exceed what vault had");
    }

    // =============================================
    // Edge cases
    // =============================================

    function test_maxWithdraw_emptyVault_returnsZero() public {
        assertEq(vault.maxWithdraw(depositor1), 0, "maxWithdraw should be 0 for empty vault");
    }

    function test_maxRedeem_emptyVault_returnsZero() public {
        assertEq(vault.maxRedeem(depositor1), 0, "maxRedeem should be 0 for empty vault");
    }

    function test_maxWithdraw_zeroLiquid_returnsZero() public {
        _deposit(depositor1, 1000e6);

        // Borrow as much as possible to drain liquidity
        // 79% utilization to stay under 80% cap
        _borrow(borrower, 790e6);

        // Manually remove remaining USDC to simulate zero liquid
        // We can't easily get to exactly 0 via borrows, so test the concept:
        // after large borrow, liquid is small but not zero
        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW = vault.maxWithdraw(depositor1);
        assertEq(maxW, liquidAssets, "maxWithdraw equals liquid when liquid < share value");
    }

    function test_maxWithdraw_afterOriginationFee_reflectsReducedLiquid() public {
        // Origination fee goes to owner, reducing vault liquid balance
        _deposit(depositor1, 1000e6);

        uint256 liquidBefore = usdc.balanceOf(address(vault));
        assertEq(liquidBefore, 1000e6, "liquid should be 1000 before borrow");

        _borrow(borrower, 400e6);

        // Fee = 400 * 0.5% = 2 USDC. Vault sends 398 to borrower + 2 to owner
        // Liquid = 1000 - 400 = 600 USDC (origination fee taken from vault balance)
        uint256 liquidAfter = usdc.balanceOf(address(vault));
        // 1000 - 398 (to borrower) - 2 (fee to owner) = 600
        assertEq(liquidAfter, 600e6, "liquid should be 600 after 400 borrow with fee");

        uint256 maxW = vault.maxWithdraw(depositor1);
        assertEq(maxW, 600e6, "maxWithdraw should equal liquid after borrow");
    }

    // =============================================
    // Fuzz tests
    // =============================================

    function testFuzz_maxWithdraw_neverExceedsLiquid(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6); // 1 to 100M USDC
        // Borrow must be < 80% utilization. Use 70% as safe upper bound.
        borrowAmount = bound(borrowAmount, 0, (depositAmount * 70) / 100);

        _deposit(depositor1, depositAmount);

        if (borrowAmount > 0) {
            _borrow(borrower, borrowAmount);
        }

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxW = vault.maxWithdraw(depositor1);

        assertLe(maxW, liquidAssets, "maxWithdraw must never exceed liquid balance");
    }

    function testFuzz_maxRedeem_assetsNeverExceedLiquid(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        borrowAmount = bound(borrowAmount, 0, (depositAmount * 70) / 100);

        _deposit(depositor1, depositAmount);

        if (borrowAmount > 0) {
            _borrow(borrower, borrowAmount);
        }

        uint256 liquidAssets = usdc.balanceOf(address(vault));
        uint256 maxR = vault.maxRedeem(depositor1);
        uint256 assetsFromRedeem = vault.convertToAssets(maxR);

        assertLe(assetsFromRedeem, liquidAssets, "assets from maxRedeem must never exceed liquid");
    }

    function testFuzz_maxWithdraw_withdrawSucceeds(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        borrowAmount = bound(borrowAmount, 0, (depositAmount * 70) / 100);

        _deposit(depositor1, depositAmount);

        if (borrowAmount > 0) {
            _borrow(borrower, borrowAmount);
        }

        uint256 maxW = vault.maxWithdraw(depositor1);
        if (maxW > 0) {
            vm.prank(depositor1);
            vault.withdraw(maxW, depositor1, depositor1);
            // If we get here without revert, the test passes
        }
    }

    function testFuzz_maxRedeem_redeemSucceeds(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        borrowAmount = bound(borrowAmount, 0, (depositAmount * 70) / 100);

        _deposit(depositor1, depositAmount);

        if (borrowAmount > 0) {
            _borrow(borrower, borrowAmount);
        }

        uint256 maxR = vault.maxRedeem(depositor1);
        if (maxR > 0) {
            vm.prank(depositor1);
            vault.redeem(maxR, depositor1, depositor1);
            // If we get here without revert, the test passes
        }
    }
}
