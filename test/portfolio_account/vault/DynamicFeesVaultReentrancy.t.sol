// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/* ===========================================================================
 * DynamicFeesVaultReentrancy -- verifies the (to-be-added) `nonReentrant`
 * guards on the vault money-movers.
 *
 * Currently only claimEscrow() and incentivize() carry nonReentrant. The
 * functions repay / depositRewards / borrowFromPortfolio / payFromPortfolio /
 * settleRewards all move the asset (directly or via _settleRewards ->
 * _transferOrEscrow) and are UNGUARDED today.
 *
 * Production asset is USDC (no transfer hook) so there is no live exploit;
 * these are defense-in-depth tests for a future callback-capable asset. We
 * simulate the callback asset with MockReentrantERC20: it re-enters a
 * configured target during transferFrom.
 *
 * Chosen seat: repay(). repay() pulls the asset via safeTransferFrom, which
 * hands control to the (malicious) asset mid-call -- before the guard fix this
 * lets the asset re-enter another money-mover (borrowFromPortfolio) freely.
 * After the fix (ReentrancyGuardTransientUpgradeable + nonReentrant on these
 * functions), the inner call reverts with OZ's ReentrancyGuardReentrantCall().
 *
 * The parameterless OZ error has the same selector across the transient and
 * non-transient guards, so we assert against ReentrancyGuardTransient's.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MockReentrantERC20} from "../../mocks/MockReentrantERC20.sol";

/// @dev Minimal portfolio factory: any non-zero address is a "portfolio" and is
///      its own owner. Mirrors the stub used by the other vault tests.
contract MockPortfolioFactoryReentrancy is IPortfolioFactory {
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

contract DynamicFeesVaultReentrancyTest is Test {
    DynamicFeesVault internal vault;
    MockReentrantERC20 internal asset;
    MockPortfolioFactoryReentrancy internal portfolioFactory;

    address internal owner = address(0x1);

    uint256 internal constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 internal constant EPOCH_2 = 2 * WEEK;
    uint256 internal constant LP_DEPOSIT = 1_000e18;

    function setUp() public {
        // Fixed absolute timestamp on an epoch boundary (avoids via-ir caching pitfalls).
        vm.warp(EPOCH_2);

        // Callback-capable asset: re-enters on transferFrom when armed.
        asset = new MockReentrantERC20("Callback USD", "cUSD", 18);
        portfolioFactory = new MockPortfolioFactoryReentrancy();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(asset), "Callback Vault", "cVAULT",
            address(portfolioFactory), address(this), uint256(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Seed vault liquidity (this contract is an LP).
        asset.mint(address(this), LP_DEPOSIT);
        asset.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, address(this));
    }

    /* =====================================================================
     * NEGATIVE TEST (expected to FAIL on current unguarded code):
     * a "borrower" (address `borrower`) repays. During repay()'s
     * safeTransferFrom pull, the malicious asset re-enters
     * borrowFromPortfolio() on the vault.
     *
     * Post-fix: repay() holds the transient nonReentrant slot; the re-entrant
     * borrowFromPortfolio reverts ReentrancyGuardReentrantCall(), bubbled by
     * the mock.
     * Current code: no guard, the re-entrant borrow succeeds, repay completes,
     * and NO revert occurs -- expectRevert then fails
     * ("call did not revert as expected"), proving the guard is absent.
     * =====================================================================*/
    function test_Repay_Reentrancy_IntoBorrow_Reverts() public {
        address borrower = address(0xB0110);

        // Borrower takes a loan so repay() does real work (pulls assets).
        uint256 borrowAmount = 100e18;
        vm.prank(borrower);
        vault.borrowFromPortfolio(borrowAmount);

        // Fund the borrower to repay.
        uint256 repayAmount = 40e18;
        asset.mint(borrower, repayAmount);

        // Arm the asset: when repay() pulls funds via transferFrom, re-enter
        // borrowFromPortfolio for a fresh loan. msg.sender of the inner call is
        // the asset contract; the mock factory treats any non-zero address as a
        // portfolio, so it clears onlyPortfolio and we measure nonReentrant.
        bytes memory reentrantCall =
            abi.encodeWithSelector(DynamicFeesVault.borrowFromPortfolio.selector, uint256(10e18));
        asset.arm(address(vault), reentrantCall);

        vm.startPrank(borrower);
        asset.approve(address(vault), repayAmount);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.repay(repayAmount);
        vm.stopPrank();
    }

    /* =====================================================================
     * NEGATIVE TEST variant: re-enter repay() itself (a different guarded
     * money-mover) during the outer repay()'s transferFrom pull. Re-entering
     * the SAME function is the canonical reentrancy shape and is the strongest
     * signal that the function lacks self-reentrancy protection.
     *
     * Current code: no guard -> the inner repay() also pulls funds and
     * completes; no revert. Post-fix: inner repay reverts
     * ReentrancyGuardReentrantCall().
     * =====================================================================*/
    function test_Repay_Reentrancy_IntoRepay_Reverts() public {
        address borrower = address(0xB0220);

        vm.prank(borrower);
        vault.borrowFromPortfolio(100e18);

        // Enough to cover the outer pull plus the re-entrant inner pull.
        asset.mint(borrower, 60e18);

        bytes memory reentrantCall =
            abi.encodeWithSelector(DynamicFeesVault.repay.selector, uint256(10e18));
        asset.arm(address(vault), reentrantCall);

        vm.startPrank(borrower);
        asset.approve(address(vault), type(uint256).max);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.repay(40e18);
        vm.stopPrank();
    }

    /* =====================================================================
     * POSITIVE CONTROL (must pass on current AND fixed code):
     * a normal repay() with the (un-armed) asset succeeds and reduces debt.
     * Ensures adding the guard is not a tautology -- the happy path must keep
     * working after the modifier lands.
     * =====================================================================*/
    function test_Repay_NormalRepayment_ReducesDebt() public {
        address borrower = address(0xB0330);

        uint256 borrowAmount = 100e18;
        vm.prank(borrower);
        vault.borrowFromPortfolio(borrowAmount);
        assertEq(vault.getDebtBalance(borrower), borrowAmount, "control: debt after borrow");

        uint256 repayAmount = 40e18;
        asset.mint(borrower, repayAmount);

        // Asset is NOT armed -> behaves as a plain ERC20, no reentry.
        vm.startPrank(borrower);
        asset.approve(address(vault), repayAmount);
        vault.repay(repayAmount);
        vm.stopPrank();

        assertEq(
            vault.getDebtBalance(borrower),
            borrowAmount - repayAmount,
            "control: debt reduced by exact repayment"
        );
    }
}
