// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/ERC4626ClaimingFacet.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/erc4626/ERC4626CollateralFacet.sol";
import {DeployERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployERC4626ClaimingFacet.s.sol";
import {DeployERC4626CollateralFacet} from "../../../script/portfolio_account/facets/DeployERC4626CollateralFacet.s.sol";
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

contract ERC4626ClaimingFacetTest is Test {
    ERC4626ClaimingFacet public _erc4626ClaimingFacet;
    ERC4626CollateralFacet public _erc4626CollateralFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    // Config contracts
    PortfolioAccountConfig public _portfolioAccountConfig;
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    SwapConfig public _swapConfig;

    MockERC20 public _underlyingAsset;
    MockERC4626 public _mockVault;

    // Lending infrastructure
    address public _loanContract;
    address public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e6;
    uint256 constant YIELD_AMOUNT = 100e6;

    function setUp() public virtual {
        vm.startPrank(_owner);

        // Deploy portfolio manager and factory
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-claiming-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // Deploy config contracts
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (_portfolioAccountConfig, _votingConfig, _loanConfig, _swapConfig) = configDeployer.deploy();

        // Deploy mock underlying asset and vault
        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 6);
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Vault", "mVAULT", 6);

        // Deploy lending infrastructure
        _setupLendingInfrastructure();

        // Deploy and register ERC4626CollateralFacet (required for collateral tracking)
        DeployERC4626CollateralFacet collateralDeployer = new DeployERC4626CollateralFacet();
        _erc4626CollateralFacet = collateralDeployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_mockVault));

        // Deploy and register ERC4626ClaimingFacet
        DeployERC4626ClaimingFacet deployer = new DeployERC4626ClaimingFacet();
        _erc4626ClaimingFacet = deployer.deploy(address(_portfolioFactory), address(_mockVault));

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

        // Fund lending vault with USDC
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

    function addCollateralViaMulticall(uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626CollateralFacet.addCollateral.selector, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function simulateYield(uint256 yieldAmount) internal {
        // Mint yield assets to owner and simulate yield in vault
        _underlyingAsset.mint(_owner, yieldAmount);
        vm.startPrank(_owner);
        _underlyingAsset.approve(address(_mockVault), yieldAmount);
        _mockVault.simulateYield(yieldAmount);
        vm.stopPrank();
    }

    // ============ claimVaultYield Tests ============

    function testClaimVaultYield() public {
        // Setup: add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        // Verify yield is available
        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertGt(yieldAssets, 0);
        assertGt(yieldShares, 0);

        // Record balances before claim
        uint256 portfolioAssetsBefore = _underlyingAsset.balanceOf(_portfolioAccount);

        // Claim yield as authorized caller
        vm.startPrank(_authorizedCaller);
        uint256 claimedAssets = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();

        // Verify yield was claimed
        assertGt(claimedAssets, 0);
        uint256 portfolioAssetsAfter = _underlyingAsset.balanceOf(_portfolioAccount);
        assertEq(portfolioAssetsAfter, portfolioAssetsBefore + claimedAssets);

        // Verify yield is now 0 (or very small due to rounding)
        (uint256 remainingYieldAssets, ) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertLt(remainingYieldAssets, 1e4); // Allow for small rounding errors
    }

    function testClaimVaultYieldRevertsWithNoCollateral() public {
        vm.startPrank(_authorizedCaller);
        vm.expectRevert("No shares deposited");
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();
    }

    function testClaimVaultYieldRevertsWithNoYield() public {
        // Setup: add collateral but no yield
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        vm.startPrank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();
    }

    function testClaimVaultYieldRevertsWithUnauthorizedCaller() public {
        // Setup: add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        // Try to claim as unauthorized caller
        vm.startPrank(_user);
        vm.expectRevert();
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();
    }

    // ============ getAvailableYield Tests ============

    function testGetAvailableYieldNoCollateral() public view {
        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertEq(yieldAssets, 0);
        assertEq(yieldShares, 0);
    }

    function testGetAvailableYieldNoYieldAccumulated() public {
        // Setup: add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();
        assertEq(yieldAssets, 0);
        assertEq(yieldShares, 0);
    }

    function testGetAvailableYieldWithAccumulatedYield() public {
        // Setup: add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield();

        // Yield should be close to YIELD_AMOUNT (slight variance due to share calculations)
        assertApproxEqRel(yieldAssets, YIELD_AMOUNT, 0.01e18); // 1% tolerance
        assertGt(yieldShares, 0);
    }

    // ============ getDepositInfo Tests ============

    function testGetDepositInfoNoCollateral() public view {
        (address vault, uint256 shares, uint256 depositedAssets, uint256 currentAssets) =
            ERC4626ClaimingFacet(_portfolioAccount).getDepositInfo();
        assertEq(vault, address(_mockVault));
        assertEq(shares, 0);
        assertEq(depositedAssets, 0);
        assertEq(currentAssets, 0);
    }

    function testGetDepositInfoWithCollateral() public {
        // Setup: add collateral
        uint256 depositedShares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(depositedShares);
        addCollateralViaMulticall(depositedShares);

        (address vault, uint256 shares, uint256 depositedAssets, uint256 currentAssets) =
            ERC4626ClaimingFacet(_portfolioAccount).getDepositInfo();

        assertEq(vault, address(_mockVault));
        assertEq(shares, depositedShares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        assertEq(currentAssets, INITIAL_DEPOSIT);
    }

    function testGetDepositInfoWithYield() public {
        // Setup: add collateral
        uint256 depositedShares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(depositedShares);
        addCollateralViaMulticall(depositedShares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        (address vault, uint256 shares, uint256 depositedAssets, uint256 currentAssets) =
            ERC4626ClaimingFacet(_portfolioAccount).getDepositInfo();

        assertEq(vault, address(_mockVault));
        assertEq(shares, depositedShares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        // Current assets should be higher due to yield
        assertGt(currentAssets, depositedAssets);
        assertApproxEqRel(currentAssets, INITIAL_DEPOSIT + YIELD_AMOUNT, 0.01e18);
    }

    // ============ Multiple Yield Claims Tests ============

    function testMultipleYieldClaims() public {
        // Setup: add collateral
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        transferSharesToPortfolio(shares);
        addCollateralViaMulticall(shares);

        // First yield simulation and claim
        simulateYield(YIELD_AMOUNT);

        vm.startPrank(_authorizedCaller);
        uint256 firstClaim = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();

        assertGt(firstClaim, 0);

        // Second yield simulation and claim
        simulateYield(YIELD_AMOUNT / 2);

        vm.startPrank(_authorizedCaller);
        uint256 secondClaim = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield();
        vm.stopPrank();

        assertGt(secondClaim, 0);

        // Total claimed should be approximately the total yield simulated
        uint256 totalClaimed = firstClaim + secondClaim;
        assertApproxEqRel(totalClaimed, YIELD_AMOUNT + YIELD_AMOUNT / 2, 0.02e18);
    }
}
