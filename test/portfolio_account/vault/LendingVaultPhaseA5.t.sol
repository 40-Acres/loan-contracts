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
 * LendingVault Phase A5 Hardening Regression Tests
 * =============================================================
 * Locks in fixes shipped in src/facets/account/vault/LendingVault.sol:
 *   1. nonReentrant on borrowFromPortfolio / payFromPortfolio / depositRewards
 *   2. originationFeeBps upper bound (MAX_FEE_BPS = 1000) on initialize and
 *      setOriginationFee
 *   3. Design choice: payFromPortfolio MUST work while paused; borrowFromPortfolio
 *      must NOT.
 *
 * Note: the lender-side same-block withdraw/redeem guard (PR #243) was
 * REMOVED; its tests were deleted. The independent borrow-cap guard
 * (borrowableTotalAssets / lastDepositBlock) is covered in
 * LendingVaultSameBlockGuard.t.sol.
 *
 * Each test comment names a falsifiable mutation it would catch.
 * =============================================================
 */

// -------------------------------------------------------------
// Mock USDC — clean ERC20, no hooks. Used for non-reentrancy tests.
// -------------------------------------------------------------
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// -------------------------------------------------------------
// HookableUSDC — ERC20 that invokes a configured callback on transfer
// and transferFrom. Used to drive the reentrancy regressions: the
// vault's safeTransfer / safeTransferFrom inside borrow/pay/deposit
// hands control to the malicious portfolio, which tries to re-enter.
// -------------------------------------------------------------
interface ITransferHook {
    function onTokenTransfer() external;
}

contract HookableUSDC is ERC20 {
    address public hookTarget;
    bool public hookEnabled;

    constructor() ERC20("Hookable USDC", "hUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address target, bool enabled) external {
        hookTarget = target;
        hookEnabled = enabled;
    }

    // Fire the hook AFTER the standard ERC20 state updates so the
    // re-entered call sees the post-transfer balances (the realistic
    // attack model). We override _update to inject the callback.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookEnabled && hookTarget != address(0)) {
            // Best effort — let revert from re-entrancy guard bubble up.
            ITransferHook(hookTarget).onTokenTransfer();
        }
    }
}

// -------------------------------------------------------------
// Portfolio factory mock — same shape as the existing test file.
// isPortfolio(addr) returns true for any non-zero address, so our
// malicious portfolio contract qualifies.
// -------------------------------------------------------------
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

// -------------------------------------------------------------
// Malicious portfolio — re-enters the vault on token-transfer hook.
// Mode controls which entrypoint to attack. Re-entrancy must revert
// with OZ v5's ReentrancyGuardReentrantCall(); we let the underlying
// USDC's _update bubble that revert and assert at the outer call.
// -------------------------------------------------------------
contract MaliciousPortfolio is ITransferHook {
    enum Mode { NONE, BORROW, PAY, DEPOSIT_REWARDS }

    LendingVault public immutable vault;
    HookableUSDC public immutable token;
    Mode public mode;
    bool public attempted;

    constructor(LendingVault _vault, HookableUSDC _token) {
        vault = _vault;
        token = _token;
    }

    function setMode(Mode _mode) external {
        mode = _mode;
        attempted = false;
    }

    // Approve vault to pull tokens (used for pay / depositRewards paths).
    function approveVault(uint256 amount) external {
        token.approve(address(vault), amount);
    }

    // Initiate the outer call from this contract so msg.sender to the
    // vault is this malicious portfolio (passes onlyPortfolio).
    function callBorrow(uint256 amount) external returns (uint256) {
        return vault.borrowFromPortfolio(amount);
    }

    function callPay(uint256 totalPayment, uint256 feesToPay) external returns (uint256) {
        return vault.payFromPortfolio(totalPayment, feesToPay);
    }

    function callDepositRewards(uint256 amount) external {
        vault.depositRewards(amount);
    }

    // Hook fires inside vault.safeTransfer / safeTransferFrom. We re-enter
    // the same vault entrypoint to verify nonReentrant guards each one.
    function onTokenTransfer() external override {
        if (attempted) return; // only re-enter once to keep the trace tight
        attempted = true;
        if (mode == Mode.BORROW) {
            vault.borrowFromPortfolio(1e6);
        } else if (mode == Mode.PAY) {
            vault.payFromPortfolio(1e6, 0);
        } else if (mode == Mode.DEPOSIT_REWARDS) {
            vault.depositRewards(1e6);
        }
    }
}

// =============================================================
// Test contract
// =============================================================
contract LendingVaultPhaseA5Test is Test {
    LendingVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public vaultOwner;
    address public depositor1;
    address public depositor2;
    address public borrower;

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;

    uint256 constant MAX_UTIL_BPS = 8000; // 80%
    uint256 constant ORIG_FEE_BPS = 50;   // 0.5%

    // OZ v5 ReentrancyGuardReentrantCall() selector — locked in by the spec
    bytes4 constant REENTRANT_SELECTOR = 0x3ee5aeb5;

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

        vault = _deployVault(address(usdc), ORIG_FEE_BPS);
        vm.label(address(vault), "LendingVault");
    }

    // -------------------------------------------------------------
    // Deployment helpers
    // -------------------------------------------------------------
    function _deployVault(address asset_, uint256 feeBps_) internal returns (LendingVault v) {
        LendingVault impl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            asset_,
            address(portfolioFactory),
            vaultOwner,
            "Lending Vault",
            "lvUSDC",
            feeBps_
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = LendingVault(address(proxy));
    }

    function _depositSameBlock(address depositor, uint256 amount) internal {
        // No vm.roll — same-block tests need the deposit to remain in this block.
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _depositAndAdvance(address depositor, uint256 amount) internal {
        _depositSameBlock(depositor, amount);
        vm.roll(block.number + 1);
    }

    // =============================================================
    // (1) Reentrancy regressions
    //     Catches: removing `nonReentrant` from any of the three entrypoints.
    //     Mechanism: HookableUSDC fires onTokenTransfer during
    //     safeTransfer/safeTransferFrom inside the vault. The malicious
    //     portfolio re-enters; OZ v5 reverts with ReentrancyGuardReentrantCall.
    // =============================================================

    function _setupReentrancyEnv()
        internal
        returns (LendingVault v, HookableUSDC h, MaliciousPortfolio mp)
    {
        h = new HookableUSDC();
        v = _deployVault(address(h), ORIG_FEE_BPS);
        mp = new MaliciousPortfolio(v, h);
        h.setHook(address(mp), false); // disable hook during initial liquidity provisioning
        // Seed the vault with liquidity from a clean depositor.
        h.mint(depositor1, 10_000e6);
        vm.startPrank(depositor1);
        h.approve(address(v), 10_000e6);
        v.deposit(10_000e6, depositor1);
        vm.stopPrank();
        vm.roll(block.number + 1); // clear flash-deposit guard for any later withdrawals
    }

    /// Catches: removing `nonReentrant` from borrowFromPortfolio.
    /// Without the guard the inner borrowFromPortfolio call would itself
    /// succeed and we'd not see the OZ revert.
    function test_BorrowFromPortfolio_NonReentrant() public {
        (LendingVault v, HookableUSDC h, MaliciousPortfolio mp) = _setupReentrancyEnv();

        mp.setMode(MaliciousPortfolio.Mode.BORROW);
        h.setHook(address(mp), true);

        vm.expectRevert(abi.encodeWithSelector(REENTRANT_SELECTOR));
        mp.callBorrow(100e6);

        // sanity: state didn't change for the malicious portfolio
        assertEq(v.getDebtBalance(address(mp)), 0, "debt must not be recorded when reentrant call is rejected");
    }

    /// Catches: removing `nonReentrant` from payFromPortfolio.
    /// Re-entry happens inside safeTransferFrom (the fee transfer).
    function test_PayFromPortfolio_NonReentrant() public {
        (LendingVault v, HookableUSDC h, MaliciousPortfolio mp) = _setupReentrancyEnv();

        // Establish real debt first (fees=0 so the borrow itself doesn't try
        // to send to owner; hook is still off here).
        mp.setMode(MaliciousPortfolio.Mode.NONE);
        mp.callBorrow(500e6);

        // Fund the malicious portfolio so safeTransferFrom on pay can succeed
        // up to the point where the hook fires.
        h.mint(address(mp), 1_000e6);
        mp.approveVault(1_000e6);

        mp.setMode(MaliciousPortfolio.Mode.PAY);
        h.setHook(address(mp), true);

        // Pay with feesToPay > 0 so the FIRST transfer (fees -> owner) fires
        // the hook before any debt accounting.
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_SELECTOR));
        mp.callPay(100e6, 10e6);

        // sanity: original 500e6 debt unchanged because the outer call reverted.
        assertEq(v.getDebtBalance(address(mp)), 500e6, "debt must not change when reentrant call is rejected");
    }

    /// Catches: removing `nonReentrant` from depositRewards.
    function test_DepositRewards_NonReentrant() public {
        (LendingVault v, HookableUSDC h, MaliciousPortfolio mp) = _setupReentrancyEnv();

        h.mint(address(mp), 1_000e6);
        mp.approveVault(1_000e6);

        mp.setMode(MaliciousPortfolio.Mode.DEPOSIT_REWARDS);
        h.setHook(address(mp), true);

        vm.expectRevert(abi.encodeWithSelector(REENTRANT_SELECTOR));
        mp.callDepositRewards(50e6);

        // sanity: epoch rewards untouched.
        assertEq(v.lastEpochReward(), 0, "epoch rewards must not accumulate when reentrant call is rejected");
    }

    // =============================================================
    // (2) Withdraw sanity
    // =============================================================

    /// Next-block withdraw succeeds (sanity; not a #243 same-block assertion).
    function test_NextBlock_WithdrawSucceeds() public {
        _depositSameBlock(depositor1, 1_000e6);
        vm.roll(block.number + 1);

        uint256 maxW = vault.maxWithdraw(depositor1);
        assertGt(maxW, 0, "maxWithdraw should be positive next block");

        uint256 balBefore = usdc.balanceOf(depositor1);
        vm.prank(depositor1);
        vault.withdraw(maxW, depositor1, depositor1);
        assertEq(usdc.balanceOf(depositor1) - balBefore, maxW, "withdraw must succeed next block");
    }

    // =============================================================
    // (3) originationFeeBps upper bound
    // =============================================================

    /// Catches: removing the `if (originationFeeBps_ > MAX_FEE_BPS) revert`
    /// in initialize. Without it a deployer could ship a 100% fee vault.
    function test_Initialize_RevertsIfFeeAboveMax() public {
        LendingVault impl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(usdc),
            address(portfolioFactory),
            vaultOwner,
            "Lending Vault",
            "lvUSDC",
            uint256(1001) // one above MAX_FEE_BPS
        );
        vm.expectRevert(LendingVault.FeeBpsTooHigh.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// Catches: replacing `>` with `>=` (off-by-one) in the initialize check —
    /// the boundary value (MAX_FEE_BPS) must still succeed.
    function test_Initialize_AcceptsAtMaxFee() public {
        LendingVault v = _deployVault(address(usdc), 1000); // == MAX_FEE_BPS
        assertEq(v.originationFeeBps(), 1000, "vault must accept fee == MAX_FEE_BPS");
    }

    /// Catches: removing the `if (originationFeeBps_ > MAX_FEE_BPS) revert`
    /// in setOriginationFee. Without it owner could later push fee to 100%.
    function test_SetOriginationFee_RevertsIfAboveMax() public {
        vm.prank(vaultOwner);
        vm.expectRevert(LendingVault.FeeBpsTooHigh.selector);
        vault.setOriginationFee(1001);
    }

    /// Catches: replacing `>` with `>=` in setOriginationFee.
    function test_SetOriginationFee_AcceptsAtMax() public {
        vm.prank(vaultOwner);
        vault.setOriginationFee(1000);
        assertEq(vault.originationFeeBps(), 1000, "owner must be able to set fee == MAX_FEE_BPS");
    }

    // =============================================================
    // (4) Pause behaviour — design-locked tests
    // =============================================================

    /// Catches: a future change that adds `whenNotPaused` to payFromPortfolio.
    /// Repays must still work during emergency pause so borrowers can avoid
    /// liquidation while admin investigates.
    function test_PayFromPortfolio_WorksWhilePaused() public {
        // Seed liquidity, then borrow.
        _depositAndAdvance(depositor1, 10_000e6);
        vm.prank(borrower);
        vault.borrowFromPortfolio(500e6);

        // Pause.
        vm.prank(vaultOwner);
        vault.pause();
        assertTrue(vault.paused(), "precondition: vault is paused");

        // Fund borrower so safeTransferFrom can pull repayment.
        usdc.mint(borrower, 200e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 200e6);
        uint256 paid = vault.payFromPortfolio(200e6, 0);
        vm.stopPrank();

        assertEq(paid, 200e6, "repayment must succeed during pause");
        assertEq(vault.getDebtBalance(borrower), 300e6, "debt must decrease by repayment amount during pause");
    }

    /// Catches: removing `whenNotPaused` from borrowFromPortfolio. Pausing
    /// the vault must stop new lending immediately.
    function test_BorrowFromPortfolio_RevertsWhilePaused() public {
        _depositAndAdvance(depositor1, 10_000e6);

        vm.prank(vaultOwner);
        vault.pause();

        vm.prank(borrower);
        vm.expectRevert(LendingVault.VaultPaused.selector);
        vault.borrowFromPortfolio(100e6);
    }
}
