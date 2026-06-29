// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/*
 * =============================================================
 * LendingVaultSameBlockGuard
 * =============================================================
 * Targeted tests for the same-block flash-deposit guard.
 *
 * Design: shares ACQUIRED this block by an address -- whether via
 * mint (deposit/mint) OR via ERC20 transfer-in -- are "pinned" and
 * cannot be withdrawn/redeemed until the next block. Implemented in
 * the `_update` override, which records `lastMintBlock[to]` and
 * accumulates `sameBlockAcquiredShares[to]` for every inbound
 * transfer. `_withdraw` then requires
 *   balanceOf(owner) >= shares + locked
 * where `locked` is the amount acquired this block.
 *
 * Only the just-acquired amount is pinned, so the guard is
 * griefing-resistant: a dust deposit/transfer to a victim pins only
 * the dust, never the victim's pre-existing balance (acquired in a
 * prior block), which stays fully withdrawable.
 *
 * Invariants verified here:
 *   - Self-deposit/self-mint pins the freshly minted shares this block.
 *   - A third-party deposit/mint/transfer to a holder pins ONLY the
 *     newly acquired amount; pre-existing balance stays withdrawable.
 *   - A transfer to a fresh (zero-balance) receiver pins the whole
 *     received amount this block, released next block.
 *   - maxWithdraw / maxRedeem cap at balanceOf - locked.
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

contract LendingVaultSameBlockGuardTest is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public vaultOwner = address(0xA1);
    address public victim     = address(0xB1);
    address public attacker   = address(0xB2);
    address public alice      = address(0xC1);
    address public bob        = address(0xC2);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;

    uint256 constant MAX_UTIL_BPS = 8000;
    uint256 constant ORIG_FEE_BPS = 0; // keep math clean

    // Absolute base block. via-ir may cache block.number across vm.roll calls
    // within a function, so multi-roll tests use hardcoded absolute numbers
    // (BLOCK_START + N) rather than block.number + 1.
    uint256 constant BLOCK_START = 1000;

    function setUp() public {
        vm.warp(EPOCH_2);
        vm.roll(BLOCK_START);

        vm.label(vaultOwner, "VaultOwner");
        vm.label(victim, "Victim");
        vm.label(attacker, "Attacker");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();

        LendingVault impl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(usdc),
            address(portfolioFactory),
            vaultOwner,
            "Lending Vault",
            "lvUSDC",
            ORIG_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = LendingVault(address(proxy));
        vm.label(address(vault), "LendingVault");
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

        // Same-block guard pins lastDepositBlock => maxWithdraw returns 0
        // => ERC4626 reverts on the maxWithdraw check before reaching _withdraw.
        // (Either revert path is acceptable; we just need to confirm the call
        // fails in the same block as the self-deposit.)
        vm.prank(victim);
        vm.expectRevert();
        vault.withdraw(100e6, victim, victim);

        // And maxWithdraw confirms it's the guard, not e.g. a balance issue.
        assertEq(vault.maxWithdraw(victim), 0, "maxWithdraw=0 confirms same-block guard active");
    }

    function test_selfDeposit_nextBlock_withdrawSucceeds() public {
        _selfDeposit(victim, 1000e6);

        vm.roll(block.number + 1);

        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim received 100 USDC");
    }

    // ----------------------------------------------------------
    // (2) Third-party deposit does NOT pin victim's block.
    //     This is the actual grief-fix assertion.
    // ----------------------------------------------------------

    function test_thirdParty_zeroDeposit_doesNotPinVictim() public {
        // Victim self-deposits in block N, then time advances.
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1); // block N+1

        // Attacker tries the grief: deposit(0, victim) in block N+1.
        vm.prank(attacker);
        vault.deposit(0, victim);

        // Victim must still be able to redeem/withdraw in the same block.
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

        // Attacker funds itself and front-deposits to victim's address.
        usdc.mint(attacker, 50e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 50e6);
        vault.deposit(50e6, victim);
        vm.stopPrank();

        // Victim's lastDepositBlock should still be the original (block N),
        // not the current block (N+1). Same-block withdraw must succeed.
        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim withdrew 100 USDC same block as third-party deposit");
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

        // Third-party tries to grief.
        vm.prank(attacker);
        vault.deposit(0, victim);

        // maxWithdraw should reflect the real liquid value, not zero.
        uint256 maxW = vault.maxWithdraw(victim);
        assertGt(maxW, 0, "maxWithdraw should be non-zero -- third-party deposit must not pin victim");
        // With zero loans, liquid == totalAssets and victim owns all shares,
        // so maxWithdraw equals the original deposit (no fees, no interest).
        assertEq(maxW, 1000e6, "maxWithdraw equals original deposit");

        uint256 maxR = vault.maxRedeem(victim);
        assertGt(maxR, 0, "maxRedeem should be non-zero after third-party deposit");
    }

    // ----------------------------------------------------------
    // (4) mint() variant of the same checks.
    // ----------------------------------------------------------

    function test_selfMint_pinsBlock_sameBlockRedeemReverts() public {
        _selfMint(victim, 1000e6); // 1000 shares
        uint256 shares = vault.balanceOf(victim);

        // mint() funnels through _deposit just like deposit(); the flag is
        // bumped because caller == receiver.
        vm.prank(victim);
        vm.expectRevert();
        vault.redeem(shares, victim, victim);

        assertEq(vault.maxRedeem(victim), 0, "maxRedeem=0 same block as self-mint");
    }

    function test_thirdPartyMint_doesNotPinVictim() public {
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        // Attacker mints shares to victim — still passes through _deposit, but
        // caller != receiver, so the flag must NOT be written.
        uint256 mintShares = 1e6; // tiny mint
        uint256 assetsNeeded = vault.previewMint(mintShares);
        usdc.mint(attacker, assetsNeeded);
        vm.startPrank(attacker);
        usdc.approve(address(vault), assetsNeeded);
        vault.mint(mintShares, victim);
        vm.stopPrank();

        // Victim can still withdraw same block.
        vm.prank(victim);
        vault.withdraw(100e6, victim, victim);
        assertEq(usdc.balanceOf(victim), 100e6, "victim withdrew same block as third-party mint");
    }

    // ----------------------------------------------------------
    // (5) Transfer-in pins the receiver's freshly-received shares
    //     this block (the _update override fires on every inbound
    //     transfer, not just mints). Released next block.
    // ----------------------------------------------------------

    function test_shareTransfer_pinsJustReceivedShares_sameBlock() public {
        // Alice deposits at BLOCK_START so her shares are unpinned by the
        // transfer block. Absolute block numbers dodge via-ir block.number caching.
        _selfDeposit(alice, 500e6);
        vm.roll(BLOCK_START + 1);

        uint256 aliceShares = vault.balanceOf(alice);

        // Transfer block: alice transfers all shares to a FRESH bob (zero prior balance).
        vm.prank(alice);
        IERC20(address(vault)).transfer(bob, aliceShares);

        // (a) Pinned this block: bob cannot redeem the just-received shares.
        assertEq(vault.maxRedeem(bob), 0, "maxRedeem=0 -- received shares pinned this block");
        assertEq(vault.maxWithdraw(bob), 0, "maxWithdraw=0 -- received shares pinned this block");
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(aliceShares, bob, bob);

        // (b) Released next block: bob can now redeem and receives assets.
        vm.roll(BLOCK_START + 2);
        assertEq(vault.maxRedeem(bob), aliceShares, "maxRedeem unlocked next block");
        vm.prank(bob);
        uint256 assets = vault.redeem(aliceShares, bob, bob);
        assertGt(assets, 0, "bob redeemed received shares next block");
        assertEq(usdc.balanceOf(bob), assets, "bob received assets from redeem");
    }

    function test_transferFrom_pinsJustReceivedShares_sameBlock() public {
        _selfDeposit(alice, 500e6);
        vm.roll(BLOCK_START + 1);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        IERC20(address(vault)).approve(attacker, aliceShares);

        // Transfer block: attacker pulls alice's shares into a FRESH bob.
        vm.prank(attacker);
        IERC20(address(vault)).transferFrom(alice, bob, aliceShares);

        // (a) Pinned this block.
        assertEq(vault.maxRedeem(bob), 0, "maxRedeem=0 -- pulled shares pinned this block");
        assertEq(vault.maxWithdraw(bob), 0, "maxWithdraw=0 -- pulled shares pinned this block");
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(aliceShares, bob, bob);

        // (b) Released next block.
        vm.roll(BLOCK_START + 2);
        assertEq(vault.maxRedeem(bob), aliceShares, "maxRedeem unlocked next block");
        vm.prank(bob);
        uint256 assets = vault.redeem(aliceShares, bob, bob);
        assertGt(assets, 0, "bob redeemed pulled shares next block");
    }

    // ----------------------------------------------------------
    // (5b) Griefing-resistance over the transfer path: a dust
    //      transfer pins ONLY the dust, never the recipient's
    //      pre-existing balance.
    // ----------------------------------------------------------

    function test_shareTransfer_doesNotPinPreExistingBalance() public {
        // Bob self-deposits in block N, then the block advances so his
        // balance is fully unpinned (acquired in a prior block).
        _selfDeposit(bob, 500e6);
        vm.roll(block.number + 1);

        uint256 bobPreExisting = vault.balanceOf(bob);
        assertGt(bobPreExisting, 0, "bob has pre-existing shares");

        // Alice deposited in a prior block so she has unpinned shares to send.
        _selfDeposit(alice, 10e6);
        vm.roll(block.number + 1);
        uint256 dustShares = vault.balanceOf(alice) / 100; // tiny slice
        assertGt(dustShares, 0, "dust slice is non-zero");

        // Block M: alice transfers dust shares to bob.
        vm.prank(alice);
        IERC20(address(vault)).transfer(bob, dustShares);

        // Only the dust is pinned: maxRedeem caps at pre-existing balance.
        assertEq(vault.maxRedeem(bob), bobPreExisting, "only dust pinned; pre-existing redeemable");

        // Bob can STILL withdraw up to his pre-existing balance, same block.
        uint256 preExistingAssets = vault.convertToAssets(bobPreExisting);
        vm.prank(bob);
        vault.withdraw(preExistingAssets, bob, bob);
        assertEq(usdc.balanceOf(bob), preExistingAssets, "bob withdrew full pre-existing balance same block");
        // The dust shares remain (pinned this block).
        assertEq(vault.balanceOf(bob), dustShares, "only the pinned dust remains");
    }

    // ----------------------------------------------------------
    // (6) Zero-share self-deposit edge case. Under the pin-acquired
    //     design a zero-amount deposit acquires 0 shares, so it pins
    //     NOTHING. The assertion holds only trivially: victim has no
    //     shares at all, so maxWithdraw is 0 regardless of the guard.
    //     (Test name retained; the "pins block" claim is vacuous here.)
    // ----------------------------------------------------------

    function test_zeroShareSelfDeposit_stillPinsBlock() public {
        vm.prank(victim);
        vault.deposit(0, victim);

        assertEq(vault.maxWithdraw(victim), 0, "maxWithdraw=0 -- victim has no shares (zero acquisition pins nothing)");
    }

    function test_zeroShareSelfDeposit_doesNotPinPreExistingBalance() public {
        // Victim self-deposits in a prior block; balance becomes unpinned.
        _selfDeposit(victim, 1000e6);
        vm.roll(block.number + 1);

        uint256 preExisting = vault.balanceOf(victim);
        assertGt(preExisting, 0, "victim has pre-existing shares");

        // A zero-amount self-deposit this block acquires 0 shares, so it must
        // pin nothing -- the pre-existing balance stays fully withdrawable.
        vm.prank(victim);
        vault.deposit(0, victim);

        assertEq(vault.maxRedeem(victim), preExisting, "zero deposit pins nothing; full balance redeemable");

        vm.prank(victim);
        vault.redeem(preExisting, victim, victim);
        assertEq(vault.balanceOf(victim), 0, "victim redeemed full pre-existing balance same block");
    }

    // ----------------------------------------------------------
    // (7) Third-party deposit/mint bypass on a FRESH zero-balance
    //     account. The pin is gated on caller==receiver, so a
    //     deposit/mint TO alice (caller=attacker) never pins alice.
    //     With NO pre-existing balance, alice withdraws EXACTLY the
    //     shares acquired this block -- the guard must catch that.
    //     POST-FIX expectation: redeem reverts. Current code: it
    //     succeeds (bypass), so these tests FAIL today.
    // ----------------------------------------------------------

    function test_thirdPartyDeposit_bypass_freshAccountRedeemsSameBlock() public {
        // alice has ZERO prior vault balance.
        assertEq(vault.balanceOf(alice), 0, "alice starts with zero shares");

        // Attacker deposits to alice (caller=attacker != receiver=alice),
        // all in the current block (no vm.roll).
        usdc.mint(attacker, 1000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "alice received freshly-acquired shares this block");

        // Same block: alice redeems exactly the just-acquired shares.
        // Post-fix this must revert (shares acquired this block are pinned).
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(aliceShares, alice, alice);
    }

    function test_thirdPartyMint_bypass_freshAccountRedeemsSameBlock() public {
        assertEq(vault.balanceOf(alice), 0, "alice starts with zero shares");

        // Attacker mints shares to alice (caller=attacker != receiver=alice).
        uint256 mintShares = 1000e6;
        uint256 assetsNeeded = vault.previewMint(mintShares);
        usdc.mint(attacker, assetsNeeded);
        vm.startPrank(attacker);
        usdc.approve(address(vault), assetsNeeded);
        vault.mint(mintShares, alice);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "alice received freshly-minted shares this block");

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(aliceShares, alice, alice);
    }
}
