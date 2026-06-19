// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// REPRODUCTION (failing) test for a maxWithdraw / maxRedeem over-withdrawal
// bug in DynamicFeesVault.
//
// THE BUG
// -------
// `maxWithdraw(owner)` (L1074) and `maxRedeem(owner)` (L1091) cap a lender's
// exit at:
//     uint256 liquid = IERC20(asset()).balanceOf(address(this));
// i.e. the RAW asset balance of the vault.
//
// But the raw balance includes funds that are NOT free lender liquidity.
// `totalAssets()` (via `_totalAssetsRaw`, L435-438) already deducts these as
// liabilities:
//     deductions = _getUnvestedLenderPremium()
//                + $.totalUnsettledRewards
//                + excessPendingOwedToBorrowers
//                + $.escrowedExcessTotal;
//
// `escrowedExcessTotal` is cash physically sitting in the vault that is OWED
// to a borrower (a reward-excess payout that failed to transfer, e.g. USDC
// blacklist, and got escrowed). It is a third-party liability, not lender
// liquidity. The borrower reclaims it later via `claimEscrow()`.
//
// Because maxWithdraw/maxRedeem cap on the RAW balance rather than
// (rawBalance - escrowedExcessTotal - other earmarks), a lender is permitted
// to withdraw INTO the escrowed cash. The lender can drain funds the vault
// owes to a borrower, leaving the vault unable to honor `claimEscrow()`.
//
// WHAT THESE TESTS PROVE
// ----------------------
// True free liquidity = rawBalance - escrowedExcessTotal.
//   - PRIMARY: maxWithdraw(lp) > freeLiquidity   (cap ignores the earmark)
//   - PRIMARY: maxRedeem-in-assets > freeLiquidity
//   - END-TO-END HARM: after lp withdraws maxWithdraw, the vault's remaining
//     balance < escrowedExcessTotal, so the (un-blacklisted) borrower's
//     claimEscrow() can no longer be honored -> reverts on transfer.
//
// These tests are EXPECTED TO FAIL on current code (the asserts encode the
// buggy current behavior as the failing condition where appropriate, and the
// harm test reverts). The future fix makes maxWithdraw/maxRedeem cap on free
// liquidity, after which the PRIMARY asserts flip and the harm test passes.
//
// NO FIX is included. NO existing test is modified.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

// =====================================================================
// Mocks (mirrored from DynamicFeesVaultEscrowAccounting.t.sol)
// =====================================================================

contract MockUSDCWithBlacklist is ERC20 {
    mapping(address => bool) public blacklisted;
    enum FailMode { ReturnFalse, Revert }
    FailMode public failMode;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setBlacklisted(address user, bool b) external { blacklisted[user] = b; }

    function setFailMode(FailMode m) external { failMode = m; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blacklisted[to]) {
            if (failMode == FailMode.Revert) revert("blacklisted");
            return false;
        }
        return super.transfer(to, amount);
    }
}

contract MockPortfolioFactoryMaxWithdraw is IPortfolioFactory {
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

/// @dev Pinned 20% lender ratio: 80% of vested rewards reduce debt, 20% lender premium.
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// =====================================================================
// Test
// =====================================================================

contract DynamicFeesVaultMaxWithdrawEscrowTest is Test {
    DynamicFeesVault public vault;
    MockUSDCWithBlacklist public usdc;
    MockPortfolioFactoryMaxWithdraw public portfolioFactory;

    // The LP is `address(this)` (it deposits SEED in setUp, like the sibling harness).
    address public lp; // == address(this)
    address public owner = address(0xA1);
    address public borrower = address(0xB1);
    address public feeRecipient = address(0xFEE);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    uint256 constant SEED    = 10_000e6;
    uint256 constant BORROW  = 100e6;
    uint256 constant REWARDS = 500e6; // > BORROW so excess > 0 after debt cleared
    uint256 constant FEE_BPS = 0;

    function setUp() public {
        lp = address(this);
        vm.warp(EPOCH_2);

        usdc = new MockUSDCWithBlacklist();
        portfolioFactory = new MockPortfolioFactoryMaxWithdraw();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC",
            address(portfolioFactory), feeRecipient, FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));

        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        FlatFeeCalculator fc = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));

        // LP (this contract) supplies liquidity.
        usdc.mint(lp, SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, lp);
    }

    // Build escrowed-excess state: borrower borrows, deposits a large reward
    // stream, time fully vests it, borrower is blacklisted, settlement routes
    // the excess into escrow (cash stays in the vault, owed to borrower).
    function _setupEscrow() internal {
        vm.prank(borrower);
        vault.borrowFromPortfolio(BORROW);

        vm.startPrank(borrower);
        usdc.mint(borrower, REWARDS);
        usdc.approve(address(vault), REWARDS);
        vault.depositRewards(REWARDS);
        vm.stopPrank();

        vm.warp(EPOCH_5);

        usdc.setFailMode(MockUSDCWithBlacklist.FailMode.ReturnFalse);
        usdc.setBlacklisted(borrower, true);
        vault.settleRewards(borrower);

        // Move past the LP's deposit block so maxWithdraw isn't gated to 0.
        vm.roll(block.number + 1);
    }

    // =================================================================
    // END-TO-END HARM (escrow vector): the lender's withdrawal drains funds
    // earmarked for a borrower's escrow, and the borrower then OVER-claims.
    //
    // In this state the sole LP's share entitlement (== totalAssets == SEED)
    // is the binding cap on maxWithdraw, and it sits just below rawBalance, so
    // maxWithdraw returns the full SEED entitlement. The LP withdraws all of
    // it. The cash left behind (which the buggy accounting treated as fully
    // free) is then handed to the borrower via claimEscrow -- but it includes
    // the borrowed principal that should have backed the lenders' shares, so
    // the borrower walks away with MORE than they were escrowed.
    //
    // FAILS on current code: borrower receives owed + leaked principal
    // (399999999) instead of the escrowed amount (299999999).
    // =================================================================
    function test_lenderDrainsEscrowedFunds_borrowerCannotClaim() public {
        _setupEscrow();

        uint256 escrow = vault.escrowedExcessTotal();
        uint256 owedToBorrower = vault.escrowedExcessOf(borrower);
        assertGt(escrow, 0, "precondition: escrow must exist");
        assertEq(escrow, owedToBorrower, "single-borrower escrow");

        uint256 maxW = vault.maxWithdraw(lp);

        // Accounting snapshot before the lender exits.
        uint256 rawBefore = usdc.balanceOf(address(vault));
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 lpEntitlement = vault.convertToAssets(vault.balanceOf(lp));
        emit log_named_uint("rawBalance before  ", rawBefore);
        emit log_named_uint("totalAssets() before", totalAssetsBefore);
        emit log_named_uint("lp share entitlement", lpEntitlement);
        emit log_named_uint("escrowedExcessTotal ", escrow);
        emit log_named_uint("true free liquidity ", rawBefore - escrow);
        emit log_named_uint("maxWithdraw(lp)     ", maxW);

        // Lender withdraws the maximum the (buggy) vault permits.
        vault.withdraw(maxW, lp, lp);

        emit log_named_uint("withdrawn by lp   ", maxW);
        emit log_named_uint("owedToBorrower    ", owedToBorrower);
        emit log_named_uint("vault balance left", usdc.balanceOf(address(vault)));

        // After the LP's max exit the escrow must remain fully claimable: the
        // free-liquidity cap stops the LP from draining the escrowed cash. Measure
        // the claim delta (the borrower's wallet already holds unrepaid loan
        // principal, which is not part of the escrow claim).
        usdc.setBlacklisted(borrower, false);
        uint256 borrowerBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vault.claimEscrow();
        assertEq(
            usdc.balanceOf(borrower) - borrowerBefore,
            owedToBorrower,
            "borrower must be able to claim exactly the escrowed amount after the LP exit"
        );
    }

    // =================================================================
    // CLEAN ISOLATION of the raw-balance-cap bug via the unvested lender
    // premium earmark (the fallback vector named in the task).
    //
    // State:
    //   - sole LP holds all shares (SEED entitlement)
    //   - a borrower borrows D, so D of cash is loaned out: rawBalance falls
    //     to SEED-D, but NAV still counts the outstanding D as debt -> LP
    //     entitlement stays ~= SEED
    //   - incentivize(P) at the epoch boundary injects P of cash that is NOT
    //     yet in NAV (fully unvested) -> rawBalance = SEED-D+P, totalAssets
    //     unchanged (P is deducted as _getUnvestedLenderPremium())
    //
    // True free liquidity = rawBalance - unvestedPremium = SEED-D.
    //
    // The bug: maxWithdraw caps at `liquid = rawBalance` = SEED-D+P, while the
    // LP entitlement ~= SEED > rawBalance, so maxWithdraw returns rawBalance =
    // SEED-D+P -- which exceeds free liquidity by P. The lender can withdraw
    // straight into the unvested premium.
    //
    // FAILS on current code: assertLe(maxW, free) fails by ~P.
    // =================================================================
    function test_maxWithdraw_exceedsFreeLiquidity_withUnvestedPremium() public {
        uint256 D = 4_000e6; // borrow, leaves cash below entitlement
        uint256 P = 2_000e6; // incentive premium (unvested at epoch boundary)

        vm.prank(borrower);
        vault.borrowFromPortfolio(D);

        // incentivize at the current epoch boundary (block.timestamp == EPOCH_2,
        // an exact WEEK multiple) so elapsed == 0 and the premium is fully
        // unvested -> counted in rawBalance, deducted from totalAssets().
        usdc.mint(address(this), P);
        usdc.approve(address(vault), P);
        vault.incentivize(P);

        // Past the LP's deposit block (no time advance: premium stays unvested).
        vm.roll(block.number + 1);

        uint256 unvested = vault.getUnvestedLenderPremium();
        assertEq(unvested, P, "premium fully unvested at epoch boundary");

        uint256 rawBalance = usdc.balanceOf(address(vault));
        uint256 free = rawBalance - unvested; // true free lender liquidity
        uint256 entitlement = vault.convertToAssets(vault.balanceOf(lp));
        uint256 maxW = vault.maxWithdraw(lp);

        emit log_named_uint("rawBalance          ", rawBalance);
        emit log_named_uint("unvestedLenderPremium", unvested);
        emit log_named_uint("freeLiquidity       ", free);
        emit log_named_uint("lp entitlement (NAV)", entitlement);
        emit log_named_uint("maxWithdraw(lp)     ", maxW);

        // Sanity: entitlement exceeds raw balance, so the raw-balance cap is the
        // binding constraint (this is what makes the bug observable).
        assertGt(entitlement, rawBalance, "entitlement should exceed cash (debt outstanding)");

        // PRIMARY (encodes the fix): a lender must never withdraw past free
        // liquidity. Current buggy code returns maxW == rawBalance > free.
        assertLe(
            maxW,
            free,
            "maxWithdraw must not exceed free liquidity (rawBalance - unvested premium)"
        );
    }

    // =================================================================
    // Mirror of the above for maxRedeem (shares -> assets) under the unvested
    // premium earmark. FAILS on current code.
    // =================================================================
    function test_maxRedeem_exceedsFreeLiquidity_withUnvestedPremium() public {
        uint256 D = 4_000e6;
        uint256 P = 2_000e6;

        vm.prank(borrower);
        vault.borrowFromPortfolio(D);

        usdc.mint(address(this), P);
        usdc.approve(address(vault), P);
        vault.incentivize(P);

        vm.roll(block.number + 1);

        uint256 unvested = vault.getUnvestedLenderPremium();
        uint256 rawBalance = usdc.balanceOf(address(vault));
        uint256 free = rawBalance - unvested;

        uint256 maxShares = vault.maxRedeem(lp);
        uint256 assetsOut = vault.previewRedeem(maxShares);

        emit log_named_uint("rawBalance          ", rawBalance);
        emit log_named_uint("unvestedLenderPremium", unvested);
        emit log_named_uint("freeLiquidity       ", free);
        emit log_named_uint("maxRedeem(lp)       ", maxShares);
        emit log_named_uint("previewRedeem(max)  ", assetsOut);

        assertLe(
            assetsOut,
            free,
            "maxRedeem (in assets) must not exceed free liquidity"
        );
    }
}
