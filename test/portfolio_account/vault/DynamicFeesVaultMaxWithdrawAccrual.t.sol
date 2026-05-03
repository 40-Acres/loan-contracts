// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ============================================================================
// Regression: maxWithdraw / maxRedeem must mirror previewWithdraw / previewRedeem
// when fees are pending.
//
// Bug (pre-fix): maxWithdraw used convertToAssets(balanceOf(owner)) and
// maxRedeem used convertToShares(liquid). Both read PRE-accrual totalSupply()
// and totalAssets(). The four previewX functions and the _withdraw path both
// fold pendingFeeShares into the share-side. As a result,
// previewWithdraw(maxWithdraw(owner)) returned MORE shares than balanceOf(owner)
// whenever pendingFeeShares > 0, so withdraw(maxWithdraw(owner)) reverted in
// _burn with ERC20InsufficientBalance.
//
// Math sketch (b = balanceOf(owner), T = totalSupply, A = totalAssets,
// O = 10**_decimalsOffset(), P = pendingFeeShares):
//   pre-fix maxAssets ~= b * (A+1) / (T+O)             [pre-accrual]
//   previewWithdraw(maxAssets) ~= ceil(b * (T+P+O) / (T+O)) [post-accrual]
//   strictly greater than b whenever P > 0.
//
// Fix (lines 869-902 of DynamicFeesVault.sol): both maxWithdraw and maxRedeem
// now call _accrueFeeView() and use newTotalSupply = totalSupply()+pending,
// newTotalAssets, in their share/asset math — matching the previews.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPortfolioFactory} from "../../../src/interfaces/IPortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {FeeCalculator} from "../../../src/facets/account/vault/FeeCalculator.sol";
import {IFeeCalculator} from "../../../src/facets/account/vault/IFeeCalculator.sol";

// ============ Mocks ============

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPortfolioFactoryFee is IPortfolioFactory {
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

/// @dev Pinned 20% lender ratio so we can compute exact expected splits.
contract FlatFeeCalculator is IFeeCalculator {
    uint256 public immutable flat;
    constructor(uint256 _flat) { flat = _flat; }
    function getVaultRatioBps(uint256) external view override returns (uint256) { return flat; }
}

// ============================================================================
// Test
// ============================================================================

contract DynamicFeesVaultMaxWithdrawAccrualTest is Test {
    DynamicFeesVault public vault;
    MockUSDC public usdc;
    MockPortfolioFactoryFee public portfolioFactory;

    address public owner = address(0x1);
    address public borrower = address(0x20);
    address public feeRecipient = address(0xFEE);

    uint256 constant WEEK = ProtocolTimeLibrary.WEEK;
    uint256 constant EPOCH_2 = 2 * WEEK;
    uint256 constant EPOCH_4 = 4 * WEEK;
    uint256 constant EPOCH_5 = 5 * WEEK;

    uint256 constant SEED = 10_000e6;
    uint256 constant DEFAULT_FEE_BPS = 2500;

    function setUp() public {
        vm.warp(EPOCH_2);

        usdc = new MockUSDC();
        portfolioFactory = new MockPortfolioFactoryFee();

        DynamicFeesVault impl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(usdc), "USDC Vault", "vUSDC",
            address(portfolioFactory), 8000, feeRecipient, DEFAULT_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = DynamicFeesVault(address(proxy));
        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.acceptOwnership();

        // Pin 20% lender ratio
        FlatFeeCalculator fc = new FlatFeeCalculator(2000);
        vm.prank(owner);
        vault.setFeeCalculator(address(fc));

        // Seed initial liquidity (test contract is initial LP).
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.deposit(SEED, address(this));
    }

    // ------------------------------------------------------------------
    // Set up a state where _accrueFeeView() returns nonzero `pending`.
    //
    // Mirrors `_twoEpochVestSetup` from DynamicFeesVaultTreasury.t.sol:
    //   stream #1 at EPOCH_2, stream #2 at EPOCH_4, advance to EPOCH_5.
    // At EPOCH_5, stream #1's lender premium (20e6) is fully vested into
    // totalAssets() — so totalAssets() > lastTotalAssetsForFee and
    // _accrueFeeView returns nonzero `pending`. We do NOT call sync(), so
    // pendingFeeShares() stays > 0 and the maxWithdraw/Redeem paths see
    // a nonzero accrual that must be folded into their math.
    // ------------------------------------------------------------------
    function _setupPendingFees() internal {
        // Tiny borrow keeps vault USDC liquid greater than the test contract's
        // share value, so maxWithdraw's `assets < liquid` branch is taken and
        // the bug — wrong `assets` math — actually surfaces. (When `liquid` is
        // the binding constraint, the cap masks the math error.)
        vm.prank(borrower);
        vault.borrowFromPortfolio(100e6);

        // Stream #1 at EPOCH_2
        vm.startPrank(borrower);
        usdc.mint(borrower, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // Stream #2 at EPOCH_4
        vm.warp(EPOCH_4);
        vm.startPrank(borrower);
        usdc.mint(borrower, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        // EPOCH_5: stream #1's premium has fully vested. totalAssets() now
        // exceeds lastTotalAssetsForFee → pendingFeeShares > 0.
        vm.warp(EPOCH_5);

        // Roll forward one block to release the lastDepositBlock guard set
        // by setUp's deposit (so maxWithdraw won't be forced to 0).
        vm.roll(block.number + 1);
    }

    // =================================================================
    // 1) PRIMARY REGRESSION: withdraw(maxWithdraw(owner)) must not revert
    //    when fees are pending. Pre-fix this reverted with
    //    ERC20InsufficientBalance because previewWithdraw burned more
    //    shares than the owner held.
    // =================================================================
    function test_withdraw_maxWithdraw_doesNotRevert_withPendingFees() public {
        _setupPendingFees();

        // Sanity: pending fee shares must be > 0 to be a real regression test.
        uint256 pending = vault.pendingFeeShares();
        assertGt(pending, 0, "scenario sanity: pendingFeeShares must be > 0");

        uint256 maxAssets = vault.maxWithdraw(address(this));
        assertGt(maxAssets, 0, "scenario sanity: maxWithdraw must return > 0");

        // The critical assertion: previewWithdraw on the max value must
        // not exceed the owner's share balance — which is what the burn
        // step inside _withdraw will check. Pre-fix this is violated.
        uint256 sharesBurnPreviewed = vault.previewWithdraw(maxAssets);
        uint256 ownerShares = vault.balanceOf(address(this));
        assertLe(
            sharesBurnPreviewed,
            ownerShares,
            "previewWithdraw(maxWithdraw) must not exceed balanceOf(owner)"
        );

        // Actual withdraw must not revert.
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 assetsBefore = usdc.balanceOf(address(this));
        vault.withdraw(maxAssets, address(this), address(this));
        uint256 sharesAfter = vault.balanceOf(address(this));
        uint256 assetsAfter = usdc.balanceOf(address(this));

        assertEq(assetsAfter - assetsBefore, maxAssets, "received maxWithdraw assets");
        assertLe(sharesBefore - sharesAfter, sharesBefore, "shares burned <= owner shares");
    }

    // =================================================================
    // 2) Same regression for the redeem path.
    // =================================================================
    function test_redeem_maxRedeem_doesNotRevert_withPendingFees() public {
        _setupPendingFees();

        uint256 pending = vault.pendingFeeShares();
        assertGt(pending, 0, "scenario sanity: pendingFeeShares must be > 0");

        uint256 maxShares = vault.maxRedeem(address(this));
        assertGt(maxShares, 0, "scenario sanity: maxRedeem must return > 0");

        // maxRedeem must never exceed the owner's actual balance.
        assertLe(
            maxShares,
            vault.balanceOf(address(this)),
            "maxRedeem must not exceed balanceOf(owner)"
        );

        uint256 assetsBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 received = vault.redeem(maxShares, address(this), address(this));
        uint256 assetsAfter = usdc.balanceOf(address(this));
        uint256 sharesAfter = vault.balanceOf(address(this));

        assertEq(assetsAfter - assetsBefore, received, "received matches return");
        assertEq(sharesBefore - sharesAfter, maxShares, "exactly maxShares burned");
    }

    // =================================================================
    // 3) Algebraic guarantee: previewWithdraw(maxWithdraw(owner)) must
    //    not exceed balanceOf(owner). This is the property that makes
    //    the burn safe; tested directly so future drift in either
    //    function trips the assertion.
    // =================================================================
    function test_maxWithdraw_matchesPreviewWithdrawSupply() public {
        _setupPendingFees();
        assertGt(vault.pendingFeeShares(), 0, "pending fees required");

        uint256 maxAssets = vault.maxWithdraw(address(this));
        uint256 sharesQuoted = vault.previewWithdraw(maxAssets);
        uint256 ownerShares = vault.balanceOf(address(this));

        assertLe(
            sharesQuoted,
            ownerShares,
            "previewWithdraw(maxWithdraw(owner)) must not exceed balanceOf(owner)"
        );
    }

    // =================================================================
    // 4) When liquidity is the bottleneck, redeem(maxRedeem(...)) must
    //    not exceed the contract's liquid asset balance — within
    //    floor-rounding tolerance of one share's worth.
    //
    // Construction: borrow most of SEED so the vault holds only a small
    // liquid balance relative to the test contract's share value. Then
    // pendingFeeShares > 0 still holds via the same stream chain.
    // =================================================================
    function test_maxRedeem_drains_liquid_within_one_share() public {
        // Borrow up to (just under) the 80% utilization cap so liquidity
        // is well below the owner's share value, then run a stream chain
        // to generate pending fees.
        vm.prank(borrower);
        vault.borrowFromPortfolio(7_500e6);

        vm.startPrank(borrower);
        usdc.mint(borrower, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_4);
        vm.startPrank(borrower);
        usdc.mint(borrower, 100e6);
        usdc.approve(address(vault), 100e6);
        vault.depositRewards(100e6);
        vm.stopPrank();

        vm.warp(EPOCH_5);
        vm.roll(block.number + 1);

        // Fees are pending and liquidity (~1100e6) is far below the
        // owner's share value (~10000e6+).
        uint256 pending = vault.pendingFeeShares();
        assertGt(pending, 0, "pending fees required");

        uint256 liquidBefore = usdc.balanceOf(address(vault));
        uint256 ownerShareValue = vault.convertToAssets(vault.balanceOf(address(this)));
        assertLt(liquidBefore, ownerShareValue, "scenario sanity: liquidity is the bottleneck");

        uint256 maxShares = vault.maxRedeem(address(this));
        assertGt(maxShares, 0, "maxRedeem > 0");

        uint256 received = vault.redeem(maxShares, address(this), address(this));

        // The assets received must not exceed liquidity that was available.
        assertLe(received, liquidBefore, "redeemed assets must not exceed prior liquid balance");

        // And we should drain it tightly: the leftover is at most one
        // share's worth of asset (floor-rounding from share->asset math).
        // Use a generous tolerance of one whole share unit (1e6 USDC) which
        // is far larger than the actual rounding error but still tiny
        // relative to the liquid balance.
        assertGe(received + 1e6, liquidBefore, "should drain liquid within one share's rounding");
    }
}
