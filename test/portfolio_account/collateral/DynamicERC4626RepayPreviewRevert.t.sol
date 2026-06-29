// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * DynamicERC4626CollateralManager -- repay must never revert on paused src
 * ==========================================================================
 *
 * Same asymmetry as the regular ERC4626 manager, validated for the Dynamic
 * (live-debt-read) variant whose lending pool is a DynamicFeesVault.
 *
 * The repay path (decreaseTotalDebt -> _snapshotIfNeededRepay) wraps the
 * external collateral read (previewRedeem) in try/catch: a paused collateral
 * vault skips the shortfall snapshot and the repay proceeds. The borrow path
 * (increaseTotalDebt -> _snapshotIfNeeded -> getMaxLoan -> previewRedeem) uses
 * the strict read and still reverts when the collateral vault is paused.
 *
 * Mirrors test/portfolio_account/collateral/ERC4626RepayPreviewRevert.t.sol,
 * swapping in the Dynamic ERC4626 collateral + lending facets.
 * ==========================================================================
 */

import {Test} from "forge-std/Test.sol";
import {DynamicERC4626CollateralFacet} from "../../../src/facets/account/erc4626/DynamicERC4626CollateralFacet.sol";
import {DynamicERC4626LendingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626LendingFacet.sol";
import {DeployDynamicERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626CollateralFacet.s.sol";
import {DeployDynamicERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployDynamicERC4626LendingFacet.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployERC4626PortfolioFactoryConfig} from "../../../script/portfolio_account/DeployERC4626PortfolioFactoryConfig.s.sol";
import {ERC4626PortfolioFactoryConfig} from "../../../src/facets/account/erc4626/ERC4626PortfolioFactoryConfig.sol";
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
 * @title DynamicERC4626RepayPreviewRevertTest
 * @dev Dynamic ERC4626 diamond (DynamicFeesVault-backed lending). Pausable
 *      collateral mock whose previewRedeem reverts while paused. Proves a repay
 *      must succeed even when the collateral preview path reverts, while a borrow
 *      under the same pause must still revert.
 */
contract DynamicERC4626RepayPreviewRevertTest is Test {
    DynamicERC4626CollateralFacet public _collateralFacet;
    DynamicERC4626LendingFacet public _lendingFacet;
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
            bytes32(keccak256(abi.encodePacked("dynamic-erc4626-repay-preview-revert-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        DeployERC4626PortfolioFactoryConfig configDeployer = new DeployERC4626PortfolioFactoryConfig();
        (_portfolioFactoryConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy(address(_portfolioFactory), _owner);

        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);

        // Pausable collateral vault -- previewRedeem reverts while paused.
        _mockVault = new MockPausableERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        _setupLendingInfrastructure();

        DeployDynamicERC4626CollateralFacet deployer = new DeployDynamicERC4626CollateralFacet();
        _collateralFacet = deployer.deploy(address(_portfolioFactory), address(_mockVault));

        DeployDynamicERC4626LendingFacet lendingDeployer = new DeployDynamicERC4626LendingFacet();
        _lendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_underlyingAsset), address(_mockVault));

        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000); // 70% LTV
        _loanConfig.setLtv(7000); // 70% LTV
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioFactoryConfig.setLoanContract(_loanContract);
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));
        ERC4626PortfolioFactoryConfig(address(_portfolioFactoryConfig)).setCollateralVault(address(_mockVault));

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
            "Dynamic ERC4626 Lending Vault",
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

    // ============ Helpers ============

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
        calldatas[0] = abi.encodeWithSelector(DynamicERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _payDebtDirect(uint256 amount) internal {
        vm.startPrank(_user);
        _underlyingAsset.approve(_portfolioAccount, amount);
        DynamicERC4626LendingFacet(_portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    function _setupCollateralAndDebt(uint256 collateralAmount, uint256 borrowAmount) internal returns (uint256 shares) {
        shares = _prepareUserWithVaultShares(collateralAmount);
        _transferSharesToPortfolio(shares);
        _addCollateralViaMulticall(shares);
        vm.roll(block.number + 1);
        _borrowViaMulticall(borrowAmount);
    }

    function _debt() internal view returns (uint256) {
        return DynamicERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
    }

    // ============================================================================
    // 1. REPAY succeeds when collateral previewRedeem reverts.
    // ============================================================================

    /**
     * @dev Repay must succeed when the collateral vault's previewRedeem reverts.
     *      decreaseTotalDebt -> _snapshotIfNeededRepay catches the paused read,
     *      skips the shortfall snapshot, and proceeds with the payment.
     */
    function test_repay_succeeds_whenCollateralPreviewReverts() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);

        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "Debt should be 500 before repay");

        // Pause the collateral vault: previewRedeem reverts("paused").
        _mockVault.setPaused(true);
        vm.expectRevert(bytes("paused"));
        _mockVault.previewRedeem(1);

        _underlyingAsset.mint(_user, 200e6);
        _payDebtDirect(200e6);

        uint256 debtAfter = _debt();
        assertLt(debtAfter, debtBefore, "Repay must reduce debt even when collateral preview reverts");
    }

    // ============================================================================
    // 2. ASYMMETRY: BORROW reverts when collateral previewRedeem reverts.
    // ============================================================================

    /**
     * @dev Borrow must REVERT when the collateral vault is paused. The borrow path
     *      walks the strict previewRedeem (increaseTotalDebt -> _snapshotIfNeeded ->
     *      getMaxLoan -> getTotalCollateralValue -> previewRedeem), which bubbles
     *      "paused" out of the multicall. Proves the fix did not weaken the
     *      borrow-side gate on the Dynamic variant.
     */
    function test_borrow_reverts_whenCollateralPreviewReverts() public {
        uint256 shares = _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);
        assertGt(shares, 0, "harness should have collateral");

        vm.roll(block.number + 1);

        _mockVault.setPaused(true);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicERC4626LendingFacet.borrow.selector, 1e6);
        vm.expectRevert(bytes("paused"));
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        assertEq(_debt(), BORROW_AMOUNT, "Borrow must not increase debt when collateral preview reverts");
    }

    // ============================================================================
    // 3. FRESH-DEBT regression: repay pays against live debt while paused.
    // ============================================================================

    /**
     * @dev With collateral paused, a repay must REDUCE the on-chain debt by the
     *      paid amount -- proving the live-debt read and the payment to the pool
     *      ran even though the collateral snapshot was skipped.
     *
     *      The Dynamic manager reads debt live from the pool and sizes the payment
     *      to the pre-call balance; DynamicFeesVault may vest rewards during the
     *      payFromPortfolio call, which can decrement debt by MORE than the explicit
     *      payment. To stay robust against vesting we (a) freeze the test at the
     *      borrow epoch with no reward stream deposited, so no vesting fires, and
     *      (b) assert a strict decrease of at least the paid amount on both the
     *      manager view and the pool's getDebtBalance. The exact-equality check is
     *      kept as the primary assertion because no rewards are streaming here; if a
     *      future change introduces vesting into this path it will surface as the
     *      strict-decrease lower bound rather than a brittle exact failure.
     */
    function test_repay_paysAgainstFreshDebt_whenCollateralPaused() public {
        _setupCollateralAndDebt(INITIAL_DEPOSIT, BORROW_AMOUNT);

        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "Debt should be 500 before repay");

        uint256 poolDebtBefore = ILendingPool(_loanContract).getDebtBalance(_portfolioAccount);
        assertEq(poolDebtBefore, debtBefore, "local view equals pool debt pre-repay");

        _mockVault.setPaused(true);

        uint256 amountPaid = 200e6;
        _underlyingAsset.mint(_user, amountPaid);
        _payDebtDirect(amountPaid);

        uint256 debtAfter = _debt();
        uint256 poolDebtAfter = ILendingPool(_loanContract).getDebtBalance(_portfolioAccount);

        // Strict lower bound: repay reduced debt by AT LEAST the paid amount
        // (robust even if reward vesting were to decrement more).
        assertLe(debtAfter, debtBefore - amountPaid, "debt reduced by at least the paid amount (manager view)");
        assertLe(poolDebtAfter, poolDebtBefore - amountPaid, "debt reduced by at least the paid amount (pool)");

        // No reward stream is active here, so the reduction is exactly the payment.
        assertEq(debtAfter, debtBefore - amountPaid, "manager debt drops by exactly the paid amount");
        assertEq(poolDebtAfter, poolDebtBefore - amountPaid, "pool debt drops by exactly the paid amount");
    }
}
