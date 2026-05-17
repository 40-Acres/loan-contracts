// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * ERC4626UtilizationCap
 *
 * Issue Summary
 * -------------
 * Utilization-cap enforcement moved off the LendingVault and onto the
 * manager-side `overSuppliedVaultDebt` flag. `LendingVault.borrowFromPortfolio`
 * no longer reverts with ExceedsUtilization; `_recomputeOverSupplied` runs
 * after every debt mutation and stores `activeAssets - cap` (when positive).
 * `enforceCollateralRequirements()` reverts BadDebt at end of multicall.
 *
 * `LoanConfig.maxUtilizationBps` is the single source of truth; the getter
 * falls back to 8000 if unset.
 *
 * Why these tests are load-bearing
 * --------------------------------
 * `_recomputeOverSupplied` is the ERC4626 stack's ONLY borrow-time
 * utilization protection. If a refactor reverts to hardcoded 8000 or
 * stops reading `loanConfig.getMaxUtilizationBps()`, raising the cap from
 * 8000 -> 9500 (the user-stated motivation) silently no-ops. These tests
 * pin the cap-from-LoanConfig wiring and the post-state flag math.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";

import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* ---------------------------------------------------------------------------
 *  Harness owning the ERC-7201 slot keccak256("storage.ERC4626CollateralManager").
 * -------------------------------------------------------------------------*/
contract ERC4626UtilHarness {
    function addCollateral(address cfg, address vault, uint256 shares) external {
        ERC4626CollateralManager.addCollateral(cfg, vault, shares);
    }
    function increaseTotalDebt(address cfg, address vault, uint256 amount)
        external returns (uint256, uint256)
    {
        return ERC4626CollateralManager.increaseTotalDebt(cfg, vault, amount);
    }
    function decreaseTotalDebt(address cfg, address vault, uint256 amount)
        external returns (uint256)
    {
        return ERC4626CollateralManager.decreaseTotalDebt(cfg, vault, amount);
    }
    function enforceCollateralRequirements(address cfg, address vault) external view returns (bool) {
        return ERC4626CollateralManager.enforceCollateralRequirements(cfg, vault);
    }
    function getMaxLoan(address cfg, address vault) external view returns (uint256, uint256) {
        return ERC4626CollateralManager.getMaxLoan(cfg, vault);
    }

    // Layout: { shares, depositedAssetValue, debt, overSuppliedVaultDebt, startShortfall, snapshotBlockNumber }
    function readOverSupplied() external view returns (uint256 v) {
        bytes32 slot = keccak256("storage.ERC4626CollateralManager");
        assembly { v := sload(add(slot, 3)) }
    }
}

contract MockUtilPool4626 {
    IERC20 public immutable assetToken;
    address public immutable portfolioFactory;
    uint256 public _activeAssets;
    uint256 public _totalAssets;
    mapping(address => uint256) public debt;

    constructor(address asset_, address factory_) {
        assetToken = IERC20(asset_);
        portfolioFactory = factory_;
    }

    function borrowFromPortfolio(uint256 amount) external returns (uint256) {
        debt[msg.sender] += amount;
        _activeAssets += amount;
        if (assetToken.balanceOf(address(this)) >= amount) {
            assetToken.transfer(msg.sender, amount);
        }
        return 0;
    }
    function payFromPortfolio(uint256 totalPayment, uint256) external returns (uint256 actualPaid) {
        uint256 d = debt[msg.sender];
        actualPaid = totalPayment > d ? d : totalPayment;
        if (actualPaid > 0) {
            assetToken.transferFrom(msg.sender, address(this), actualPaid);
            debt[msg.sender] -= actualPaid;
            if (_activeAssets >= actualPaid) _activeAssets -= actualPaid;
            else _activeAssets = 0;
        }
    }
    function lendingAsset() external view returns (address) { return address(assetToken); }
    function lendingVault() external view returns (address) { return address(this); }
    function activeAssets() external view returns (uint256) { return _activeAssets; }
    function getDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function getEffectiveDebtBalance(address b) external view returns (uint256) { return debt[b]; }
    function totalAssets() external view returns (uint256) { return _totalAssets; }
    function asset() external view returns (address) { return address(assetToken); }
    function decimals() external pure returns (uint8) { return 6; }
    function getPortfolioFactory() external view returns (address) { return portfolioFactory; }
    function depositRewards(uint256) external {}

    function setActive(uint256 v) external { _activeAssets = v; }
    function setTotal(uint256 v) external { _totalAssets = v; }
}

contract ERC4626UtilizationCapTest is Test {
    ERC4626UtilHarness internal h;
    MockUtilPool4626 internal pool;
    PortfolioManager internal pm;
    PortfolioFactory internal factory;
    PortfolioFactoryConfig internal cfg;
    LoanConfig internal loanConfig;
    MockERC20 internal usdc;
    MockERC4626 internal collatVault;

    address internal OWNER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal AUTH = address(0xAAAA);

    function setUp() public {
        vm.startPrank(OWNER);

        pm = new PortfolioManager(OWNER);
        (PortfolioFactory f, ) = pm.deployFactory(keccak256("erc4626-utilcap-test"));
        factory = f;

        DeployPortfolioFactoryConfig deployer = new DeployPortfolioFactoryConfig();
        (cfg, , loanConfig, ) = deployer.deploy(address(factory), OWNER);

        usdc = new MockERC20("USDC", "USDC", 6);
        collatVault = new MockERC4626(address(usdc), "cVault", "cVAULT", 6);

        pool = new MockUtilPool4626(address(usdc), address(factory));
        cfg.setLoanContract(address(pool));
        factory.setPortfolioFactoryConfig(address(cfg));

        // Like-to-like LTV path: lending asset == collateral asset.
        loanConfig.setLtv(7000); // 70%
        loanConfig.setMultiplier(7000);
        // maxUtilizationBps unset -> defaults to 8000.

        vm.stopPrank();

        h = new ERC4626UtilHarness();
        vm.prank(OWNER);
        pm.setAuthorizedCaller(AUTH, true);

        vm.label(address(h), "ERC4626UtilHarness");
        vm.label(address(pool), "MockUtilPool4626");
    }

    function _setCap(uint256 bps) internal {
        vm.prank(OWNER);
        loanConfig.setMaxUtilizationBps(bps);
    }

    /// @dev Stage `shares` of ERC4626 vault collateral on the harness. We back
    /// the share supply with real underlying deposits so `convertToAssets`
    /// returns predictable 1:1 values.
    function _stageCollateral(uint256 shares) internal {
        // Mint underlying to harness, approve vault, deposit -> shares to harness.
        usdc.mint(address(h), shares);
        vm.prank(address(h));
        usdc.approve(address(collatVault), shares);
        vm.prank(address(h));
        collatVault.deposit(shares, address(h));
        // Add as collateral (need authorized caller -- snapshot path doesn't gate adds).
        h.addCollateral(address(cfg), address(collatVault), shares);
    }

    /* ---------------------------------------------------------------
     * Section 1: cap-respecting borrow keeps flag at zero
     * --------------------------------------------------------------- */

    function test_borrowUnderCap_flagStaysZero() public {
        pool.setTotal(1000e6);            // 1000 USDC total assets
        usdc.mint(address(pool), 1000e6); // fund pool so transfer succeeds

        // Stage 100e6 collateral -> LTV 70% -> maxLoan 70e6 (well under cap math too).
        _stageCollateral(100e6);

        // Borrow 50e6: active=50e6 < cap 800e6 (8000 bps of 1000e6) and debt < maxLoan.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 50e6);

        assertEq(h.readOverSupplied(), 0, "flag must be 0 when active <= cap");
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(collatVault)));
    }

    /* ---------------------------------------------------------------
     * Section 2: over-cap borrow flags exact excess; enforcement reverts
     * --------------------------------------------------------------- */

    function test_borrowOverCap_flagEqualsExcess_revertsBadDebt() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);

        // Large collateral so the collateral-side LTV guard does not trip first.
        _stageCollateral(10_000e6); // maxLoan @70% LTV = 7000e6

        // Borrow 90e6: post active = 90e6 > cap 80e6 -> flag = 10e6.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 90e6);

        assertEq(h.readOverSupplied(), 10e6, "flag = active - cap");

        // Cross a block so the intra-block shortfall snapshot does not also fire.
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.BadDebt.selector, uint256(10e6)));
        h.enforceCollateralRequirements(address(cfg), address(collatVault));
    }

    /* ---------------------------------------------------------------
     * Section 3: repay clears the flag (post-state recompute)
     * --------------------------------------------------------------- */

    function test_repayClearsFlag() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 90e6);
        assertEq(h.readOverSupplied(), 10e6, "flag set after over-cap borrow");

        // Fund harness for repayment.
        usdc.mint(address(h), 20e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(collatVault), 20e6);

        // active = 90 - 20 = 70 <= cap 80 -> flag clears.
        assertEq(h.readOverSupplied(), 0, "flag clears when active <= cap");
    }

    /* ---------------------------------------------------------------
     * Section 4: raising cap unlocks a borrow that would have flagged
     * --------------------------------------------------------------- */

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// User-stated motivation: "when we update our Vault possibly we can set
    /// the cap a bit higher". Same 90e6 borrow flags 10e6 at cap 8000 but
    /// clears at cap 9500 (95e6 > 90e6). If a future refactor pins the cap
    /// to a hardcoded value or stops reading the LoanConfig, this test fails.
    /// Removing this test is not coverage cleanup.
    function test_ERC4626_RaisingCapUnlocksBorrow_DoNotRemove() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        // ---- At default cap (8000 via LoanConfig fallback; storage left unset).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 90e6);
        assertEq(h.readOverSupplied(), 10e6, "default cap 8000: 90e6 exceeds 80e6 cap by 10e6");

        // Wipe debt to set up the cap-9500 trial cleanly.
        usdc.mint(address(h), 90e6);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(collatVault), 90e6);
        assertEq(h.readOverSupplied(), 0, "flag cleared after repay");

        // ---- At cap 9500: same 90e6 borrow now sits under cap (95e6) -> no flag.
        _setCap(9500);
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 90e6);
        assertEq(h.readOverSupplied(), 0, "at cap 9500: 90e6 within 95e6 cap, flag must be 0");

        vm.roll(block.number + 1);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(collatVault)));
    }

    /* ---------------------------------------------------------------
     * Section 5: vault no longer reverts on over-cap
     * --------------------------------------------------------------- */

    /// @notice Vault-level ExceedsUtilization was removed. cap+1 wei borrow MUST
    /// succeed at the vault level; the manager flag carries the excess.
    function test_vaultNoLongerRevertsOnOverCap() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        // Default cap of 8000 via LoanConfig fallback; storage left unset.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 80e6 + 1);

        assertEq(h.readOverSupplied(), 1, "cap+1 wei borrow flags exactly 1 wei");
    }

    /* ---------------------------------------------------------------
     * Section 6: zero-totalAssets pool -- any positive active flags FULL excess
     *
     * Ported from the legacy vault-side `*revertsOnZeroTotalAssets` test.
     * Old behavior: vault reverted ExceedsUtilization on any borrow when
     * totalAssets == 0. New behavior: borrow succeeds at the vault, the
     * cap evaluates to `0 * bps / 10000 == 0`, so the entire activeAssets
     * is "over" the cap and overSuppliedVaultDebt absorbs it. Enforcement
     * then reverts BadDebt with the full excess.
     * --------------------------------------------------------------- */

    /// @notice With vault.totalAssets() == 0 the cap collapses to 0 and any
    /// borrow >= 1 wei is fully over the cap. Borrow MUST succeed at the
    /// pool but enforcement MUST revert with BadDebt(borrowAmount).
    function test_borrowAgainstZeroTotalAssets_flagAbsorbsAll_revertsBadDebt() public {
        // pool.totalAssets stays 0 (default). Mint to pool so transfer works.
        usdc.mint(address(pool), 1);

        // Stage collateral so collateral-side guards do not trip first.
        _stageCollateral(10_000e6);

        // 1 wei borrow. activeAssets = 1, cap = 0 -> flag = 1.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 1);

        assertEq(h.readOverSupplied(), 1, "1 wei borrow into zero-totalAssets pool flags 1 wei");

        // Cross a block so the intra-block snapshot does not also fire.
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements(address(cfg), address(collatVault));
    }

    /* ---------------------------------------------------------------
     * Section 7: boundary around the cap (cap-1, cap, cap+1)
     *
     * Ported from the legacy `*revertsAtExactCap` and
     * `*succeedsOneWeiBelowCap` vault tests. The new `_recomputeOverSupplied`
     * uses strict `>` so activeAssets == cap is FINE -- a behavior change
     * vs. legacy vault enforcement which used `>=` and reverted at exact cap.
     * Removing this test would silently lose the boundary documentation.
     * --------------------------------------------------------------- */

    /// @notice Behavior change vs. legacy vault enforcement which used >=
    /// and reverted at exact cap. Removing this test would silently lose
    /// the boundary documentation. Walks cap-1, cap, cap+1 to pin the
    /// strict-greater-than comparison in `_recomputeOverSupplied`.
    function test_ERC4626_BoundaryAroundCap_NoFlagSet_DoNotRemove() public {
        // totalAssets = 100e6, cap 8000 bps -> cap = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        // ---- cap - 1: under cap, flag stays 0.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 80e6 - 1);
        assertEq(h.readOverSupplied(), 0, "cap - 1: flag must be 0");
        vm.roll(block.number + 1);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(collatVault)), "cap - 1: enforcement passes");

        // Repay back to zero to set up the exact-cap trial cleanly.
        usdc.mint(address(h), 80e6 - 1);
        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(collatVault), 80e6 - 1);
        assertEq(h.readOverSupplied(), 0, "post-repay flag back to 0");

        // ---- exact cap: strict `>` -- flag stays 0, enforcement passes.
        // This is the behavior-change pin: legacy vault used `>=` and reverted here.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 80e6);
        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");
        vm.roll(block.number + 1);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(collatVault)), "exact cap: enforcement passes");

        // ---- cap + 1: flag = 1.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 1);
        assertEq(h.readOverSupplied(), 1, "cap + 1: flag = exactly 1 wei");

        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.BadDebt.selector, uint256(1)));
        h.enforceCollateralRequirements(address(cfg), address(collatVault));
    }

    /// @notice REGRESSION GUARD -- DO NOT REMOVE.
    /// Behavior change vs. legacy vault enforcement which used >= and
    /// reverted at exact cap. Removing this test would silently lose
    /// the boundary documentation. Pins the strict-greater-than
    /// comparison: activeAssets == cap MUST leave the flag at 0 and
    /// enforcement MUST pass.
    function test_ERC4626_BorrowAtExactCap_NoFlagSet_DoNotRemove() public {
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        // Borrow exactly cap (80e6 at 8000 bps).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 80e6);

        assertEq(h.readOverSupplied(), 0, "exact cap: flag must be 0 (strict >)");

        vm.roll(block.number + 1);
        assertTrue(h.enforceCollateralRequirements(address(cfg), address(collatVault)), "exact cap: enforcement passes");
    }

    /* ---------------------------------------------------------------
     * Section 8: repay-never-reverts invariant (BUG REGRESSION)
     *
     * Pre-fix, `_recomputeOverSupplied` (called from the repay path) set
     * `overSuppliedVaultDebt = max(activeAssets - cap, 0)` absolutely. If
     * external state (another borrower's debt, or vesting shrinking
     * totalAssets) had already pushed the pool over cap, a clean borrower
     * making a legitimate repay would have the global excess pinned to THEM
     * and `enforceCollateralRequirements()` would revert -- blocking the
     * repay.
     *
     * Post-fix, the repay path uses `_clampDownOverSupplied` which only
     * lowers the flag -- never raises it.
     * --------------------------------------------------------------- */

    /// @notice Regression for the repay-never-reverts invariant. External
    /// over-cap state must not be attributed to a borrower who is merely
    /// repaying. Without the clamp-down in `_clampDownOverSupplied`, a repay
    /// during this state would raise the flag and revert.
    function test_ERC4626CollateralManager_RepayWhenPoolExternallyOverCap_FlagNotRaised_DoNotRemove() public {
        // totalAssets = 100e6, cap 8000 bps -> cap = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6); // lots of collateral so LTV side never trips

        // 1) Borrower starts clean.
        assertEq(h.readOverSupplied(), 0, "precondition: flag is 0");

        // 2) Borrower has a small debt to repay (10e6 << cap 80e6).
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 10e6);
        assertEq(h.readOverSupplied(), 0, "small borrow under cap: flag still 0");

        // 3) External state pushes pool over cap. Bump activeAssets directly
        //    (simulates another borrower's debt growing -- or totalAssets
        //    shrinking via vesting). active = 120e6 > cap = 80e6, excess = 40e6
        //    attributable to "someone else", not this borrower.
        pool.setActive(120e6);

        // 4) Borrower repays a portion of their 10e6.
        usdc.mint(address(h), 5e6);

        // Cross a block so the intra-block shortfall snapshot does not interfere.
        vm.roll(block.number + 1);

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(collatVault), 5e6);

        // 5) Flag MUST still be 0. The clamp-down only LOWERS the flag.
        assertEq(
            h.readOverSupplied(),
            0,
            "repay must not RAISE the supply flag from external over-cap state"
        );

        // 6) Enforcement must NOT revert -- repay path succeeds end-to-end.
        vm.roll(block.number + 1);
        assertTrue(
            h.enforceCollateralRequirements(address(cfg), address(collatVault)),
            "enforce must pass after legitimate repay"
        );
    }

    /// @notice Paired test: partial-clear case. Under the new per-borrower
    /// semantics, the supply flag is accumulated by `+=` on over-cap borrows
    /// and decremented by `-= actualPaid` on repays. So after a 110e6 borrow
    /// (maxLoan = 80e6, flag += 30e6) and a 10e6 repay (flag -= 10e6), the
    /// flag must read 20e6 -- the original excess minus what was actually
    /// paid down. The flag must NEVER be raised by a repay.
    function test_ERC4626CollateralManager_RepayPartialClear_FlagLoweredToNewExcess_DoNotRemove() public {
        // totalAssets = 100e6, cap = 80e6.
        pool.setTotal(100e6);
        usdc.mint(address(pool), 100e6);
        _stageCollateral(10_000e6);

        // Borrower's own borrow pushes pool over cap: borrow 110e6,
        // active=110e6, cap=80e6 -> flag = 30e6.
        vm.prank(AUTH);
        h.increaseTotalDebt(address(cfg), address(collatVault), 110e6);
        assertEq(h.readOverSupplied(), 30e6, "borrow over cap: flag = active - cap = 30e6");

        // Repay 10e6. active = 110 - 10 = 100; still > cap 80; new excess = 20e6.
        usdc.mint(address(h), 10e6);

        vm.roll(block.number + 1);

        vm.prank(AUTH);
        h.decreaseTotalDebt(address(cfg), address(collatVault), 10e6);

        // Flag must be LOWERED to 20e6 (30e6 - 10e6), never raised.
        assertEq(
            h.readOverSupplied(),
            20e6,
            "partial repay: flag -= actualPaid -> 30e6 - 10e6 = 20e6, never raised"
        );
    }
}
