// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// DynamicFeesVault — borrow-gate and activeAssets() drift regression tests
// ============================================================================
//
// Pins the recently-applied fix that switches `borrowFromPortfolio`'s
// utilization gate and `activeAssets()` from raw `totalLoanedAssets` to the
// effective form `totalLoanedAssets - (totalVestedRewardsApplied +
// globalBorrowerPending)`.
//
// Without the fix, principal extinguished by reward settlement keeps counting
// as "active", so borrow capacity collapses over time even though the vault is
// mostly liquid -- a self-inflicted borrow DoS.
//
// Each test constructs drift via real reward streaming (no storage poking) and
// asserts a property that would fail under the raw form.
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

contract MockPortfolioFactoryDrift is IPortfolioFactory {
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

contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

contract DynamicFeesVaultBorrowDriftTest is Test {
    DynamicFeesVault internal vault;
    MockUSDC internal usdc;
    MockPortfolioFactoryDrift internal portfolioFactory;

    address internal owner = address(0x1);
    address internal lender = address(0xA1);
    address internal borrower = address(0xB1);
    address internal feeRecipient = address(0xFEE);

    uint256 internal constant WEEK = ProtocolTimeLibrary.WEEK;
    // Hardcoded absolute timestamps from setUp warp (avoid via-ir caching).
    uint256 internal constant EPOCH_2 = 2 * WEEK; // setUp warps here
    uint256 internal constant EPOCH_3 = 3 * WEEK;
    uint256 internal constant EPOCH_4 = 4 * WEEK;
    uint256 internal constant EPOCH_5 = 5 * WEEK;

    // Vault parameters
    uint256 internal constant MAX_UTIL_BPS = 8000;
    uint256 internal constant SEED = 10_000e6;

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryDrift();
        portfolioFactory.setPortfolio(borrower, true);

        vault = _deployVault();

        // Seed the vault with depositor liquidity.
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

    // ============ Helpers ============

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

    /// @dev Set a constant lender/borrower split ratio. 0 = 100% borrower credit,
    ///      2000 = 80% borrower credit / 20% lender premium, etc.
    function _setFlatRatio(uint256 ratioBps) internal {
        FlatFeeCalculator fc = new FlatFeeCalculator(ratioBps);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));
    }

    function _borrow(uint256 amount) internal {
        vm.prank(borrower);
        vault.borrowFromPortfolio(amount);
    }

    /// @dev Stream `amount` of borrower-credit-heavy rewards into the vault.
    function _streamRewardsAsBorrower(uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(vault), amount);
        vault.depositRewards(amount);
        vm.stopPrank();
    }

    /// @dev Read effective debt: $.totalLoanedAssets - (totalVestedRewardsApplied + globalBorrowerPending), saturating at 0.
    function _effectiveLoaned() internal view returns (uint256) {
        uint256 raw = vault.totalLoanedAssets();
        uint256 reduction = vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();
        return raw > reduction ? raw - reduction : 0;
    }

    function _totalReduction() internal view returns (uint256) {
        return vault.totalVestedRewardsApplied() + vault.getGlobalBorrowerPending();
    }

    // =========================================================================
    // 1. Gate: borrow succeeds after rewards have driven reduction up enough that
    //    the raw-form gate would reject, but the effective-form gate accepts.
    // =========================================================================

    function test_borrow_succeedsAfterRewardsSettleDebt_thatRawFormulaWouldReject() public {
        // 100% borrower credit -- no lender premium, no two-epoch lag ambiguity,
        // every dollar of reward flows directly into globalBorrowerPending.
        _setFlatRatio(0);

        // Borrow up near the cap. With SEED=10000 and 80% cap, raw headroom is
        // 500e6. After reward vesting, the effective form will have larger
        // headroom and we land borrowAmt in the gap.
        uint256 firstBorrow = 7_500e6;
        _borrow(firstBorrow);

        // Stream rewards. With ratio=0, full amount accrues into
        // globalBorrowerPending after a full epoch elapses.
        uint256 rewardAmount = 3_000e6;
        _streamRewardsAsBorrower(rewardAmount);

        // Advance one full epoch and sync so _processGlobalVesting moves
        // globalVested -> globalBorrowerPending.
        vm.warp(EPOCH_3);
        vault.sync();

        uint256 rawLoaned = vault.totalLoanedAssets();
        uint256 reduction = _totalReduction();
        uint256 effectiveLoaned = _effectiveLoaned();
        uint256 total = vault.totalAssets();

        // Drift must be real before the gate behavior matters.
        assertGt(reduction, 0, "rewards must have driven reduction > 0 to exercise drift");
        assertGt(rawLoaned, effectiveLoaned, "raw loaned must strictly exceed effective");

        // Pick a borrow size that the raw form rejects but the effective form
        // accepts. Gate (strict) is:  (loaned + amt) * 10000 < maxUtilBps * total.
        //
        //   raw form rejects:        rawLoaned + amt       >= capAssets
        //   effective form accepts:  effectiveLoaned + amt <  capAssets
        //
        // So `borrowAmt` must land in (capAssets - rawLoaned, capAssets - effectiveLoaned).
        uint256 capAssets = (MAX_UTIL_BPS * total) / 10000;
        require(capAssets > effectiveLoaned, "test setup: effective form has headroom");
        // Raw headroom (signed): may be negative if rawLoaned already exceeds cap;
        // we floor it at zero for the borrowAmt range calculation.
        uint256 rawHeadroom = capAssets > rawLoaned ? capAssets - rawLoaned : 0;
        uint256 effectiveHeadroom = capAssets - effectiveLoaned;
        require(effectiveHeadroom > rawHeadroom, "test setup: drift must open a gate-gap");

        // Land midway through the gap so we are strictly within both bounds.
        // borrowAmt > rawHeadroom (so raw rejects: rawLoaned + amt >= capAssets)
        // borrowAmt < effectiveHeadroom (so effective accepts strictly).
        uint256 borrowAmt = rawHeadroom + (effectiveHeadroom - rawHeadroom) / 2;
        require(borrowAmt > rawHeadroom, "test setup: borrowAmt must exceed raw headroom");
        require(borrowAmt < effectiveHeadroom, "test setup: borrowAmt must be below effective headroom");

        // Self-documenting inequalities at the chosen amount.
        // Raw form would have required:  (rawLoaned + borrowAmt) * 10000 < MAX_UTIL_BPS * total
        // i.e.                            rawLoaned + borrowAmt < (MAX_UTIL_BPS * total) / 10000
        // We assert the raw-form would FAIL while effective-form passes.
        assertGe(
            (rawLoaned + borrowAmt) * 10000,
            MAX_UTIL_BPS * total,
            "raw formula would reject: (rawLoaned + amt) * 10000 >= maxUtilBps * total"
        );
        assertLt(
            (effectiveLoaned + borrowAmt) * 10000,
            MAX_UTIL_BPS * total,
            "effective formula accepts: (effectiveLoaned + amt) * 10000 < maxUtilBps * total"
        );

        // Capture pre-state to verify the borrow actually happened.
        uint256 borrowerBalBefore = usdc.balanceOf(borrower);
        uint256 totalLoanedBefore = vault.totalLoanedAssets();

        vm.prank(borrower);
        vault.borrowFromPortfolio(borrowAmt);

        assertEq(
            usdc.balanceOf(borrower),
            borrowerBalBefore + borrowAmt,
            "borrower received the borrowed amount"
        );
        assertEq(
            vault.totalLoanedAssets(),
            totalLoanedBefore + borrowAmt,
            "totalLoanedAssets advanced by borrow amount"
        );
    }

    // =========================================================================
    // 4. activeAssets(): returns the netted (effective) form after settlement.
    // =========================================================================

    function test_activeAssets_returnsNettedAfterSettlement() public {
        _setFlatRatio(0);

        uint256 borrowedAmt = 5_000e6;
        _borrow(borrowedAmt);

        // Reward stream that, once vested, increases globalBorrowerPending.
        _streamRewardsAsBorrower(1_200e6);

        vm.warp(EPOCH_3);
        vault.sync();

        uint256 rawLoaned = vault.totalLoanedAssets();
        uint256 reduction = _totalReduction();

        // Drift must be live.
        assertGt(reduction, 0, "reduction must be non-zero (rewards settled)");
        assertGt(rawLoaned, reduction, "raw loaned still exceeds reduction in this scenario");

        uint256 expected = rawLoaned - reduction;
        assertEq(vault.activeAssets(), expected, "activeAssets must equal effective form");
        assertLt(vault.activeAssets(), rawLoaned, "activeAssets must be strictly less than raw");
    }

    // =========================================================================
    // 5. activeAssets(): saturates at zero when reduction exceeds raw loaned.
    // =========================================================================

    function test_activeAssets_saturatesAtZero_whenReductionExceedsLoaned() public {
        _setFlatRatio(0);

        // Small principal so a large reward stream can over-saturate it.
        uint256 smallBorrow = 500e6;
        _borrow(smallBorrow);

        // Stream a reward amount strictly greater than principal. With ratio=0
        // and a full epoch of vesting, globalBorrowerPending will exceed
        // totalLoanedAssets, hitting the excessPendingOwedToBorrowers branch in
        // totalAssets() and the saturate-at-zero branch in activeAssets().
        uint256 rewardAmount = 1_500e6; // 3x principal
        _streamRewardsAsBorrower(rewardAmount);

        vm.warp(EPOCH_3);
        vault.sync();

        uint256 rawLoaned = vault.totalLoanedAssets();
        uint256 reduction = _totalReduction();
        assertGt(reduction, rawLoaned, "precondition: reduction must exceed raw loaned to exercise saturation");

        // No revert; returns 0 cleanly.
        assertEq(vault.activeAssets(), 0, "activeAssets saturates at zero, does not revert or underflow");
    }

    // =========================================================================
    // 6. activeAssets(): fresh state with no settled rewards matches raw loaned.
    //    Sanity that the netting does not break the baseline.
    // =========================================================================

    function test_activeAssets_freshState_matchesRawLoaned() public {
        uint256 borrowedAmt = 4_000e6;
        _borrow(borrowedAmt);

        // No rewards streamed, no time passed beyond setUp warp.
        assertEq(vault.totalVestedRewardsApplied(), 0, "no vested rewards in fresh state");
        assertEq(vault.getGlobalBorrowerPending(), 0, "no globalBorrowerPending in fresh state");

        uint256 rawLoaned = vault.totalLoanedAssets();
        assertEq(rawLoaned, borrowedAmt, "raw loaned equals borrowed amount in fresh state");
        assertEq(vault.activeAssets(), rawLoaned, "activeAssets == raw loaned when reduction == 0");
    }
}
