// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// DynamicFeesVault -- conservative outstanding-capital read for borrow caps
// ============================================================================
//
// SEPARATE-GETTER DESIGN (what is pinned here)
// --------------------------------------------
// DynamicFeesVault exposes two outstanding-capital reads:
//
//   activeAssets()             (src/.../DynamicFeesVault.sol:971) -- UNCHANGED.
//       totalLoanedAssets - (totalVestedRewardsApplied + globalBorrowerPending)   (saturating at 0)
//       Subtracts the FULL globalBorrowerPending. This is the NAV-facing read:
//       Vault / VaultV2 NAV math depends on it, so it intentionally stays
//       understated by unsettled borrower credit and is NOT changed by this fix.
//
//   activeAssetsConservative() (src/.../DynamicFeesVault.sol:983) -- NEW.
//       totalLoanedAssets - totalVestedRewardsApplied                             (saturating at 0)
//       IGNORES unsettled globalBorrowerPending. Its result only ever
//       OVER-states outstanding (never under-states), so a borrow-cap consumer
//       reading it sees headroom that is only ever too small, never too large.
//
// WHY TWO READS
// -------------
// During the pre-settlement window, globalBorrowerPending is borrower reward
// credit that has vested globally but is NOT yet settled per-borrower. Part of
// it will extinguish principal; part may be paid out to borrowers as excess.
// Subtracting all of it (activeAssets) under-reports capital still outstanding.
// Feeding that under-reported figure into a borrow cap would INFLATE available
// headroom and over-grant borrow capacity. The fix routes the borrow cap
// through activeAssetsConservative() instead, while leaving activeAssets()
// alone for NAV.
//
// WHERE THE CONSERVATIVE READ IS CONSUMED
// ---------------------------------------
// DynamicCollateralManager.getMaxLoan (src/.../DynamicCollateralManager.sol:262)
// reads `outstandingCapital = IDynamicLendingPool(address(lendingPool)).activeAssetsConservative()`
// and passes it to getMaxLoanByRewardsRate, which computes
//     vaultAvailableSupply = maxUtilization - outstandingCapital
// A larger (conservative) outstandingCapital yields a SMALLER vaultAvailableSupply
// -> a TIGHTER cap. DynamicYieldBasisCollateralManager and
// DynamicHydrexCollateralManager read the same getter via the same hard cast.
//
// Level used: FOCUSED VAULT INVARIANT (not full manager e2e). Justification:
// activeAssetsConservative() is the exact getter the managers consume; the
// existing DynamicFeesVaultBorrowDrift harness proves this minimal standalone
// vault reliably builds globalBorrowerPending > 0 via real reward streaming;
// full DynamicCollateralManager + PortfolioFactoryConfig + LoanConfig +
// veNFT-collateral wiring would produce an identical signal at much higher
// setup cost.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";
import {IDynamicLendingPool} from "../../../src/interfaces/IDynamicLendingPool.sol";

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

// Minimal contract WITHOUT activeAssetsConservative(). Used to pin that the hard
// cast IDynamicLendingPool(address(x)).activeAssetsConservative() reverts when the
// backing contract does not implement the selector.
contract MissingConservativeReadStub {
    // Implements an unrelated function so the contract has code; deliberately
    // omits activeAssetsConservative().
    function activeAssets() external pure returns (uint256) { return 0; }
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
    // TASK 1: activeAssetsConservative() excludes unsettled borrower credit.
    //
    // In the pre-settlement state (globalBorrowerPending > 0):
    //   - activeAssetsConservative() == totalLoaned - vestedApplied (the safe,
    //     over-stated figure; totalLoaned > vestedApplied holds here).
    //   - activeAssetsConservative() > activeAssets() (proves the conservative
    //     read ignores the unsettled pending that activeAssets() subtracts).
    //   - the gap equals exactly globalBorrowerPending (since
    //     vestedApplied + pending <= totalLoaned, neither read saturates).
    // =========================================================================
    function test_activeAssetsConservative_excludesUnsettledBorrowerCredit() public {
        _buildPreSettlementState();

        uint256 totalLoaned = vault.totalLoanedAssets();
        uint256 vestedApplied = vault.totalVestedRewardsApplied();
        uint256 globalPending = vault.getGlobalBorrowerPending();
        uint256 active = vault.activeAssets();
        uint256 conservative = vault.activeAssetsConservative();

        emit log_named_uint("totalLoanedAssets        ", totalLoaned);
        emit log_named_uint("totalVestedRewardsApplied", vestedApplied);
        emit log_named_uint("globalBorrowerPending    ", globalPending);
        emit log_named_uint("activeAssets()           ", active);
        emit log_named_uint("activeAssetsConservative ", conservative);

        // Precondition: unsettled borrower credit must be live for this to matter.
        assertGt(globalPending, 0, "precondition: unsettled globalBorrowerPending must be > 0");
        // Precondition: neither read saturates at 0 in this scenario.
        assertGt(totalLoaned, vestedApplied, "precondition: totalLoaned > vestedApplied (conservative does not saturate)");

        // Conservative read == the safe / over-stated figure (no pending subtracted).
        assertEq(
            conservative,
            totalLoaned - vestedApplied,
            "activeAssetsConservative() == totalLoaned - totalVestedRewardsApplied"
        );

        // Conservative read strictly exceeds activeAssets(): it excludes the
        // unsettled pending that activeAssets() subtracts.
        assertGt(
            conservative,
            active,
            "activeAssetsConservative() must exceed activeAssets() (excludes unsettled pending)"
        );

        // Sharpened proof: the gap equals exactly the unsettled globalBorrowerPending.
        // Holds because totalReduction (vestedApplied + pending) <= totalLoaned here,
        // so activeAssets() = totalLoaned - vestedApplied - pending and the difference is pending.
        assertEq(
            conservative - active,
            globalPending,
            "gap between conservative and activeAssets() equals unsettled globalBorrowerPending"
        );
    }

    // =========================================================================
    // TASK 2: manager-plumbing signal -- conservative read yields a TIGHTER cap.
    //
    // DynamicCollateralManager.getMaxLoan:262 sets
    //     outstandingCapital = IDynamicLendingPool(lendingPool).activeAssetsConservative()
    // and getMaxLoanByRewardsRate computes
    //     vaultAvailableSupply = maxUtilization - outstandingCapital.
    //
    // A larger (conservative) outstandingCapital -> a SMALLER vaultAvailableSupply
    // -> a tighter cap. This vault-level proof is sufficient because the manager
    // reads THIS EXACT getter: the full DynamicCollateralManager +
    // PortfolioFactoryConfig + LoanConfig e2e wiring produces an identical signal
    // (a smaller vaultAvailableSupply when fed the conservative read) at much
    // higher setup cost. Here we assert the headroom subtraction directly on the
    // two getters.
    // =========================================================================
    function test_getMaxLoanInput_conservativeReadYieldsTighterHeadroom() public {
        _buildPreSettlementState();

        uint256 active = vault.activeAssets();
        uint256 conservative = vault.activeAssetsConservative();
        uint256 globalPending = vault.getGlobalBorrowerPending();

        // Precondition: the two reads must actually differ (drift is live).
        assertGt(globalPending, 0, "precondition: unsettled globalBorrowerPending must be > 0");
        assertGt(conservative, active, "precondition: conservative read exceeds activeAssets()");

        // Pick a maxUtilization >= conservative so neither subtraction underflows,
        // mirroring getMaxLoanByRewardsRate's `maxUtilization - outstandingCapital`.
        uint256 maxUtilization = conservative + 1_000e6;

        // Headroom the manager WOULD consume (conservative read) vs. headroom the
        // understated activeAssets() read would have produced.
        uint256 headroomConservative = maxUtilization - conservative;
        uint256 headroomUnderstated = maxUtilization - active;

        emit log_named_uint("maxUtilization                 ", maxUtilization);
        emit log_named_uint("activeAssets()                 ", active);
        emit log_named_uint("activeAssetsConservative       ", conservative);
        emit log_named_uint("headroom from conservative read", headroomConservative);
        emit log_named_uint("headroom from activeAssets read", headroomUnderstated);

        // The conservative read produces a strictly SMALLER vaultAvailableSupply
        // -> a tighter cap -> never over-grants during the pre-settlement window.
        assertLt(
            headroomConservative,
            headroomUnderstated,
            "conservative read yields smaller vaultAvailableSupply (tighter cap) than understated activeAssets()"
        );

        // The headroom reduction equals exactly the unsettled pending.
        assertEq(
            headroomUnderstated - headroomConservative,
            globalPending,
            "headroom tightening equals the unsettled globalBorrowerPending excluded by the conservative read"
        );
    }

    // =========================================================================
    // TASK 3: hard-cast wiring invariant.
    //
    // The managers perform a hard cast
    //   IDynamicLendingPool(address(lendingPool)).activeAssetsConservative().
    // Pin that:
    //   (a) the cast resolves on the backing DynamicFeesVault (selector present)
    //       and returns the expected value, and
    //   (b) hard-casting a contract WITHOUT the selector and calling it reverts.
    //       This proves the cast genuinely requires the method to exist -- a
    //       switched lendingPool that is not a DynamicFeesVault would break
    //       getMaxLoan loudly rather than silently mis-price.
    // =========================================================================
    function test_hardCast_activeAssetsConservative_resolvesOnBackingVault() public {
        _buildPreSettlementState();

        uint256 expected = vault.activeAssetsConservative();

        // (a) Hard cast on the real vault resolves and matches.
        uint256 viaCast = IDynamicLendingPool(address(vault)).activeAssetsConservative();
        assertEq(viaCast, expected, "hard cast on DynamicFeesVault resolves to the conservative read");

        emit log_named_uint("activeAssetsConservative via cast", viaCast);
    }

    function test_hardCast_activeAssetsConservative_revertsWhenSelectorMissing() public {
        // (b) A contract WITHOUT the selector, hard-cast and called, reverts.
        MissingConservativeReadStub stub = new MissingConservativeReadStub();
        vm.expectRevert();
        IDynamicLendingPool(address(stub)).activeAssetsConservative();
    }
}
