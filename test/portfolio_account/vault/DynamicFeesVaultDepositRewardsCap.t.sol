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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000e6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
    function isPortfolio(address _portfolio) external pure override returns (bool) { return _portfolio != address(0); }
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

/// @notice Flat lender-share calculator. worstBorrowerBps = 10000 - flatRate.
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flatRate;
    constructor(uint256 _flatRate) { flatRate = _flatRate; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flatRate; }
}

/**
 * @title DynamicFeesVaultDepositRewardsCapTest
 * @notice Part A behavior tests for depositRewards' cap-the-pull.
 *
 *  Part A: after settling the depositor, depositRewards computes
 *      worstBorrowerBps = 10000 - getVaultRatioBps(10000)   // smallest borrower credit fraction
 *      retain          = min(amount, ceilDiv(debt * 10000, worstBorrowerBps))  // debt read AFTER settle
 *  and pulls in only `retain`. The excess stays in the depositor's wallet.
 *  Emits RewardsDepositCapped(borrower, requested, retained) when retain < amount.
 *  Returns early (no pull, no stream) when retain == 0.
 */
contract DynamicFeesVaultDepositRewardsCapTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactory public portfolioFactory;

    address public owner = address(0x1);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_3 = 3 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;

    uint256 constant LP_DEPOSIT = 100_000e6;

    event RewardsDepositCapped(address indexed borrower, uint256 requested, uint256 retained);
    event RewardsMinted(address indexed to, uint256 amount);

    function setUp() public {
        vm.warp(EPOCH_2);

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

        // Fund the vault with LP liquidity so utilization stays low (real FeeCalculator).
        usdc.mint(address(this), LP_DEPOSIT);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(LP_DEPOSIT, address(this));
    }

    function _useFlatCalculator(uint256 lenderRateBps) internal {
        FlatFeeCalculator calc = new FlatFeeCalculator(lenderRateBps);
        vm.prank(owner);
        vault.setFeeCalculator(address(calc));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ----------------------------------------------------------------------
    // Test 1: Cap fires (deposit >> debt). Real FeeCalculator curve.
    // ----------------------------------------------------------------------
    function test_depositRewards_capFires_pullsOnlyRetain() public {
        // Real curve. At max utilization the lender share is 9500 bps, so
        // worstBorrowerBps = 500. The cap bites for deposits above ~20x debt.
        uint256 debt = 10e6;
        uint256 deposit = 1000e6; // 100x debt -> well above the ~20x threshold

        vm.prank(alice);
        vault.borrowFromPortfolio(debt);

        // worstBorrowerBps derived live from the production calculator, then asserted.
        uint256 worstBorrowerBps = 10000 - vault.getVaultRatioBps(10000);
        assertEq(worstBorrowerBps, 500, "worstBorrowerBps must equal live 10000 - getVaultRatioBps(10000)");

        uint256 expectedRetain = Math.ceilDiv(debt * 10000, worstBorrowerBps);
        assertEq(expectedRetain, 200e6, "retain = ceilDiv(10e6*10000, 500) = 200e6");
        assertLt(expectedRetain, deposit, "cap must bite (retain < amount)");

        _fund(alice, deposit);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 unsettledBefore = vault.getTotalUnsettledRewards();

        // RewardsDepositCapped(alice, requested=deposit, retained=expectedRetain)
        vm.expectEmit(true, false, false, true, address(vault));
        emit RewardsDepositCapped(alice, deposit, expectedRetain);

        vm.prank(alice);
        vault.depositRewards(deposit);

        uint256 pulled = usdc.balanceOf(address(vault)) - vaultBalBefore;
        uint256 refundKept = usdc.balanceOf(alice) - (aliceBalBefore - deposit); // deposit not spent

        console.log("worstBorrowerBps :", worstBorrowerBps);
        console.log("expectedRetain   :", expectedRetain);
        console.log("vault pulled     :", pulled);
        console.log("depositor kept   :", aliceBalBefore - usdc.balanceOf(alice));

        assertEq(pulled, expectedRetain, "vault USDC balance delta must equal retain");
        assertEq(usdc.balanceOf(alice), aliceBalBefore - expectedRetain, "depositor only spends retain");
        assertEq(refundKept, deposit - expectedRetain, "depositor keeps amount - retain");
        assertEq(
            vault.getTotalUnsettledRewards() - unsettledBefore,
            expectedRetain,
            "totalUnsettledRewards delta must equal retain"
        );
    }

    // ----------------------------------------------------------------------
    // Test 2: Cap does NOT fire (deposit <= threshold). No event, full pull.
    // ----------------------------------------------------------------------
    function test_depositRewards_belowThreshold_noCapFullPull() public {
        uint256 debt = 10e6;
        // worstBorrowerBps=500 -> threshold retain = 20x debt = 200e6. Deposit below it.
        uint256 deposit = 150e6;

        vm.prank(alice);
        vault.borrowFromPortfolio(debt);

        uint256 worstBorrowerBps = 10000 - vault.getVaultRatioBps(10000);
        uint256 cap = Math.ceilDiv(debt * 10000, worstBorrowerBps);
        assertGe(cap, deposit, "deposit must be below the cap so retain == amount");

        _fund(alice, deposit);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 unsettledBefore = vault.getTotalUnsettledRewards();

        // Record logs and assert RewardsDepositCapped was NOT emitted.
        vm.recordLogs();
        vm.prank(alice);
        vault.depositRewards(deposit);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 cappedSig = keccak256("RewardsDepositCapped(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != cappedSig, "RewardsDepositCapped must NOT be emitted below threshold");
        }

        uint256 pulled = usdc.balanceOf(address(vault)) - vaultBalBefore;
        assertEq(pulled, deposit, "full deposit pulled when below cap");
        assertEq(
            vault.getTotalUnsettledRewards() - unsettledBefore,
            deposit,
            "totalUnsettledRewards delta equals full deposit"
        );
    }

    // ----------------------------------------------------------------------
    // Test 3: Debt cleared by in-function settlement -> early return (retain==0).
    // ----------------------------------------------------------------------
    // We use a 0% lender calculator so 100% of a first stream is borrower credit.
    // Alice deposits a first stream sized exactly to her debt; by the time it has
    // fully vested, a second depositRewards call settles her debt to zero, so the
    // cap computes retain = ceilDiv(0 * 10000, 10000) = 0 and returns early.
    function test_depositRewards_debtClearedBySettle_earlyReturn() public {
        _useFlatCalculator(0); // 0% lender -> worstBorrowerBps = 10000, 100% borrower credit

        // Debt chosen as an exact multiple of the epoch duration (WEEK = 604800s) so
        // the streamed rate (debt/duration) re-multiplies back to exactly `debt` with
        // zero floor-division dust -- the vested borrower credit then clears the debt
        // to precisely zero, which is what drives retain == 0 on the second deposit.
        uint256 debt = 604800 * 10; // 6_048_000
        vm.prank(alice);
        vault.borrowFromPortfolio(debt);

        // First stream: capped to debt under 0% lender (retain == debt). The cap pulls
        // exactly `debt`, streamed at rate = debt/WEEK = 10/sec with no remainder.
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.depositRewards(100e6); // retain == debt == 6_048_000

        assertEq(vault.getDebtBalance(alice), debt, "debt unchanged before vesting");

        // Advance past the stream's period finish so the full borrower credit vests.
        // Do NOT pre-settle: stored debt must still be > 0 at function entry so the
        // require(debtBalance > 0) guard passes, and the in-function _settleRewards is
        // what clears it to zero -- driving retain == 0 and the early return.
        vm.warp(EPOCH_3);

        // Sanity: effective debt is now zero (vesting fully credited), but the STORED
        // debt is still nonzero until a state-changing settle runs.
        assertEq(vault.getEffectiveDebtBalance(alice), 0, "effective debt cleared by vested credit");
        assertEq(vault.getDebtBalance(alice), debt, "stored debt still nonzero pre-settle (guard passes)");

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        // Second depositRewards: _settleRewards inside clears the debt to zero, so the
        // cap computes retain = ceilDiv(0 * 10000, worstBorrowerBps) = 0 -> early return.
        // No revert, no USDC pulled, no new stream created.
        vm.prank(alice);
        vault.depositRewards(50e6);

        assertEq(vault.getDebtBalance(alice), 0, "in-function settle cleared the debt to zero");
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore, "no USDC pulled on retain==0 early return");
        assertEq(usdc.balanceOf(alice), aliceBalBefore, "depositor keeps full amount on early return");
        // No NEW stream: the expired stream is zeroed by settlement and the early
        // return adds nothing, so the depositor has no live reward rate.
        assertEq(vault.getPendingRewards(alice), 0, "no live stream after early return");
    }

    // ----------------------------------------------------------------------
    // Test 4: Debt-growth safety. Cap sized to earlier (smaller) debt; borrower
    // borrows more same epoch. Vault must never be short; settlement correct.
    // ----------------------------------------------------------------------
    function test_depositRewards_capThenBorrowMore_vaultNeverShort() public {
        uint256 debt1 = 10e6;
        vm.prank(alice);
        vault.borrowFromPortfolio(debt1);

        uint256 worstBorrowerBps = 10000 - vault.getVaultRatioBps(10000);
        uint256 expectedRetain = Math.ceilDiv(debt1 * 10000, worstBorrowerBps); // 200e6

        // Over-deposit; cap retains 200e6, sized to the 10e6 debt only.
        _fund(alice, 1000e6);
        vm.prank(alice);
        vault.depositRewards(1000e6);

        assertEq(vault.getTotalUnsettledRewards(), expectedRetain, "retain sized to earlier debt");

        // Borrow more in the SAME epoch. New debt is separately collateralized;
        // the existing stream is unchanged by the new borrow.
        uint256 debt2 = 500e6;
        vm.prank(alice);
        vault.borrowFromPortfolio(debt2);

        assertEq(vault.getDebtBalance(alice), debt1 + debt2, "total debt = debt1 + debt2 (no premature credit)");

        // Advance to epoch end and settle everything.
        vm.warp(EPOCH_3);
        vault.settleRewards(alice);

        // Solvency invariant: liquid USDC + outstanding debt owed to vault >=
        // obligations the vault owes (LP claims via totalAssets + escrow).
        uint256 liquid = usdc.balanceOf(address(vault));
        uint256 outstanding = vault.getTotalDebtBalance();
        uint256 obligations = vault.totalAssets() + vault.escrowedExcessTotal();

        console.log("liquid          :", liquid);
        console.log("outstanding debt:", outstanding);
        console.log("totalAssets     :", vault.totalAssets());
        console.log("escrowedTotal   :", vault.escrowedExcessTotal());

        assertGe(liquid + outstanding, obligations, "vault must never be short (cash + receivables >= obligations)");

        // The 200e6 of borrower credit vested fully (real curve borrower share),
        // so debt should be reduced but never below zero and never negative-tracked.
        assertLe(vault.getDebtBalance(alice), debt1 + debt2, "debt cannot exceed what was borrowed");
    }

    // ----------------------------------------------------------------------
    // Test 5: totalAssets (NAV) invariant with NONZERO premium (real curve).
    // ----------------------------------------------------------------------
    function test_depositRewards_totalAssetsInvariant_realCurve() public {
        // Real FeeCalculator: at low util lender share is ~2000 bps so premium is nonzero.
        uint256 debt = 5_000e6;
        vm.prank(alice);
        vault.borrowFromPortfolio(debt);

        // Over-deposit so the cap fires under the real curve.
        uint256 deposit = 200_000e6;
        _fund(alice, deposit);
        vm.prank(alice);
        vault.depositRewards(deposit);

        // NAV right after the (capped) deposit. Capping leaves the excess in the
        // wallet, so the deposit must not move NAV beyond floor-division dust.
        uint256 navAfterDeposit = vault.totalAssets();

        // Advance partway through the epoch and settle: NAV must be invariant
        // across the vesting -> settlement window (premium + borrower credit just
        // move between buckets; total NAV unchanged modulo dust).
        uint256 mid = EPOCH_2 + (WEEK / 2);
        vm.warp(mid);
        uint256 navMidPre = vault.totalAssets();
        vault.settleRewards(alice);
        uint256 navMidPost = vault.totalAssets();

        // Cross the epoch boundary and settle again.
        vm.warp(EPOCH_3);
        uint256 navEndPre = vault.totalAssets();
        vault.settleRewards(alice);
        vault.sync();
        uint256 navEndPost = vault.totalAssets();

        console.log("navAfterDeposit :", navAfterDeposit);
        console.log("navMidPre       :", navMidPre);
        console.log("navMidPost      :", navMidPost);
        console.log("navEndPre       :", navEndPre);
        console.log("navEndPost      :", navEndPost);

        // Settlement does not change NAV (only reclassifies buckets). Tolerance for
        // floor-division dust accumulation across multiple vesting steps.
        assertApproxEqAbs(navMidPre, navMidPost, 50, "NAV invariant across mid-epoch settlement");
        assertApproxEqAbs(navEndPre, navEndPost, 50, "NAV invariant across epoch-end settlement");
    }

    // ----------------------------------------------------------------------
    // Test 6: ceilDiv rounds toward the vault (retain rounded UP, never down).
    // ----------------------------------------------------------------------
    function test_depositRewards_retainRoundsUp() public {
        // Pick a lender share so that debt*10000 / worstBorrowerBps is non-integer.
        // flatRate = 3333 -> worstBorrowerBps = 6667. debt = 10e6:
        //   10e6 * 10000 = 1e11; 1e11 / 6667 = 14_999_250.03... -> ceil = 14_999_251
        _useFlatCalculator(3333);

        uint256 debt = 10e6;
        vm.prank(alice);
        vault.borrowFromPortfolio(debt);

        uint256 worstBorrowerBps = 10000 - vault.getVaultRatioBps(10000);
        assertEq(worstBorrowerBps, 6667, "worstBorrowerBps = 10000 - 3333");

        uint256 numerator = debt * 10000;
        uint256 floorRetain = numerator / worstBorrowerBps;
        uint256 ceilRetain = Math.ceilDiv(numerator, worstBorrowerBps);
        assertEq(ceilRetain, floorRetain + 1, "non-integer division -> ceil is floor + 1");

        // Deposit above the cap so it bites and retain == ceilRetain exactly.
        uint256 deposit = 100e6;
        assertGt(deposit, ceilRetain, "deposit must exceed the cap");
        _fund(alice, deposit);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(true, false, false, true, address(vault));
        emit RewardsDepositCapped(alice, deposit, ceilRetain);

        vm.prank(alice);
        vault.depositRewards(deposit);

        uint256 pulled = usdc.balanceOf(address(vault)) - vaultBalBefore;

        console.log("worstBorrowerBps:", worstBorrowerBps);
        console.log("floorRetain     :", floorRetain);
        console.log("ceilRetain      :", ceilRetain);
        console.log("pulled          :", pulled);

        assertEq(pulled, ceilRetain, "retain must round UP (toward the vault), never down");
        assertGt(pulled, floorRetain, "retain strictly greater than floor division");
    }
}
