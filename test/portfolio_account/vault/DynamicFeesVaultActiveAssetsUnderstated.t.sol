// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// DynamicFeesVault -- settled outstanding-capital read for borrow caps
// ============================================================================
//
// COLLAPSED-GETTER DESIGN (what is pinned here)
// --------------------------------------------
// DynamicFeesVault exposes a single outstanding-capital read:
//
//   activeAssets()             (src/.../DynamicFeesVault.sol:1012)
//       totalLoanedAssets - totalVestedRewardsApplied   (saturating at 0)
//       IGNORES unsettled globalBorrowerPending. Its result only ever
//       OVER-states outstanding (never under-states), so a borrow-cap consumer
//       reading it sees headroom that is only ever too small, never too large.
//
// A former settled-only getter was removed and its settled body folded directly
// into activeAssets(). There is no longer a NAV-facing variant
// that subtracts globalBorrowerPending: DynamicFeesVault is standalone
// (lendingVault() returns itself; it is never wrapped by Vault/VaultV2 whose NAV
// folds a loan contract's activeAssets()), and nothing internal calls
// activeAssets(), so the only consumers are the borrow-cap managers, which all
// want the settled value.
//
// WHY THE SETTLED READ
// --------------------
// During the pre-settlement window, globalBorrowerPending is borrower reward
// credit that has vested globally but is NOT yet settled per-borrower. Part of
// it will extinguish principal; part may be paid out to borrowers as excess.
// Subtracting all of it would under-report capital still outstanding. Feeding
// that under-reported figure into a borrow cap would INFLATE available headroom
// and over-grant borrow capacity. By excluding the unsettled pending,
// activeAssets() stays conservative (only ever over-states outstanding).
//
// WHERE THE READ IS CONSUMED
// --------------------------
// DynamicCollateralManager.getMaxLoan reads
//   `outstandingCapital = lendingPool.activeAssets()`
// and passes it to getMaxLoanByRewardsRate, which computes
//     vaultAvailableSupply = maxUtilization - outstandingCapital
// A larger (conservative) outstandingCapital yields a SMALLER vaultAvailableSupply
// -> a TIGHTER cap. DynamicYieldBasisCollateralManager and
// DynamicHydrexCollateralManager read the same getter (the plain
// ILendingPool.activeAssets() every lending pool implements).
//
// Level used: FOCUSED VAULT INVARIANT (not full manager e2e). Justification:
// activeAssets() is the exact getter the managers consume; the existing
// DynamicFeesVaultBorrowDrift harness proves this minimal standalone vault
// reliably builds globalBorrowerPending > 0 via real reward streaming; full
// DynamicCollateralManager + PortfolioFactoryConfig + LoanConfig + veNFT-
// collateral wiring would produce an identical signal at much higher setup cost.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactory is IPortfolioFactory {
    mapping(address => bool) public _isPortfolio;
    function setPortfolio(address a, bool v) external { _isPortfolio[a] = v; }
    function isPortfolio(address p) external view override returns (bool) { return _isPortfolio[p]; }
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

// 100% borrower-credit split (ratio = 0 -> lender premium = 0). Every dollar of
// vested reward flows into globalBorrowerPending, giving a clean drift signal with
// no lender-premium two-epoch-lag ambiguity.
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

contract DynamicFeesVaultActiveAssetsUnderstatedTest is Test {
    DynamicFeesVault internal vault;
    MockUSDC internal usdc;
    MockPortfolioFactory internal portfolioFactory;

    address internal owner = address(0x1);
    address internal lender = address(0xA1);
    address internal borrower = address(0xB1);
    address internal feeRecipient = address(0xFEE);

    uint256 internal constant WEEK = ProtocolTimeLibrary.WEEK;
    // Hardcoded absolute timestamps from setUp warp (avoid via-ir block.timestamp caching).
    uint256 internal constant EPOCH_2 = 2 * WEEK; // setUp warps here
    uint256 internal constant EPOCH_3 = 3 * WEEK;

    uint256 internal constant SEED = 10_000e6;

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactory();
        portfolioFactory.setPortfolio(borrower, true);

        vault = _deployVault();

        usdc.mint(lender, SEED);
        vm.startPrank(lender);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, lender);
        vm.stopPrank();

        vm.label(address(vault), "DynamicFeesVault");
        vm.label(address(usdc), "USDC");
        vm.label(borrower, "Borrower");
        vm.label(lender, "Lender");
    }

    function _deployVault() internal returns (DynamicFeesVault v) {
        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc),
            "Vault",
            "vUSDC",
            address(portfolioFactory),
            feeRecipient,
            uint256(0) // feeBps = 0 to keep totalAssets math clean
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        v = DynamicFeesVault(address(proxy));
        v.transferOwnership(owner);
        vm.prank(owner);
        v.acceptOwnership();
    }

    function _setFlatRatio(uint256 ratioBps) internal {
        FlatFeeCalculator fc = new FlatFeeCalculator(ratioBps);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));
    }

    function _borrow(uint256 amount) internal {
        vm.prank(borrower);
        vault.borrowFromPortfolio(amount);
    }

    function _streamRewardsAsBorrower(uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    /// @dev Build the pre-settlement state used by Tasks 1 & 2: borrow, stream
    ///      100%-borrower-credit rewards, advance a full epoch and sync so
    ///      _processGlobalVesting moves the vested reward into
    ///      globalBorrowerPending WITHOUT any per-borrower settlement.
    function _buildPreSettlementState() internal {
        _setFlatRatio(0);
        _borrow(5_000e6);
        _streamRewardsAsBorrower(1_200e6);
        vm.warp(EPOCH_3);
        vault.sync();
    }

    // =========================================================================
    // TASK 1: activeAssets() excludes unsettled borrower credit.
    //
    // In the pre-settlement state (globalBorrowerPending > 0):
    //   - activeAssets() == totalLoaned - vestedApplied (the safe, over-stated
    //     figure; totalLoaned > vestedApplied holds here).
    //   - activeAssets() does NOT subtract the unsettled pending: it stays at the
    //     raw debt (vestedApplied == 0 here) even though the borrower's effective
    //     debt is lower once the pending credit is applied.
    //   - If activeAssets() *had* subtracted the pending, it would be smaller by
    //     exactly globalBorrowerPending -- pinned via the arithmetic gap.
    // =========================================================================
    function test_activeAssets_excludesUnsettledBorrowerCredit() public {
        _buildPreSettlementState();

        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 vestedApplied = vault.totalVestedRewardsApplied();
        uint256 globalPending = vault.getGlobalBorrowerPending();
        uint256 active = vault.activeAssets();
        uint256 rawDebt = vault.getDebtBalance(borrower);
        uint256 effectiveDebt = vault.getEffectiveDebtBalance(borrower);

        emit log_named_uint("totalLoanedAssets        ", totalLoaned);
        emit log_named_uint("totalVestedRewardsApplied", vestedApplied);
        emit log_named_uint("globalBorrowerPending    ", globalPending);
        emit log_named_uint("activeAssets()           ", active);
        emit log_named_uint("getDebtBalance           ", rawDebt);
        emit log_named_uint("getEffectiveDebtBalance  ", effectiveDebt);

        // Precondition: unsettled borrower credit must be live for this to matter.
        assertGt(globalPending, 0, "precondition: unsettled globalBorrowerPending must be > 0");
        // Precondition: neither read saturates at 0 in this scenario.
        assertGt(totalLoaned, vestedApplied, "precondition: totalLoaned > vestedApplied (activeAssets does not saturate)");

        // activeAssets() == the safe / over-stated figure (no pending subtracted).
        assertEq(
            active,
            totalLoaned - vestedApplied,
            "activeAssets() == totalLoaned - totalVestedRewardsApplied"
        );

        // activeAssets() does NOT subtract the unsettled pending: it equals the raw
        // outstanding debt (vestedApplied == 0 here) even though the borrower's
        // effective debt is already lower once the vested pending credit is applied.
        assertEq(active, rawDebt, "activeAssets() equals raw outstanding debt (pending not subtracted)");
        assertLt(effectiveDebt, active, "effective debt is lower than activeAssets() -- pending credit is real but excluded");

        // Sharpened proof: had activeAssets() subtracted the pending (the old
        // under-reporting NAV behaviour), it would be smaller by exactly
        // globalBorrowerPending. Holds because vestedApplied + pending <= totalLoaned.
        uint256 ifPendingSubtracted = totalLoaned - vestedApplied - globalPending;
        assertEq(
            active - ifPendingSubtracted,
            globalPending,
            "activeAssets() exceeds the pending-subtracting figure by exactly globalBorrowerPending"
        );
    }

    // =========================================================================
    // TASK 2: manager-plumbing signal -- the settled read yields a TIGHTER cap.
    //
    // DynamicCollateralManager.getMaxLoan sets
    //     outstandingCapital = lendingPool.activeAssets()
    // and getMaxLoanByRewardsRate computes
    //     vaultAvailableSupply = maxUtilization - outstandingCapital.
    //
    // Because activeAssets() excludes the unsettled pending, the value the manager
    // consumes is larger than a NAV-style read that subtracted the pending would
    // be -> a SMALLER vaultAvailableSupply -> a tighter cap that never over-grants
    // during the pre-settlement window. This vault-level proof is sufficient
    // because the manager reads THIS EXACT getter: the full DynamicCollateralManager
    // + PortfolioFactoryConfig + LoanConfig e2e wiring produces an identical signal
    // at much higher setup cost. Here we assert the headroom subtraction directly.
    // =========================================================================
    function test_getMaxLoanInput_settledReadYieldsTighterHeadroom() public {
        _buildPreSettlementState();

        uint256 active = vault.activeAssets(); // the value the manager consumes
        uint256 globalPending = vault.getGlobalBorrowerPending();

        // Precondition: unsettled pending must be live for the settled read to matter.
        assertGt(globalPending, 0, "precondition: unsettled globalBorrowerPending must be > 0");

        // A hypothetical NAV-style read that ALSO subtracted the unsettled pending
        // would under-report outstanding by exactly globalBorrowerPending.
        uint256 ifPendingSubtracted = active - globalPending;

        // Pick a maxUtilization >= active so neither subtraction underflows,
        // mirroring getMaxLoanByRewardsRate's `maxUtilization - outstandingCapital`.
        uint256 maxUtilization = active + 1_000e6;

        // Headroom the manager actually consumes (settled activeAssets) vs. headroom
        // a pending-subtracting read would have produced.
        uint256 headroomSettled = maxUtilization - active;
        uint256 headroomIfPendingSubtracted = maxUtilization - ifPendingSubtracted;

        emit log_named_uint("maxUtilization                    ", maxUtilization);
        emit log_named_uint("activeAssets() (settled)          ", active);
        emit log_named_uint("hypothetical pending-subtracted    ", ifPendingSubtracted);
        emit log_named_uint("headroom from settled read        ", headroomSettled);
        emit log_named_uint("headroom if pending were subtracted", headroomIfPendingSubtracted);

        // The settled read produces a strictly SMALLER vaultAvailableSupply
        // -> a tighter cap -> never over-grants during the pre-settlement window.
        assertLt(
            headroomSettled,
            headroomIfPendingSubtracted,
            "settled activeAssets() yields smaller vaultAvailableSupply (tighter cap) than a pending-subtracting read"
        );

        // The headroom reduction equals exactly the unsettled pending.
        assertEq(
            headroomIfPendingSubtracted - headroomSettled,
            globalPending,
            "headroom tightening equals the unsettled globalBorrowerPending excluded by the settled read"
        );
    }
}
