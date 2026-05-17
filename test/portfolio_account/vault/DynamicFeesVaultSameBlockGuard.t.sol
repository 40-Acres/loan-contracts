// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/*
 * =============================================================
 * DynamicFeesVaultSameBlockGuard
 * =============================================================
 * Targeted tests for the same-block flash-deposit guard after the
 * fix that consolidates the flag write into `_deposit` gated on
 * `caller == receiver` and deletes the `_update` override.
 *
 * Pre-fix bug: ERC4626 `_update` wrote
 *   $.lastDepositBlock[receiver] = block.number
 * on every mint (including `deposit(0, victim)`), allowing any
 * third party to DoS a victim's withdraw/redeem for one block.
 *
 * Post-fix invariants verified here:
 *   - Self-deposit pins the depositor's block.
 *   - Third-party deposits (zero OR non-zero) do NOT pin the
 *     receiver's block.
 *   - maxWithdraw / maxRedeem reflect those semantics.
 *   - Share transfers do NOT pin the recipient's block.
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

contract DynamicFeesVaultSameBlockGuardTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public victim   = address(0xB1);
    address public attacker = address(0xB2);
    address public alice    = address(0xC1);
    address public bob      = address(0xC2);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;

    function setUp() public {
        vm.warp(EPOCH_2);

        vm.label(victim, "Victim");
        vm.label(attacker, "Attacker");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "USDC Vault",
            "vUSDC",
            address(portfolioFactory),
            address(this),    // feeRecipient
            uint256(0)        // feeBps = 0 (no perf fee for these tests)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));
        vm.label(address(vault), "DynamicFeesVault");
    }

    // ----------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------

    function _selfDeposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _selfMint(address user, uint256 shares) internal {
        uint256 assets = vault.previewMint(shares);
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.mint(shares, user);
        vm.stopPrank();
    }

    // ----------------------------------------------------------
    // (1) Self-deposit pins; same-block withdraw reverts;
    //     next block, withdraw succeeds.
    // ----------------------------------------------------------

    function test_selfDeposit_pinsBlock_sameBlockWithdrawReverts() public {
        _selfDeposit(victim, 1000e6);

        // The same-block guard makes maxWithdraw return 0; the public withdraw
        // path therefore reverts. (Either ERC4626 max-check revert OR the
        // _withdraw require-string is acceptable; both indicate the guard
        // is active.)
        vm.prank(victim);
        vm.expectRevert();
        vault.withdraw(100e6, victim, victim);

        assertEq(vault.maxWithdraw(victim), 0, "maxWithdraw=0 confirms guard active");
    }

    function test_selfDeposit_nextBlock_withdrawSucceeds() public {
        _selfDeposit(victim, 1000e6);

        vm.roll(block.number + 1);

        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim received 100 USDC next block");
    }

    // ----------------------------------------------------------
    // (2) Third-party deposit does NOT pin victim's block.
    //     This is the grief-fix assertion.
    // ----------------------------------------------------------

    function test_thirdParty_zeroDeposit_doesNotPinVictim() public {
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        // Attacker grief attempt: deposit(0, victim) in block N+1.
        vm.prank(attacker);
        vault.deposit(0, victim);

        // Victim must still be able to redeem in the same block.
        uint256 victimShares = vault.balanceOf(victim);
        assertGt(victimShares, 0, "victim has shares");

        vm.prank(victim);
        uint256 assets = vault.redeem(victimShares, victim, victim);
        assertGt(assets, 0, "victim redeem produced assets");
        assertEq(vault.balanceOf(victim), 0, "all shares redeemed");
    }

    function test_thirdParty_nonZeroDeposit_doesNotPinVictim() public {
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        usdc.mint(attacker, 50e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 50e6);
        vault.deposit(50e6, victim);
        vm.stopPrank();

        // Same-block withdraw must succeed — victim's lastDepositBlock
        // should still be the original block, not the current one.
        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim withdrew same block as third-party deposit");
    }

    // ----------------------------------------------------------
    // (3) maxWithdraw / maxRedeem reflect the new semantics.
    // ----------------------------------------------------------

    function test_maxWithdraw_zero_afterSelfDeposit_sameBlock() public {
        _selfDeposit(victim, 1000e6);
        assertEq(vault.maxWithdraw(victim), 0, "maxWithdraw=0 same block as self-deposit");
        assertEq(vault.maxRedeem(victim), 0, "maxRedeem=0 same block as self-deposit");
    }

    function test_maxWithdraw_nonZero_afterThirdPartyDeposit_sameBlock() public {
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        vm.prank(attacker);
        vault.deposit(0, victim);

        uint256 maxW = vault.maxWithdraw(victim);
        assertGt(maxW, 0, "maxWithdraw must be non-zero -- third-party deposit must not pin victim");

        uint256 maxR = vault.maxRedeem(victim);
        assertGt(maxR, 0, "maxRedeem must be non-zero after third-party deposit");
    }

    // ----------------------------------------------------------
    // (4) mint() variant of the same checks.
    // ----------------------------------------------------------

    function test_selfMint_pinsBlock_sameBlockRedeemReverts() public {
        _selfMint(victim, 1000e6);
        uint256 shares = vault.balanceOf(victim);

        vm.prank(victim);
        vm.expectRevert();
        vault.redeem(shares, victim, victim);

        assertEq(vault.maxRedeem(victim), 0, "maxRedeem=0 same block as self-mint");
    }

    function test_thirdPartyMint_doesNotPinVictim() public {
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        // Attacker mints shares to victim — caller != receiver, so the flag
        // must NOT be written under the new gate.
        uint256 mintShares = 1e6;
        uint256 assetsNeeded = vault.previewMint(mintShares);
        usdc.mint(attacker, assetsNeeded);
        vm.startPrank(attacker);
        usdc.approve(address(vault), assetsNeeded);
        vault.mint(mintShares, victim);
        vm.stopPrank();

        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim withdrew same block as third-party mint");
    }

    // ----------------------------------------------------------
    // (5) Share transfers do NOT pin the recipient's block.
    //     Locks the new semantics — _update no longer writes the flag.
    // ----------------------------------------------------------

    function test_shareTransfer_doesNotPinRecipient() public {
        _selfDeposit(alice, 500e6);
        vm.roll(block.number + 1);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        IERC20(address(vault)).transfer(bob, aliceShares);

        // Bob's lastDepositBlock should be untouched (0). Bob can redeem
        // in the same block he received the shares.
        vm.prank(bob);
        uint256 assets = vault.redeem(aliceShares, bob, bob);
        assertGt(assets, 0, "bob redeemed received shares same block");
        assertEq(usdc.balanceOf(bob), assets, "bob received assets from redeem");
    }

    function test_transferFrom_doesNotPinRecipient() public {
        _selfDeposit(alice, 500e6);
        vm.roll(block.number + 1);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        IERC20(address(vault)).approve(attacker, aliceShares);

        vm.prank(attacker);
        IERC20(address(vault)).transferFrom(alice, bob, aliceShares);

        // Bob must be able to redeem same block — _update no longer writes the flag.
        vm.prank(bob);
        uint256 assets = vault.redeem(aliceShares, bob, bob);
        assertGt(assets, 0, "bob redeemed pulled shares same block");
    }

    // ----------------------------------------------------------
    // (6) Zero-share self-deposit edge case: caller == receiver,
    //     so the flag bumps and the depositor is gated this block.
    // ----------------------------------------------------------

    function test_zeroShareSelfDeposit_stillPinsBlock() public {
        vm.prank(victim);
        vault.deposit(0, victim);

        assertEq(vault.maxWithdraw(victim), 0, "maxWithdraw=0 same block as zero-amount self-deposit");
    }
}
