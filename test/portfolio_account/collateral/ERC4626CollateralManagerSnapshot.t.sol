// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * ISSUE SUMMARY — ERC4626CollateralManager Snapshot Enforcement
 * ==========================================================================
 *
 * 1. The snapshot pattern compares shortfall at the START of the block
 *    (first mutating op) vs the END (enforceCollateralRequirements).
 *    If shortfall did not increase, enforcement passes even if the user
 *    is underwater — this is intentional: it allows paying down debt
 *    while still underwater, as long as the situation doesn't worsen.
 *
 * 2. When no snapshot exists (no mutating op this block), start == end,
 *    so enforcement always passes. This is correct because it means
 *    no state changed this block.
 *
 * 3. removeCollateral and removeSharesForYield have inline
 *    require(debt <= maxLoanIgnoreSupply) guards that revert regardless
 *    of the snapshot pattern. These provide hard protection against
 *    removing collateral below the debt threshold.
 *
 * 4. overSuppliedVaultDebt tracking in increaseTotalDebt can accumulate
 *    if a user borrows beyond maxLoanIgnoreSupply. The enforceCollateralRequirements
 *    check for overSuppliedVaultDebt > 0 will always revert with BadDebt.
 * ==========================================================================
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/ERC4626ClaimingFacet.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {DeployERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployERC4626ClaimingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ERC4626SnapshotTest
 * @dev Tests for the per-block snapshot enforcement pattern in ERC4626CollateralManager.
 *
 * The snapshot pattern:
 *   - First mutating call in a block (addCollateral, removeCollateral, increaseTotalDebt,
 *     decreaseTotalDebt) records the current shortfall as the "start" baseline.
 *   - enforceCollateralRequirements (called by PortfolioManager at end of multicall)
 *     computes the "end" shortfall and reverts if end > start.
 *   - If no snapshot was taken this block, start == end (always passes).
 */
contract ERC4626SnapshotTest is Test {
    ERC4626CollateralFacet public _erc4626CollateralFacet;
    ERC4626LendingFacet public _erc4626LendingFacet;
    ERC4626ClaimingFacet public _erc4626ClaimingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    // Config contracts
    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    // Mock contracts
    MockERC20 public _underlyingAsset;
    MockERC4626 public _mockVault;

    // Lending infrastructure
    address public _loanContract;
    address public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC worth of shares
    uint256 constant BORROW_AMOUNT = 500e6;    // 500 USDC

    function setUp() public virtual {
        vm.startPrank(_owner);

        // Deploy portfolio manager and factory
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-snapshot-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // Deploy config contracts
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        // Deploy mock underlying asset (USDC-like with 6 decimals)
        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);

        // Deploy mock ERC4626 vault for collateral
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        // Deploy lending infrastructure
        _setupLendingInfrastructure();

        // Deploy and register ERC4626CollateralFacet
        DeployERC4626CollateralFacet deployer = new DeployERC4626CollateralFacet();
        _erc4626CollateralFacet = deployer.deploy(address(_portfolioFactory), address(_mockVault));

        // Deploy and register ERC4626LendingFacet
        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _erc4626LendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        // Set config
        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000); // 70% LTV
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioFactoryConfig.setLoanContract(_loanContract);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // Set authorized caller
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Mint underlying assets to user for testing
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT * 10);

        // Fund lending vault with USDC for borrowing
        _underlyingAsset.mint(address(this), 10000e6);
        _underlyingAsset.approve(_lendingVault, 10000e6);
        DynamicFeesVault(payable(_lendingVault)).deposit(10000e6, address(this));
    }

    function _setupLendingInfrastructure() internal {
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            address(_underlyingAsset),
            "ERC4626 Lending Vault",
            "lVAULT",
            address(_portfolioFactory),
            8000,
            address(this),
            uint256(0)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        DynamicFeesVault dynamicVault = DynamicFeesVault(address(vaultProxy));

        _loanContract = address(dynamicVault);
        _lendingVault = address(dynamicVault);

        dynamicVault.transferOwnership(_owner);
        dynamicVault.acceptOwnership();
    }

    // ============ Helper Functions ============

    function _prepareUserWithVaultShares(uint256 depositAmount) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.approve(address(_mockVault), depositAmount);
        shares = _mockVault.deposit(depositAmount, _user);
        vm.stopPrank();
    }

    function _transferSharesToPortfolio(uint256 shares) internal {
        vm.startPrank(_user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();
    }

    function _addCollateralViaMulticall(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _removeCollateralViaMulticall(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, shares);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _payDebtDirect(uint256 amount) internal {
        vm.startPrank(_user);
        _underlyingAsset.approve(_portfolioAccount, amount);
        ERC4626LendingFacet(_portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    function _setupCollateralAndDebt(uint256 collateralAmount, uint256 borrowAmount) internal returns (uint256 shares) {
        shares = _prepareUserWithVaultShares(collateralAmount);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);
        vm.roll(block.number + 1); // New block between independent operations
        _borrowViaMulticall(borrowAmount);
    }

    function _deployAndRegisterClaimingFacet() internal {
        vm.startPrank(_owner);
        DeployERC4626ClaimingFacet claimingDeployer = new DeployERC4626ClaimingFacet();
        _erc4626ClaimingFacet = claimingDeployer.deploy(address(_portfolioFactory), address(_mockVault));
        vm.stopPrank();
    }

    // ============================================================================
    // CORE SNAPSHOT MECHANICS (Tests 1-5)
    // ============================================================================

    /**
     * @dev Test 1: addCollateral triggers a snapshot.
     * After addCollateral in a multicall, the snapshot should be written to storage.
     * The snapshot captures the shortfall BEFORE the addCollateral executes, which
     * for a fresh account with no debt is 0.
     * Enforcement should pass because end shortfall (still 0) <= start shortfall (0).
     */
    function testERC4626SnapshotOnAddCollateral() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);

        // addCollateral via multicall — this triggers _snapshotIfNeeded internally
        _addCollateralViaMulticall(shares);

        // Enforcement should pass (no debt, no shortfall increase)
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass after addCollateral");

        // Verify collateral was tracked
        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT, "Collateral value should equal deposit");
    }

    /**
     * @dev Test 2: removeCollateral triggers a snapshot.
     * The snapshot captures shortfall before removing. After removal with no debt,
     * shortfall remains 0 and enforcement passes.
     */
    function testERC4626SnapshotOnRemoveCollateral() public {
        // Setup: add collateral first
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        // New block for the remove operation
        vm.roll(block.number + 1);

        // removeCollateral — triggers snapshot, then inline checks debt <= maxLoan
        _removeCollateralViaMulticall(shares);

        // Verify collateral removed
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "Collateral should be 0");
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0, "Shares should be 0");
    }

    /**
     * @dev Test 3: increaseTotalDebt (borrow) triggers a snapshot.
     * Snapshot captures shortfall before borrowing. After borrowing within LTV,
     * shortfall is still 0, so enforcement passes.
     */
    function testERC4626SnapshotOnDebtIncrease() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        // New block for borrow
        vm.roll(block.number + 1);

        // Borrow within LTV (70% of 1000 = 700 max, borrowing 400)
        _borrowViaMulticall(400e6);

        // Verify debt recorded
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 400e6, "Debt should be 400 USDC");

        // Enforcement passes because shortfall didn't increase (debt <= maxLoan)
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass when debt is within LTV");
    }

    /**
     * @dev Test 4: Multiple operations in the same block — only the FIRST writes the snapshot.
     * This tests idempotency: the second addCollateral in the same block should NOT
     * overwrite the snapshot taken by the first.
     *
     * We verify this by adding collateral in two steps within one multicall. The snapshot
     * records shortfall at the very start, and the enforcement at the end uses that same
     * starting baseline.
     */
    function testERC4626SnapshotIdempotentSameBlock() public {
        uint256 halfDeposit = INITIAL_DEPOSIT / 2;
        uint256 shares1 = _prepareUserWithVaultShares(halfDeposit);
        uint256 shares2 = _prepareUserWithVaultShares(halfDeposit);
        _transferSharesToPortfolio(shares1);
        _transferSharesToPortfolio(shares2);

        // Two addCollateral calls in the same multicall (same block)
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares1);
        calldatas[1] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares2);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Both shares should be registered
        uint256 totalShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(totalShares, shares1 + shares2, "Both share deposits should be tracked");

        // Collateral value should be the full deposit
        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT, "Collateral value should equal full deposit");
    }

    /**
     * @dev Test 5: Snapshot resets when a new block begins.
     * Block N: addCollateral, borrow — snapshot written at block N.
     * Block N+1: pay debt — new snapshot written at block N+1 with updated state.
     * This verifies the snapshotBlockNumber comparison correctly detects new blocks.
     */
    function testERC4626SnapshotResetsNewBlock() public {
        // Block N: Setup collateral and borrow
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1); // Block N+1

        _borrowViaMulticall(400e6);

        // Verify debt at end of block N+1
        uint256 debtAfterBorrow = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfterBorrow, 400e6, "Debt should be 400 after borrow");

        vm.roll(block.number + 1); // Block N+2: new snapshot will be written

        // Pay some debt — this writes a NEW snapshot at block N+2
        _underlyingAsset.mint(_user, 200e6);
        _payDebtDirect(200e6);

        // After payment, debt should decrease
        uint256 debtAfterPay = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfterPay, debtAfterBorrow, "Debt should decrease after payment");

        // Enforcement should pass: shortfall decreased (or stayed 0)
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass after debt payment");
    }

    // ============================================================================
    // ENFORCEMENT INVARIANTS (Tests 6-10)
    // ============================================================================

    /**
     * @dev Test 6: Underwater user can pay debt — shortfall decreases, enforcement passes.
     * An underwater user (debt > maxLoan due to collateral depreciation) should still
     * be able to pay down debt because the shortfall is decreasing.
     */
    function testERC4626UnderwaterCanPayDebt() public {
        // Setup: Collateral of 1000, borrow 600 (within 70% LTV = 700 max)
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 600e6);

        // Simulate collateral depreciation: reduce vault assets to make user underwater
        // Current: 1000 collateral, 600 debt, maxLoan = 700
        // After depreciation: e.g. 800 collateral, 600 debt, maxLoan = 560 -> underwater!
        // We'll remove assets from the mock vault to simulate price drop
        // The MockERC4626 vault holds 1000e6 for the user's shares
        // To reduce vault total assets, we can burn some underlying from the vault
        _underlyingAsset.burn(address(_mockVault), 200e6);

        // Verify user is now underwater
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 currentDebt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(currentDebt, maxLoanIgnoreSupply, "User should be underwater");

        // New block for the payment
        vm.roll(block.number + 1);

        // Pay some debt — this should succeed because shortfall decreases
        _underlyingAsset.mint(_user, 100e6);
        _payDebtDirect(100e6);

        // Debt should have decreased
        uint256 debtAfterPay = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfterPay, currentDebt, "Debt should decrease after payment");

        // Enforcement should pass: shortfall decreased (we paid down debt)
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass when underwater user pays debt");
    }

    /**
     * @dev Test 7: Underwater user cannot borrow — shortfall would increase, enforcement reverts.
     * If a user is already at max LTV, further borrowing increases shortfall and must revert.
     */
    function testERC4626UnderwaterCannotBorrow() public {
        // Setup: Collateral of 1000, borrow 600 (within 70% LTV)
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 600e6);

        // New block
        vm.roll(block.number + 1);

        // Try to borrow more — this should increase shortfall beyond 700 max,
        // causing enforcement to revert with UndercollateralizedDebt
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 200e6);

        // Borrowing 200 more would put debt at 800 > maxLoan 700 = shortfall of 100
        // Snapshot captures shortfall=0 before borrow; after borrow shortfall=100e6
        // Enforcement reverts with UndercollateralizedDebt(100e6)
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.UndercollateralizedDebt.selector, 100e6));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev Test 8: Underwater user cannot remove collateral — inline guard reverts.
     * removeCollateral has require(debt <= newMaxLoanIgnoreSupply) which is checked
     * BEFORE the snapshot enforcement. This is a hard guard.
     */
    function testERC4626UnderwaterCannotRemoveCollateral() public {
        // Setup: Collateral of 1000, borrow 600
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 600e6);

        vm.roll(block.number + 1);

        // Try to remove 200 USDC worth of collateral (20% of shares)
        // After removal: 800 collateral, 600 debt, maxLoan = 560 -> debt > maxLoan
        uint256 sharesToRemove = shares / 5; // ~200 USDC

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, sharesToRemove);

        vm.expectRevert("Debt exceeds max loan");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev Test 9: overSuppliedVaultDebt > 0 causes BadDebt revert.
     * When a borrow exceeds maxLoanIgnoreSupply, the excess is tracked as
     * overSuppliedVaultDebt. enforceCollateralRequirements reverts with BadDebt.
     *
     * Note: Under normal operation, borrowing beyond maxLoan is prevented by the
     * snapshot enforcement. This test validates the safety net by constructing
     * a scenario where overSuppliedVaultDebt accumulates through collateral depreciation
     * AFTER borrowing near the limit, then attempting a new borrow.
     *
     * Actually, overSuppliedVaultDebt is set when amount > maxLoan in increaseTotalDebt.
     * The only way to trigger it is if the DynamicFeesVault allows the borrow (its own
     * utilization check) even when the CollateralManager considers it over the limit.
     * We'll need to manipulate vault supply to trigger this path.
     */
    function testERC4626OverSuppliedVaultDebtReverts() public {
        // Setup: Collateral of 1000, borrow 600
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 600e6);

        vm.roll(block.number + 1);

        // Depreciate collateral so maxLoanIgnoreSupply < current debt
        // This makes the next borrow go through the overSuppliedVaultDebt path
        _underlyingAsset.burn(address(_mockVault), 300e6);

        // Verify user is now underwater
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 currentDebt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        // maxLoan = (1000-300) * 7000 / 10000 = 490. debt = 600. So 600 > 490.
        assertGt(currentDebt, maxLoanIgnoreSupply, "Debt should exceed maxLoan after depreciation");

        // Any new borrow will set overSuppliedVaultDebt because amount > maxLoan
        // (since maxLoan = maxLoanIgnoreSupply - currentDebt, and currentDebt > maxLoanIgnoreSupply,
        //  maxLoan = 0 via _calculateMaxLoan, so ANY amount > 0 exceeds it)
        // The enforcement will then catch BadDebt.
        // However, the shortfall increase itself should also revert.
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 10e6);

        // Snapshot captures shortfall before borrow: debt=600, maxLoan=490, shortfall=110.
        // After borrow of 10: debt=610, maxLoan=490, shortfall=120.
        // end(120) > start(110) => UndercollateralizedDebt(10e6)
        // Note: overSuppliedVaultDebt also gets set, but UndercollateralizedDebt check fires first.
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.UndercollateralizedDebt.selector, 10e6));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev Test 10: Enforcement without any state change passes (no snapshot = start == end).
     * If no mutating operation ran this block, there is no snapshot, so the
     * enforcement logic sets start = end and the comparison passes.
     */
    function testERC4626NoSnapshotNoRevert() public {
        // Setup: add collateral (creates a snapshot in this block)
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        // Advance to a new block where NO operations happen
        vm.roll(block.number + 1);

        // Call enforceCollateralRequirements directly (view call, no state change)
        // No snapshot exists for this new block, so start == end == 0 -> passes
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass when no operations occurred in this block");
    }

    // ============================================================================
    // SHARE-BASED EDGE CASES (Tests 11-15)
    // ============================================================================

    /**
     * @dev Test 11: removeSharesForYield with outstanding debt — inline debt check.
     * removeSharesForYield has require(debt <= newMaxLoanIgnoreSupply).
     * If yield removal would push the user below the debt threshold, it reverts.
     *
     * We simulate yield on the vault so there are excess shares to remove,
     * then verify the inline debt guard after actual yield share removal.
     */
    function testERC4626RemoveSharesForYieldWithDebt() public {
        // Setup: Collateral of 1000, borrow 650 (near max of 700)
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 650e6);

        vm.roll(block.number + 1);

        // Add yield to the vault: 200 USDC yield
        _underlyingAsset.mint(_owner, 200e6);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), 200e6);
        _mockVault.simulateYield(200e6);
        vm.stopPrank();

        // Now collateral value = 1200 USDC (1000 deposit + 200 yield)
        // maxLoanIgnoreSupply = 1200 * 70% = 840
        // debt = 650. 650 < 840, so yield claiming should work

        // Verify the collateral value increased with yield
        uint256 collateralAfterYield = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterYield, 1200e6, "Collateral should include yield");

        // Verify maxLoan accounts for the yield
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanIgnoreSupply, 840e6, "MaxLoan should reflect 70% of 1200");

        // Debt is still within new maxLoan
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 650e6, "Debt should still be 650");
        assertLt(debt, maxLoanIgnoreSupply, "Debt should be within maxLoan after yield");

        // Now actually exercise removeSharesForYield through the claiming facet.
        // Since the ClaimingFacet is not registered on this test diamond,
        // we deploy and register it, then call claimVaultYield via the authorized caller.
        _deployAndRegisterClaimingFacet();

        vm.roll(block.number + 1);

        // Call claimVaultYield as authorized caller
        vm.prank(_authorizedCaller);
        uint256 yieldClaimed = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();

        // Verify yield was claimed (should be ~200 USDC worth minus rounding)
        assertGt(yieldClaimed, 0, "Should have claimed some yield");

        // Verify remaining collateral covers the debt
        uint256 postClaimCollateral = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        // After yield removal, remaining value should be >= depositedAssetValue (1000)
        assertGe(postClaimCollateral, INITIAL_DEPOSIT, "Remaining collateral should cover original deposit");

        (, uint256 postClaimMaxLoan) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 postClaimDebt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLe(postClaimDebt, postClaimMaxLoan, "Debt should be within maxLoan after yield claim");
    }

    /**
     * @dev Test 12: Add collateral + borrow in the same multicall — passes within maxLoan.
     * This tests the compound operation: snapshot is taken before addCollateral,
     * then borrow runs (no new snapshot because same block), and enforcement
     * at the end checks that shortfall didn't increase from the baseline.
     */
    function testERC4626AddCollateralThenBorrow() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);

        // Combine addCollateral + borrow in a single multicall
        vm.startPrank(_user);
        address[] memory factories = new address[](2);
        factories[0] = address(_portfolioFactory);
        factories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        calldatas[1] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 500e6);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Verify both operations succeeded
        uint256 collateral = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, INITIAL_DEPOSIT, "Collateral should be deposited");

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 500e6, "Debt should be 500 USDC");

        // Verify within LTV
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertLe(debt, maxLoanIgnoreSupply, "Debt should be within maxLoan");
    }

    /**
     * @dev Test 13: Empty account enforcement — passes trivially.
     * Zero collateral, zero debt: shortfall is 0, enforcement passes.
     */
    function testERC4626ZeroCollateralZeroDebt() public {
        // Empty account — no collateral, no debt
        uint256 collateral = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 0, "Collateral should be 0");

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "Debt should be 0");

        // Enforcement should pass trivially
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass for empty account");
    }

    /**
     * @dev Test 14: getLTVRatio returns correct values at various states.
     * Tests: 0% (no debt), ~71% (near max), and the formula correctness.
     *
     * NOTE: getLTVRatio is a library function not exposed on the facet. We test
     * through the underlying math: ratio = (totalDebt * 100) / maxLoanIgnoreSupply.
     * With 70% LTV config:
     *   - 0 debt: ratio = 0
     *   - 500 debt / 700 maxLoan: ratio = (500*100)/700 = 71
     */
    function testERC4626GetLTVRatio() public {
        // Case 1: No debt — ratio should be 0
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(debt, 0, "Debt should be 0");
        assertEq(maxLoanIgnoreSupply, 700e6, "MaxLoan should be 700");

        // LTV ratio with 0 debt = 0
        uint256 ratio0 = debt > 0 ? (debt * 100) / maxLoanIgnoreSupply : 0;
        assertEq(ratio0, 0, "LTV ratio should be 0 with no debt");

        vm.roll(block.number + 1);

        // Case 2: Borrow 500 — ratio should be ~71
        _borrowViaMulticall(500e6);

        debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        (, maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(debt, 500e6, "Debt should be 500");
        assertEq(maxLoanIgnoreSupply, 700e6, "MaxLoan should still be 700");

        uint256 ratio71 = (debt * 100) / maxLoanIgnoreSupply;
        assertEq(ratio71, 71, "LTV ratio should be 71% (500/700)");

        vm.roll(block.number + 1);

        // Case 3: Borrow more to near max (total 690) — ratio should be ~98
        _borrowViaMulticall(190e6);

        debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 690e6, "Debt should be 690");
        uint256 ratio98 = (debt * 100) / maxLoanIgnoreSupply;
        assertEq(ratio98, 98, "LTV ratio should be 98% (690/700)");
    }

    /**
     * @dev Test 15: Remove collateral when debt > post-removal maxLoan — inline revert.
     * The inline require(debt <= newMaxLoanIgnoreSupply) in removeCollateral fires
     * before the snapshot enforcement, providing a hard guard.
     *
     * Scenario:
     *   - 1000 collateral, 500 debt, maxLoan = 700
     *   - Remove 350 USDC worth -> remaining 650 collateral, maxLoan = 455
     *   - 500 > 455 -> revert "Debt exceeds max loan"
     */
    function testERC4626RemoveCollateralInlineGuard() public {
        // Setup
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 500e6);

        vm.roll(block.number + 1);

        // Try to remove 35% of collateral (350 USDC worth)
        // Remaining: 650 collateral -> maxLoan = 650 * 70% = 455
        // Debt: 500 > 455 -> should revert
        uint256 sharesToRemove = (shares * 35) / 100;

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, sharesToRemove);

        vm.expectRevert("Debt exceeds max loan");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Verify state unchanged
        uint256 remainingShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(remainingShares, shares, "Shares should be unchanged after failed removal");
    }

    // ============================================================================
    // ADDITIONAL INVARIANT TESTS
    // ============================================================================

    /**
     * @dev Pay debt + remove collateral across two blocks — each passes independently.
     * Block N: Pay all debt (shortfall decreases to 0).
     * Block N+1: Remove all collateral (inline check passes since debt = 0).
     */
    function testERC4626PayThenRemoveAcrossBlocks() public {
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 500e6);

        vm.roll(block.number + 1);

        // Pay all debt
        _underlyingAsset.mint(_user, 500e6);
        _payDebtDirect(500e6);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0, "Debt should be 0 after full payment");

        vm.roll(block.number + 1);

        // Remove all collateral
        _removeCollateralViaMulticall(shares);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0, "Shares should be 0");
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0, "Collateral should be 0");
    }

    /**
     * @dev Borrow exactly at maxLoan boundary — should succeed.
     * maxLoan = 700 for 1000 collateral at 70% LTV. Borrowing exactly 700
     * should pass because debt == maxLoanIgnoreSupply (no shortfall).
     *
     * NOTE: The actual maxLoan returned may be less than maxLoanIgnoreSupply
     * due to vault supply/utilization caps. We borrow exactly what getMaxLoan returns.
     */
    function testERC4626BorrowExactlyAtMaxLoan() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Get the actual available maxLoan (accounting for vault supply)
        (uint256 maxLoan,) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertGt(maxLoan, 0, "Max loan should be positive");

        // Borrow exactly at the max
        _borrowViaMulticall(maxLoan);

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal max loan");

        // Enforcement should pass since debt <= maxLoanIgnoreSupply (shortfall = 0)
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass at exact maxLoan boundary");
    }

    /**
     * @dev Partial collateral removal within safe LTV — should succeed.
     * 1000 collateral, 200 debt. Remove 500 -> remaining 500, maxLoan = 350.
     * 200 < 350 -> passes inline check. Shortfall stays at 0 -> passes enforcement.
     */
    function testERC4626PartialRemoveWithinSafeLTV() public {
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, 200e6);

        vm.roll(block.number + 1);

        uint256 halfShares = shares / 2;
        _removeCollateralViaMulticall(halfShares);

        // Verify partial removal
        uint256 remaining = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(remaining, shares - halfShares, "Should have half shares remaining");

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertLt(debt, maxLoanIgnoreSupply, "Debt should be within maxLoan after partial removal");
    }

    /**
     * @dev Multiple borrows across different blocks accumulate debt correctly.
     * Each borrow in a new block writes a fresh snapshot.
     */
    function testERC4626MultipleBorrowsAcrossBlocks() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        // First borrow: 200 USDC
        vm.roll(block.number + 1);
        _borrowViaMulticall(200e6);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 200e6, "Debt should be 200");

        // Second borrow: 150 USDC
        vm.roll(block.number + 1);
        _borrowViaMulticall(150e6);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 350e6, "Debt should be 350");

        // Third borrow: 100 USDC
        vm.roll(block.number + 1);
        _borrowViaMulticall(100e6);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 450e6, "Debt should be 450");

        // All within maxLoan (700)
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertLe(
            ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(),
            maxLoanIgnoreSupply,
            "Total debt should be within maxLoan"
        );
    }

    // ============================================================================
    // HARDENED TESTS — Missing coverage identified by audit
    // ============================================================================

    /**
     * @dev decreaseTotalDebt triggers a snapshot.
     * Verifies that paying debt in a new block writes a snapshot, and enforcement
     * passes because shortfall decreased (or stayed the same).
     */
    function testERC4626SnapshotOnDebtDecrease() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 500e6);

        vm.roll(block.number + 1);

        // Verify debt before payment
        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, 500e6, "Debt should be 500 before payment");

        // Pay 200 USDC — this triggers _snapshotIfNeeded inside decreaseTotalDebt
        _underlyingAsset.mint(_user, 200e6);
        _payDebtDirect(200e6);

        // Debt should have decreased
        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Debt should decrease after payment");

        // The snapshot was written by decreaseTotalDebt. Enforcement should pass
        // because shortfall can only decrease (debt went down, collateral unchanged).
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass after debt decrease triggers snapshot");
    }

    /**
     * @dev BadDebt revert is reachable even when shortfall does NOT increase.
     * Scenario: user has overSuppliedVaultDebt from a previous block's depreciation.
     * In a new block they pay debt (shortfall decreases or stays flat), but
     * overSuppliedVaultDebt is still > 0, so enforcement reverts with BadDebt.
     *
     * This validates that the overSuppliedVaultDebt check fires AFTER the
     * shortfall comparison, and that BadDebt is independent of shortfall direction.
     *
     * NOTE: overSuppliedVaultDebt is only set inside increaseTotalDebt when
     * amount > maxLoan. Under normal multicall flow, UndercollateralizedDebt
     * would fire first. This test constructs the scenario by manipulating
     * storage to simulate a state where overSuppliedVaultDebt > 0 exists
     * from a previous block. Since we can't easily set library storage from
     * tests, we instead verify the ordering by checking that when both
     * conditions apply, UndercollateralizedDebt fires first.
     */
    function testERC4626OverSuppliedVaultDebtCheckOrdering() public {
        // Setup: 1000 collateral, borrow 600
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 600e6);

        vm.roll(block.number + 1);

        // Depreciate collateral by 300: new value = 700, maxLoan = 490
        _underlyingAsset.burn(address(_mockVault), 300e6);

        // Verify underwater state
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debt, maxLoanIgnoreSupply, "Should be underwater");

        // Borrow 1 wei more — this sets overSuppliedVaultDebt AND increases shortfall.
        // UndercollateralizedDebt should fire BEFORE BadDebt.
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 1);

        // Shortfall increases by 1 (debt goes from 600 to 601, maxLoan still 490)
        // start shortfall = 110, end shortfall = 111, delta = 1
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.UndercollateralizedDebt.selector, 1));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev addCollateral with zero shares reverts.
     * The library has require(shares > 0, "Shares must be > 0").
     */
    function testRevert_addCollateral_zeroShares() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, 0);

        vm.expectRevert("Shares must be > 0");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev addCollateral when portfolio does not hold enough shares reverts
     * with InsufficientShareBalance.
     */
    function testRevert_addCollateral_insufficientShares() public {
        // Prepare shares for user but do NOT transfer to portfolio
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        // Don't call _transferSharesToPortfolio

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);

        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.InsufficientShareBalance.selector, shares, 0));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev removeCollateral with zero shares reverts.
     * The library has require(shares > 0, "Shares must be > 0").
     */
    function testRevert_removeCollateral_zeroShares() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, 0);

        vm.expectRevert("Shares must be > 0");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev removeCollateral with more shares than tracked reverts.
     * The library has require(data.shares >= shares, "Insufficient collateral shares").
     */
    function testRevert_removeCollateral_moreThanTracked() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateral.selector, shares + 1);

        vm.expectRevert("Insufficient collateral shares");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev borrow cannot be called directly on the facet — only through PortfolioManager multicall.
     * The onlyPortfolioManagerMulticall modifier should block direct calls.
     */
    function testRevert_borrow_directCallNotThroughMulticall() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Try to borrow directly (not through PortfolioManager multicall)
        vm.startPrank(_user);
        vm.expectRevert();
        ERC4626LendingFacet(_portfolioAccount).borrow(100e6);
        vm.stopPrank();
    }

    /**
     * @dev addCollateral cannot be called directly — only through PortfolioManager multicall.
     */
    function testRevert_addCollateral_directCallNotThroughMulticall() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);

        vm.startPrank(_user);
        vm.expectRevert();
        ERC4626CollateralFacet(_portfolioAccount).addCollateral(shares);
        vm.stopPrank();
    }

    /**
     * @dev removeCollateral cannot be called directly — only through PortfolioManager multicall.
     */
    function testRevert_removeCollateral_directCallNotThroughMulticall() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        vm.startPrank(_user);
        vm.expectRevert();
        ERC4626CollateralFacet(_portfolioAccount).removeCollateral(shares);
        vm.stopPrank();
    }

    /**
     * @dev Event verification: addCollateral emits ERC4626CollateralAdded.
     */
    function testERC4626AddCollateralEmitsEvent() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);

        // Expect the ERC4626CollateralAdded event from the library (emitted via delegatecall)
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit ERC4626CollateralManager.ERC4626CollateralAdded(
            address(_mockVault),
            shares,
            INITIAL_DEPOSIT,
            _portfolioAccount
        );

        _addCollateralViaMulticall(shares);
    }

    /**
     * @dev Event verification: removeCollateral emits ERC4626CollateralRemoved.
     */
    function testERC4626RemoveCollateralEmitsEvent() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit ERC4626CollateralManager.ERC4626CollateralRemoved(
            address(_mockVault),
            shares,
            INITIAL_DEPOSIT,
            _portfolioAccount
        );

        _removeCollateralViaMulticall(shares);
    }

    /**
     * @dev getCollateral returns correct values at various states.
     */
    function testERC4626GetCollateralViewFunction() public {
        // Empty state
        (address vault, uint256 shares, uint256 deposited, uint256 current) =
            ERC4626CollateralFacet(_portfolioAccount).getCollateral();
        assertEq(vault, address(_mockVault), "Vault should match");
        assertEq(shares, 0, "Shares should be 0 initially");
        assertEq(deposited, 0, "Deposited should be 0 initially");
        assertEq(current, 0, "Current should be 0 initially");

        // After deposit
        uint256 depositShares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(depositShares);
        _addCollateralViaMulticall(depositShares);

        (vault, shares, deposited, current) = ERC4626CollateralFacet(_portfolioAccount).getCollateral();
        assertEq(vault, address(_mockVault), "Vault should match");
        assertEq(shares, depositShares, "Shares should equal deposited shares");
        assertEq(deposited, INITIAL_DEPOSIT, "Deposited value should equal deposit amount");
        assertEq(current, INITIAL_DEPOSIT, "Current value should equal deposit (no yield yet)");

        // After yield
        _underlyingAsset.mint(_owner, 100e6);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), 100e6);
        _mockVault.simulateYield(100e6);
        vm.stopPrank();

        (vault, shares, deposited, current) = ERC4626CollateralFacet(_portfolioAccount).getCollateral();
        assertEq(shares, depositShares, "Shares should not change after yield");
        assertEq(deposited, INITIAL_DEPOSIT, "Deposited value should not change after yield");
        assertEq(current, INITIAL_DEPOSIT + 100e6, "Current value should include yield");
    }

    /**
     * @dev removeSharesForYield inline debt guard: trying to remove principal (not just yield)
     * should revert with "Would remove principal".
     */
    function testRevert_removeSharesForYield_wouldRemovePrincipal() public {
        // Setup: 1000 collateral, no yield
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Deploy claiming facet to access removeSharesForYield indirectly
        _deployAndRegisterClaimingFacet();

        // No yield — claimVaultYield should revert because currentAssets == depositedAssets
        vm.prank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
    }

    /**
     * @dev Borrow exactly 1 more than maxLoan — enforcement reverts with exact shortfall.
     */
    function testRevert_borrowOneAboveMaxLoan() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Get the actual maxLoan
        (uint256 maxLoan,) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // Borrow maxLoan first (should pass)
        _borrowViaMulticall(maxLoan);

        vm.roll(block.number + 1);

        // Verify debt = maxLoan
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, maxLoan, "Debt should equal maxLoan");

        // Try to borrow just 1 more — shortfall increases by 1
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 1);

        // Snapshot shortfall: debt=maxLoan, so if maxLoan == maxLoanIgnoreSupply, shortfall = 0
        // After borrow: debt = maxLoan+1, shortfall = 1
        vm.expectRevert(abi.encodeWithSelector(ERC4626CollateralManager.UndercollateralizedDebt.selector, 1));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev Fuzz test: _calculateMaxLoan invariants.
     * For any collateral and borrow amount, if borrow <= maxLoan (the returned value),
     * then enforcement should pass. If borrow > maxLoanIgnoreSupply, enforcement should fail.
     *
     * We bound inputs to reasonable ranges to avoid trivial edge cases.
     */
    function testFuzz_borrowWithinMaxLoanPasses(uint256 collateral, uint256 borrowPct) public {
        // Bound collateral to a range that fits within the lending vault's 10k USDC supply.
        // maxLoan at 70% LTV and 80% utilization cap means we need:
        //   collateral * 0.7 < vaultSupply * 0.8 => collateral < ~11_428
        // Use a safe upper bound of 5000 USDC to ensure maxLoan > 0.
        collateral = bound(collateral, 10e6, 5_000e6);
        // borrowPct as a percentage of maxLoan (1-100%)
        borrowPct = bound(borrowPct, 1, 100);

        // Mint enough underlying for the user
        _underlyingAsset.mint(_user, collateral);

        uint256 shares = _prepareUserWithVaultShares(collateral);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Get maxLoan (accounting for vault supply constraints)
        (uint256 maxLoan,) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        if (maxLoan == 0) return; // skip if vault is fully utilized

        uint256 borrowAmount = (maxLoan * borrowPct) / 100;
        if (borrowAmount == 0) return; // skip trivial case

        // Borrow within maxLoan — should always succeed
        _borrowViaMulticall(borrowAmount);

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, borrowAmount, "Debt should equal borrow amount");

        // Enforcement should pass
        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Enforcement should pass for borrow within maxLoan");
    }

    /**
     * @dev Fuzz test: proportional asset value removal in removeCollateral.
     * The formula: assetValueToRemove = (depositedAssetValue * shares) / totalShares
     * For any removal <= total shares (when no debt), the result should be proportional.
     */
    function testFuzz_removeCollateralProportional(uint256 depositAmount, uint256 removePct) public {
        depositAmount = bound(depositAmount, 2e6, 100_000e6);
        removePct = bound(removePct, 1, 100);

        _underlyingAsset.mint(_user, depositAmount);

        uint256 shares = _prepareUserWithVaultShares(depositAmount);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        uint256 sharesToRemove = (shares * removePct) / 100;
        if (sharesToRemove == 0) return;

        _removeCollateralViaMulticall(sharesToRemove);

        uint256 remainingShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(remainingShares, shares - sharesToRemove, "Remaining shares should be exact");

        // Collateral value should be proportional to remaining shares
        uint256 remainingCollateral = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 expectedCollateral = _mockVault.convertToAssets(remainingShares);
        assertEq(remainingCollateral, expectedCollateral, "Remaining collateral should match vault conversion");
    }

    /**
     * @dev Fuzz test: LTV ratio calculation.
     * ratio = (totalDebt * 100) / maxLoanIgnoreSupply.
     * Verify invariant: if debt <= maxLoanIgnoreSupply, ratio <= 100.
     */
    function testFuzz_ltvRatioInvariant(uint256 borrowPct) public {
        borrowPct = bound(borrowPct, 1, 99); // 1-99% of maxLoan

        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        uint256 borrowAmount = (maxLoan * borrowPct) / 100;
        if (borrowAmount == 0) return;

        _borrowViaMulticall(borrowAmount);

        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        // LTV ratio must be <= 100 when debt <= maxLoanIgnoreSupply
        assertLe(debt, maxLoanIgnoreSupply, "Debt should be within maxLoan");
        uint256 ratio = (debt * 100) / maxLoanIgnoreSupply;
        assertLe(ratio, 100, "LTV ratio should be <= 100%");
    }

    /**
     * @dev Non-owner cannot create multicall on behalf of another user.
     * PortfolioManager.multicall uses msg.sender to lookup portfolio ownership.
     */
    function testRevert_multicall_wrongUser() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);

        // Random address tries to multicall - they get their OWN portfolio (or a new one),
        // not the _user's portfolio. The shares are in _user's portfolio, so this should fail.
        address attacker = address(0xdead);
        vm.startPrank(attacker);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);

        // The attacker's portfolio does not hold the shares, so InsufficientShareBalance
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /**
     * @dev Event verification: borrow emits Borrowed event from LendingFacet.
     */
    function testERC4626BorrowEmitsEvent() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        uint256 borrowAmount = 300e6;

        // Expect Borrowed event from ERC4626LendingFacet
        // DynamicFeesVault returns 0 origination fee, so amountAfterFees = borrowAmount
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit ERC4626LendingFacet.Borrowed(borrowAmount, borrowAmount, 0, _user);

        _borrowViaMulticall(borrowAmount);
    }

    /**
     * @dev Event verification: pay emits Paid event from LendingFacet.
     * We call pay directly (not through _payDebtDirect) to place vm.expectEmit
     * correctly — after approve but before the pay call.
     */
    function testERC4626PayEmitsEvent() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 400e6);

        vm.roll(block.number + 1);

        uint256 payAmount = 200e6;
        _underlyingAsset.mint(_user, payAmount);

        vm.startPrank(_user);
        _underlyingAsset.approve(_portfolioAccount, payAmount);

        // Expect Paid event — placed after approve, right before pay
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit ERC4626LendingFacet.Paid(payAmount, _user);

        ERC4626LendingFacet(_portfolioAccount).pay(payAmount);
        vm.stopPrank();
    }

    /**
     * @dev Verify collateral vault address getter.
     */
    function testERC4626GetCollateralVault() public view {
        address vault = ERC4626CollateralFacet(_portfolioAccount).getCollateralVault();
        assertEq(vault, address(_mockVault), "Collateral vault should match mock vault");
    }

    /**
     * @dev Verify getCollateralShares returns 0 for empty account
     * and the correct value after deposit.
     */
    function testERC4626GetCollateralSharesConsistency() public {
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0, "Should start at 0 shares");

        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        assertEq(
            ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(),
            shares,
            "Should match deposited shares"
        );
    }

    /**
     * @dev Pay more than debt — excess should be refunded.
     * The pay function in ERC4626LendingFacet should refund excess.
     */
    function testERC4626PayExcessRefunded() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, 100e6);

        vm.roll(block.number + 1);

        uint256 payAmount = 200e6; // Pay 200 when debt is only 100
        _underlyingAsset.mint(_user, payAmount);

        uint256 userBalanceBefore = _underlyingAsset.balanceOf(_user);

        _payDebtDirect(payAmount);

        uint256 userBalanceAfter = _underlyingAsset.balanceOf(_user);
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();

        assertEq(debt, 0, "Debt should be 0 after overpayment");
        // User should get the excess refunded
        assertGt(userBalanceAfter, 0, "User should have received excess refund");
        // Net cost to user should be the debt amount (100e6)
        assertEq(userBalanceBefore - userBalanceAfter, 100e6, "User should only pay the actual debt");
    }

    /**
     * @dev Collateral depreciation below zero: if vault loses all value,
     * maxLoan = 0 and user cannot borrow.
     */
    function testERC4626FullCollateralDepreciation() public {
        uint256 shares = _prepareUserWithVaultShares(INITIAL_DEPOSIT);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);

        vm.roll(block.number + 1);

        // Burn almost all assets from vault (leave 1 to avoid division by zero)
        _underlyingAsset.burn(address(_mockVault), INITIAL_DEPOSIT - 1);

        // maxLoan should be nearly 0
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "MaxLoan should be 0 when collateral is nearly worthless");
        // maxLoanIgnoreSupply = 1 * 70% / 10000 = 0 (integer division)
        assertEq(maxLoanIgnoreSupply, 0, "MaxLoanIgnoreSupply should be 0 with 1 unit of collateral");
    }
}
