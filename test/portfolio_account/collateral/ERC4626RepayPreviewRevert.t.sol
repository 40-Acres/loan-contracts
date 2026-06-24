// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * BUG REPRO -- Repay blocked by reverting collateral previewRedeem
 * ==========================================================================
 *
 * ERC4626CollateralManager.decreaseTotalDebt(config, vault, amount) calls
 * _snapshotIfNeeded() at the top. On the first mutating op of a block that
 * walks:
 *   _snapshotIfNeeded -> _currentShortfall -> getMaxLoan
 *     -> getTotalCollateralValue -> _resolveCollateralValue
 *     -> IERC4626(vault).previewRedeem(shares)
 *
 * If the collateral vault's previewRedeem reverts (paused / emergency mode),
 * the ENTIRE repay reverts -- even though the payment itself goes through the
 * lending pool, not the collateral vault, and never needs the collateral read.
 *
 * The production code documents this is wrong: _resolveCollateralValue's
 * docstring says "repay paths are unaffected" and the snapshot is only a
 * baseline for enforceCollateralRequirements to catch ops that WORSEN
 * shortfall. A repay strictly reduces debt and never needs it.
 *
 * EXPECTED on current (broken) code:
 *   - test_repay_succeeds_whenCollateralPreviewReverts  -> FAILS (pay reverts "paused")
 *   - test_repay_succeeds_whenCollateralUnpaused        -> PASSES (sanity / harness sound)
 * ==========================================================================
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockPausableERC4626} from "../../mocks/MockPausableERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ERC4626RepayPreviewRevertTest
 * @dev Reuses the snapshot-harness setUp pattern but swaps in a pausable
 *      collateral mock whose previewRedeem reverts while paused. Proves that a
 *      repay must succeed even when the collateral preview path reverts.
 */
contract ERC4626RepayPreviewRevertTest is Test {
    ERC4626CollateralFacet public _erc4626CollateralFacet;
    ERC4626LendingFacet public _erc4626LendingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    MockERC20 public _underlyingAsset;
    MockPausableERC4626 public _mockVault;

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

        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-repay-preview-revert-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);

        // Pausable collateral vault -- only difference from the snapshot harness.
        _mockVault = new MockPausableERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        _setupLendingInfrastructure();

        DeployERC4626CollateralFacet deployer = new DeployERC4626CollateralFacet();
        _erc4626CollateralFacet = deployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _erc4626LendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000); // 70% LTV
        _loanConfig.setLtv(7000); // 70% LTV
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioFactoryConfig.setLoanContract(_loanContract);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        _portfolioAccount = _portfolioFactory.createAccount(_user);

        _underlyingAsset.mint(_user, INITIAL_DEPOSIT * 10);

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

    // ============ Helpers (mirror the snapshot harness) ============

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
        vm.roll(block.number + 1);
        _borrowViaMulticall(borrowAmount);
    }

    // ============================================================================
    // BUG REPRO
    // ============================================================================

    /**
     * @dev BUG: repay reverts when the collateral vault's previewRedeem reverts.
     *
     * Setup: 1000 collateral, 500 debt (within 70% LTV) in earlier blocks.
     * Advance a block, pause the collateral vault so previewRedeem reverts,
     * then repay part of the debt.
     *
     * A repay only reduces debt and pays the lending pool -- it must NOT depend
     * on the collateral preview. This test expects the repay to SUCCEED.
     *
     * On current (broken) code, decreaseTotalDebt -> _snapshotIfNeeded ->
     * _currentShortfall -> getMaxLoan -> getTotalCollateralValue ->
     * _resolveCollateralValue -> previewRedeem REVERTS("paused"), bubbling out of
     * pay(). The test therefore FAILS here (the pay call reverts with "paused").
     */
    function test_repay_succeeds_whenCollateralPreviewReverts() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);

        // New block: this repay would be the first mutating op of the block,
        // so it takes a fresh snapshot (which walks previewRedeem).
        vm.roll(block.number + 1);

        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "Debt should be 500 before repay");

        // Pause the collateral vault: previewRedeem now reverts("paused").
        _mockVault.setPaused(true);

        // Sanity: confirm the collateral preview path is indeed broken now.
        vm.expectRevert(bytes("paused"));
        _mockVault.previewRedeem(1);

        // Repay 200 USDC. The payment flows through the lending pool, not the
        // collateral vault -- a paused collateral preview must not block it.
        _underlyingAsset.mint(_user, 200e6);
        _payDebtDirect(200e6);

        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Repay must reduce debt even when collateral preview reverts");
        assertEq(debtAfter, debtBefore - 200e6, "Debt should drop by exactly the repaid amount");
    }

    /**
     * @dev SANITY (passes on current code): same flow with the vault UNPAUSED.
     * Proves the harness itself is sound and the only variable is the preview revert.
     */
    function test_repay_succeeds_whenCollateralUnpaused() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);

        vm.roll(block.number + 1);

        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "Debt should be 500 before repay");

        // Vault NOT paused -- previewRedeem works normally.
        _underlyingAsset.mint(_user, 200e6);
        _payDebtDirect(200e6);

        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Repay reduces debt with working collateral preview");
        assertEq(debtAfter, debtBefore - 200e6, "Debt should drop by exactly the repaid amount");
    }

    // ============================================================================
    // ASYMMETRY: the repay-safe fix must NOT weaken the borrow-side gate.
    // ============================================================================

    /**
     * @dev With the collateral vault PAUSED, a BORROW must still REVERT.
     *
     * The repay path catches a reverting previewRedeem (via _snapshotIfNeededRepay
     * -> _resolveCollateralValueRepaySafe). The borrow path does NOT: it walks
     * increaseTotalDebt -> _snapshotIfNeeded -> _currentShortfall -> getMaxLoan ->
     * getTotalCollateralValue -> _resolveCollateralValue -> previewRedeem (strict).
     * A paused collateral vault must therefore propagate "paused" out of borrow.
     *
     * This proves the fix is asymmetric: repay tolerates the paused read, borrow
     * does not. Without the strict borrow-side read, a paused collateral source
     * could be used to mint borrow capacity against an unpriceable position.
     */
    function test_borrow_reverts_whenCollateralPreviewReverts() public {
        // Establish collateral + debt in earlier blocks while the vault is live.
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);
        assertGt(shares, 0, "harness should have staked collateral");

        // Fresh block so the borrow takes a new snapshot (walks the strict preview).
        vm.roll(block.number + 1);

        // Pause the collateral vault: previewRedeem reverts("paused").
        _mockVault.setPaused(true);

        // A further borrow must revert -- the strict borrow-side read propagates.
        // We assert it reverts (the bubbled string is "paused"); the multicall
        // wrapper may re-wrap, so match the underlying reason explicitly.
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, 1e6);
        vm.expectRevert(bytes("paused"));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Debt unchanged: the borrow never landed.
        assertEq(
            ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(),
            BORROW_AMOUNT,
            "Borrow must not increase debt when collateral preview reverts"
        );
    }

    // ============================================================================
    // REGRESSION: repay against fresh debt must actually reach the lending pool.
    // ============================================================================

    /**
     * @dev With collateral paused, a repay must REDUCE the on-chain debt by the
     *      paid amount -- not merely "not revert".
     *
     * decreaseTotalDebt -> _snapshotIfNeededRepay syncs debt from the lending pool
     * (live read), pays through payFromPortfolio, then re-syncs data.debt from the
     * pool's getDebtBalance. This proves the payment reached the pool and the local
     * debt mirror tracks the pool, even though the collateral snapshot was skipped.
     *
     * The lending vault here is configured with 0 origination fee and no reward
     * vesting active, so the exact-equality assertion holds. The companion strict
     * assertion (debtAfter == debtBefore - amountPaid) is the load-bearing check;
     * the assertLt is a guard against a no-op repay that silently swallows funds.
     */
    function test_repay_paysAgainstFreshDebt_whenCollateralPaused() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);

        vm.roll(block.number + 1);

        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, BORROW_AMOUNT, "Debt should be 500 before repay");

        // Pause collateral: the snapshot read is skipped, but the live debt sync
        // and the payment to the pool must still run.
        _mockVault.setPaused(true);

        uint256 amountPaid = 200e6;
        _underlyingAsset.mint(_user, amountPaid);

        // Record the lending pool's own view of the debt before paying, so the
        // assertion is anchored to the pool, not just the local mirror.
        uint256 poolDebtBefore = ILendingPool(_loanContract).getDebtBalance(_portfolioAccount);
        assertEq(poolDebtBefore, debtBefore, "local mirror should equal pool debt pre-repay");

        _payDebtDirect(amountPaid);

        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 poolDebtAfter = ILendingPool(_loanContract).getDebtBalance(_portfolioAccount);

        assertLt(debtAfter, debtBefore, "repay must strictly reduce debt");
        assertEq(debtAfter, debtBefore - amountPaid, "local debt drops by exactly the paid amount");
        assertEq(poolDebtAfter, poolDebtBefore - amountPaid, "pool debt drops by exactly the paid amount");
        assertEq(debtAfter, poolDebtAfter, "local mirror stays in sync with the pool after repay");
    }
}
