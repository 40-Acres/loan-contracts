// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/collateral/ERC4626CollateralFacet.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/collateral/ERC4626CollateralManager.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
import {DeployERC4626LendingFacet} from "../../../script/portfolio_account/facets/DeployERC4626LendingFacet.s.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/lending/ERC4626LendingFacet.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Loan} from "../../../src/Loan.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

contract ERC4626CollateralFacetTest is Test {
    ERC4626CollateralFacet public _erc4626CollateralFacet;
    ERC4626LendingFacet public _erc4626LendingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    // Config contracts
    PortfolioAccountConfig public _portfolioAccountConfig;
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
            bytes32(keccak256(abi.encodePacked("erc4626-collateral-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // Deploy config contracts
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (_portfolioAccountConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy();

        // Deploy mock underlying asset (USDC-like with 6 decimals)
        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);

        // Deploy mock ERC4626 vault for collateral
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Collateral Vault", "mCVAULT", 6);

        // Deploy lending infrastructure (loan contract and lending vault)
        _setupLendingInfrastructure();

        // Deploy and register ERC4626CollateralFacet
        DeployERC4626CollateralFacet deployer = new DeployERC4626CollateralFacet();
        _erc4626CollateralFacet = deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig));

        // Deploy and register ERC4626LendingFacet
        DeployERC4626LendingFacet lendingDeployer = new DeployERC4626LendingFacet();
        _erc4626LendingFacet = lendingDeployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_underlyingAsset));

        // Set config
        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(7000); // 70% LTV
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioAccountConfig.setLoanContract(_loanContract);
        _portfolioAccountConfig.setLoanConfig(address(_loanConfig));

        // Set authorized caller
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Mint underlying assets to user for testing
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT * 10);

        // Fund lending vault with USDC for borrowing
        _underlyingAsset.mint(_lendingVault, 10000e6);
    }

    function _setupLendingInfrastructure() internal {
        // Deploy Loan contract
        Loan loanImplementation = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImplementation), "");
        _loanContract = address(loanProxy);

        // Deploy Vault
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        Vault vault = Vault(address(vaultProxy));
        _lendingVault = address(vault);

        // Initialize vault and loan
        vault.initialize(address(_underlyingAsset), _loanContract, "Lending Vault", "lVAULT");
        Loan(_loanContract).initialize(address(vault), address(_underlyingAsset));

        // Upgrade to LoanV2
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(_loanContract).upgradeToAndCall(address(loanV2Impl), new bytes(0));
        LoanV2(_loanContract).setPortfolioFactory(address(_portfolioFactory));
    }

    // ============ Helper Functions ============

    function addCollateralViaMulticall(address vault, uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, vault, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function addCollateralFromViaMulticall(address vault, uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateralFrom.selector, vault, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function removeCollateralViaMulticall(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("removeCollateral(uint256)")), shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function removeCollateralToViaMulticall(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.removeCollateralTo.selector, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function prepareUserWithVaultShares(uint256 depositAmount) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.approve(address(_mockVault), depositAmount);
        shares = _mockVault.deposit(depositAmount, _user);
        vm.stopPrank();
    }

    function transferSharesToPortfolio(uint256 shares) internal {
        vm.startPrank(_user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();
    }

    // ============ Add Collateral Tests ============

    function testAddCollateralWithinPortfolioAccount() public {
        // User deposits to vault, transfers shares to portfolio, then adds as collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);

        addCollateralViaMulticall(address(_mockVault), shares);

        // Collateral value should equal the asset value of shares
        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT);

        // Verify collateral info
        (address vault, uint256 collateralShares, uint256 depositedValue, uint256 currentValue) =
            ERC4626CollateralFacet(_portfolioAccount).getCollateral();
        assertEq(vault, address(_mockVault));
        assertEq(collateralShares, shares);
        assertEq(depositedValue, INITIAL_DEPOSIT);
        assertEq(currentValue, INITIAL_DEPOSIT);
    }

    function testAddCollateralFromOwner() public {
        // User deposits to vault, then adds collateral directly via addCollateralFrom
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);

        // Approve portfolio account to transfer shares
        vm.startPrank(_user);
        _mockVault.approve(_portfolioAccount, shares);
        vm.stopPrank();

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);

        addCollateralFromViaMulticall(address(_mockVault), shares);

        // Verify collateral was added
        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT);

        // Shares should be in portfolio account
        assertEq(_mockVault.balanceOf(_portfolioAccount), shares);
        assertEq(_mockVault.balanceOf(_user), 0);
    }

    function testAddingCollateralTwice() public {
        // First deposit
        uint256 shares1 = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares1);
        addCollateralViaMulticall(address(_mockVault), shares1);

        // Second deposit
        uint256 shares2 = prepareUserWithVaultShares(INITIAL_DEPOSIT / 2);
        transferSharesToPortfolio(shares2);
        addCollateralViaMulticall(address(_mockVault), shares2);

        // Total collateral should be sum of both deposits
        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT + INITIAL_DEPOSIT / 2);

        uint256 totalShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(totalShares, shares1 + shares2);
    }

    function testAddCollateralRevertsWithZeroShares() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, address(_mockVault), 0);

        vm.expectRevert("Shares must be > 0");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testAddCollateralRevertsWithVaultMismatch() public {
        // Add first collateral
        uint256 shares1 = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares1);
        addCollateralViaMulticall(address(_mockVault), shares1);

        // Create a different vault
        MockERC4626 differentVault = new MockERC4626(address(_underlyingAsset), "Different Vault", "dVAULT", 6);

        // Try to add collateral from different vault - should revert
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _underlyingAsset.approve(address(differentVault), INITIAL_DEPOSIT);
        uint256 shares2 = differentVault.deposit(INITIAL_DEPOSIT, _user);
        differentVault.transfer(_portfolioAccount, shares2);
        vm.stopPrank();

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, address(differentVault), shares2);

        vm.expectRevert("Vault mismatch");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ============ Remove Collateral Tests ============

    function testRemoveCollateral() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Remove collateral
        removeCollateralViaMulticall(shares);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0);
    }

    function testRemoveCollateralTo() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 userSharesBefore = _mockVault.balanceOf(_user);

        // Remove collateral and transfer to owner
        removeCollateralToViaMulticall(shares);

        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(_mockVault.balanceOf(_user), userSharesBefore + shares);
        assertEq(_mockVault.balanceOf(_portfolioAccount), 0);
    }

    function testRemovePartialCollateral() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 removeAmount = shares / 2;
        removeCollateralViaMulticall(removeAmount);

        uint256 remainingShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(remainingShares, shares - removeAmount);

        uint256 collateralValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralValue, INITIAL_DEPOSIT / 2);
    }

    function testRemoveCollateralRevertsWithInsufficientShares() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("removeCollateral(uint256)")), shares + 1);

        vm.expectRevert("Insufficient collateral shares");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ============ Max Loan Tests ============

    function testGetMaxLoan() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // With 70% LTV and 1000 USDC collateral, max loan should be ~700 USDC
        // But capped by vault supply constraints (80% utilization)
        assertGt(maxLoanIgnoreSupply, 0);
        // maxLoanIgnoreSupply = collateralValue * LTV / 10000 = 1000e6 * 7000 / 10000 = 700e6
        assertEq(maxLoanIgnoreSupply, 700e6);
    }

    function testGetMaxLoanWithNoCollateral() public view {
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0);
        assertEq(maxLoanIgnoreSupply, 0);
    }

    // ============ View Functions Tests ============

    function testGetCollateralVault() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        address vault = ERC4626CollateralFacet(_portfolioAccount).getCollateralVault();
        assertEq(vault, address(_mockVault));
    }

    function testGetCollateralShares() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 collateralShares = ERC4626CollateralFacet(_portfolioAccount).getCollateralShares();
        assertEq(collateralShares, shares);
    }

    function testEnforceCollateralRequirementsNoDebt() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        bool success = ERC4626CollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success);
    }

    // ============ Yield Appreciation Tests ============

    function testCollateralValueIncreasesWithYield() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 initialValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // Simulate yield by adding assets to vault
        uint256 yieldAmount = 100e6; // 100 USDC yield
        _underlyingAsset.mint(_owner, yieldAmount);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yieldAmount);
        _mockVault.simulateYield(yieldAmount);
        vm.stopPrank();

        uint256 newValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // Value should have increased
        assertGt(newValue, initialValue);
        assertEq(newValue, INITIAL_DEPOSIT + yieldAmount);
    }

    function testMaxLoanIncreasesWithYield() public {
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        (, uint256 initialMaxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // Simulate yield
        uint256 yieldAmount = 100e6;
        _underlyingAsset.mint(_owner, yieldAmount);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yieldAmount);
        _mockVault.simulateYield(yieldAmount);
        vm.stopPrank();

        (, uint256 newMaxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();

        // Max loan should have increased proportionally
        assertGt(newMaxLoanIgnoreSupply, initialMaxLoanIgnoreSupply);
        // New max = (1000 + 100) * 70% = 770
        assertEq(newMaxLoanIgnoreSupply, 770e6);
    }

    // ============ Debt and Unpaid Fees Tests ============

    function testGetTotalDebtInitiallyZero() public view {
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 0);
    }

    function testGetUnpaidFeesInitiallyZero() public view {
        uint256 fees = ERC4626CollateralFacet(_portfolioAccount).getUnpaidFees();
        assertEq(fees, 0);
    }

    // ============ Helper Functions for Lending ============

    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, amount);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function payDebt(uint256 amount) internal {
        vm.startPrank(_user);
        _underlyingAsset.approve(_portfolioAccount, amount);
        ERC4626LendingFacet(_portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    // ============ Remove Collateral With Debt Tests ============

    function testRemoveCollateralWithDebtReverts() public {
        // Setup: Add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Borrow against collateral
        uint256 borrowAmount = 500e6; // Borrow 500 USDC (within 70% LTV of 1000 USDC)
        borrowViaMulticall(borrowAmount);

        // Verify debt was created
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, borrowAmount);

        // Try to remove all collateral - should fail due to undercollateralized debt
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("removeCollateral(uint256)")), shares);

        vm.expectRevert(); // Should revert due to undercollateralized debt
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testRemovePartialCollateralWithDebtReverts() public {
        // Setup: Add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Borrow max amount (700 USDC at 70% LTV)
        uint256 borrowAmount = 600e6;
        borrowViaMulticall(borrowAmount);

        // Try to remove half collateral - this would reduce max loan below current debt
        // Current: 1000 collateral, 600 debt, max loan 700
        // After removing 500: 500 collateral, 600 debt, max loan 350 -> undercollateralized
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("removeCollateral(uint256)")), shares / 2);

        vm.expectRevert(); // Should revert
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testRemoveCollateralAfterPayingDebt() public {
        // Setup: Add collateral and borrow
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        // Verify debt
        uint256 debtBefore = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtBefore, borrowAmount);

        // Pay back full debt
        _underlyingAsset.mint(_user, borrowAmount);
        payDebt(borrowAmount);

        // Verify debt is zero
        uint256 debtAfter = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0);

        // Now removing collateral should succeed
        removeCollateralViaMulticall(shares);

        // Verify collateral is removed
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getCollateralShares(), 0);
    }

    function testRemovePartialCollateralWithinLTV() public {
        // Setup: Add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Borrow small amount (200 USDC)
        uint256 borrowAmount = 200e6;
        borrowViaMulticall(borrowAmount);

        // Calculate how much collateral we can safely remove
        // Current: 1000 collateral, 200 debt
        // To maintain 70% LTV: need collateral >= 200 / 0.7 = ~286 USDC
        // Can remove up to 1000 - 286 = 714 USDC worth of shares

        // Remove 500 USDC worth (should succeed since 500 collateral > 286 required)
        uint256 sharesToRemove = shares / 2; // Remove half (500 USDC worth)
        removeCollateralViaMulticall(sharesToRemove);

        // Verify partial removal succeeded
        uint256 remainingValue = ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(remainingValue, INITIAL_DEPOSIT / 2);

        // Debt should still be the same
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, borrowAmount);
    }

    function testBorrowAndPayDebt() public {
        // Setup: Add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Verify max loan
        (, uint256 maxLoanIgnoreSupply) = ERC4626CollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoanIgnoreSupply, 700e6); // 70% of 1000

        // Borrow
        uint256 borrowAmount = 300e6;
        uint256 userBalanceBefore = _underlyingAsset.balanceOf(_user);
        borrowViaMulticall(borrowAmount);

        // User should have received the loan (minus origination fee)
        uint256 userBalanceAfter = _underlyingAsset.balanceOf(_user);
        assertGt(userBalanceAfter, userBalanceBefore);

        // Debt should be recorded
        uint256 debt = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, borrowAmount);

        // Pay back partial debt
        uint256 payAmount = 100e6;
        _underlyingAsset.mint(_user, payAmount);
        payDebt(payAmount);

        // Debt should be reduced
        uint256 debtAfterPay = ERC4626CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfterPay, borrowAmount - payAmount);
    }

    function testCannotBorrowMoreThanMaxLoan() public {
        // Setup: Add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        // Try to borrow more than max loan (>700 USDC)
        // Note: The manager enforces collateral requirements after multicall
        uint256 excessBorrowAmount = 800e6;

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.borrow.selector, excessBorrowAmount);

        vm.expectRevert(); // Should revert due to exceeding max loan
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testPayDebtAndRemoveCollateralInSameCall() public {
        // Setup: Add collateral and borrow
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(address(_mockVault), shares);

        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        // Prepare payment
        _underlyingAsset.mint(_user, borrowAmount);

        // Pay debt and remove collateral in same multicall
        vm.startPrank(_user);
        _underlyingAsset.approve(_portfolioAccount, borrowAmount);

        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(ERC4626LendingFacet.pay.selector, borrowAmount);
        calldatas[1] = abi.encodeWithSelector(bytes4(keccak256("removeCollateral(uint256)")), shares);

        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Verify both operations succeeded
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalDebt(), 0);
        assertEq(ERC4626CollateralFacet(_portfolioAccount).getTotalLockedCollateral(), 0);
    }
}
