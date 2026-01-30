// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/claim/ERC4626ClaimingFacet.sol";
import {DeployERC4626ClaimingFacet} from "../../../script/portfolio_account/facets/DeployERC4626ClaimingFacet.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockCollateralFacet} from "../../mocks/MockCollateralFacet.sol";

contract ERC4626ClaimingFacetTest is Test {
    ERC4626ClaimingFacet public _erc4626ClaimingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    MockERC20 public _underlyingAsset;
    MockERC4626 public _mockVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant INITIAL_DEPOSIT = 1000e18;
    uint256 constant YIELD_AMOUNT = 100e18;

    function setUp() public virtual {
        vm.startPrank(_owner);

        // Deploy portfolio manager and factory
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("erc4626-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // Deploy mock underlying asset and vault
        _underlyingAsset = new MockERC20("Mock USDC", "mUSDC", 18);
        _mockVault = new MockERC4626(address(_underlyingAsset), "Mock Vault", "mVAULT", 18);

        // Deploy and register ERC4626ClaimingFacet
        DeployERC4626ClaimingFacet deployer = new DeployERC4626ClaimingFacet();
        _erc4626ClaimingFacet = deployer.deploy(address(_portfolioFactory));

        // Deploy and register MockCollateralFacet (required for enforceCollateralRequirements in multicall)
        MockCollateralFacet mockCollateralFacet = new MockCollateralFacet();
        bytes4[] memory collateralSelectors = new bytes4[](5);
        collateralSelectors[0] = MockCollateralFacet.getTotalDebt.selector;
        collateralSelectors[1] = MockCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[2] = MockCollateralFacet.getMaxLoan.selector;
        collateralSelectors[3] = MockCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[4] = MockCollateralFacet.getTotalLockedCollateral.selector;
        _facetRegistry.registerFacet(address(mockCollateralFacet), collateralSelectors, "MockCollateralFacet");

        // Set authorized caller
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Mint underlying assets to user for testing
        _underlyingAsset.mint(_user, INITIAL_DEPOSIT * 10);
    }

    // ============ Helper Functions ============

    function depositSharesViaMulticall(address vault, uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.depositShares.selector, vault, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function trackExistingSharesViaMulticall(address vault, uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.trackExistingShares.selector, vault, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function withdrawSharesViaMulticall(address vault, uint256 shares) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.withdrawShares.selector, vault, shares);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function prepareUserWithVaultShares(uint256 depositAmount) internal returns (uint256 shares) {
        vm.startPrank(_user);
        _underlyingAsset.approve(address(_mockVault), depositAmount);
        shares = _mockVault.deposit(depositAmount, _user);
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

    // ============ depositShares Tests ============

    function testDepositShares() public {
        // User gets vault shares first
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);

        // Approve portfolio account to transfer shares
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();

        // Deposit shares via multicall
        depositSharesViaMulticall(address(_mockVault), shares);

        // Verify shares are in portfolio account
        assertEq(_mockVault.balanceOf(_portfolioAccount), shares);
        assertEq(_mockVault.balanceOf(_user), 0);

        // Verify tracking
        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));
        assertEq(trackedShares, shares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        assertEq(currentAssets, INITIAL_DEPOSIT);
    }

    function testDepositSharesRevertsWithZeroShares() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.depositShares.selector, address(_mockVault), 0);

        vm.expectRevert("Shares must be > 0");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testDepositSharesRevertsWithInvalidVault() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.depositShares.selector, address(0), 100);

        vm.expectRevert("Invalid vault");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ============ trackExistingShares Tests ============

    function testTrackExistingShares() public {
        // User gets vault shares and transfers them directly to portfolio account
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);

        vm.startPrank(_user);
        _mockVault.transfer(_portfolioAccount, shares);
        vm.stopPrank();

        // Track the existing shares
        trackExistingSharesViaMulticall(address(_mockVault), shares);

        // Verify tracking
        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));
        assertEq(trackedShares, shares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        assertEq(currentAssets, INITIAL_DEPOSIT);
    }

    function testTrackExistingSharesRevertsWithInsufficientBalance() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            ERC4626ClaimingFacet.trackExistingShares.selector,
            address(_mockVault),
            1000e18
        );

        vm.expectRevert("Insufficient shares in wallet");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ============ withdrawShares Tests ============

    function testWithdrawShares() public {
        // Setup: deposit shares first
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        // Verify setup
        assertEq(_mockVault.balanceOf(_portfolioAccount), shares);
        assertEq(_mockVault.balanceOf(_user), 0);

        // Withdraw shares
        withdrawSharesViaMulticall(address(_mockVault), shares);

        // Verify withdrawal
        assertEq(_mockVault.balanceOf(_portfolioAccount), 0);
        assertEq(_mockVault.balanceOf(_user), shares);

        // Verify tracking is cleared
        (uint256 trackedShares, uint256 depositedAssets, ) = ERC4626ClaimingFacet(_portfolioAccount).getDepositInfo(
            address(_mockVault)
        );
        assertEq(trackedShares, 0);
        assertEq(depositedAssets, 0);
    }

    function testWithdrawPartialShares() public {
        // Setup: deposit shares first
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        uint256 withdrawAmount = shares / 2;

        // Withdraw half the shares
        withdrawSharesViaMulticall(address(_mockVault), withdrawAmount);

        // Verify partial withdrawal
        assertEq(_mockVault.balanceOf(_portfolioAccount), shares - withdrawAmount);
        assertEq(_mockVault.balanceOf(_user), withdrawAmount);

        // Verify tracking is partially updated
        (uint256 trackedShares, uint256 depositedAssets, ) = ERC4626ClaimingFacet(_portfolioAccount).getDepositInfo(
            address(_mockVault)
        );
        assertEq(trackedShares, shares - withdrawAmount);
        assertEq(depositedAssets, INITIAL_DEPOSIT / 2);
    }

    function testWithdrawSharesRevertsWithInsufficientTrackedShares() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ERC4626ClaimingFacet.withdrawShares.selector, address(_mockVault), 100);

        vm.expectRevert("Insufficient tracked shares");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // ============ claimVaultYield Tests ============

    function testClaimVaultYield() public {
        // Setup: deposit shares
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        // Verify yield is available
        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield(
            address(_mockVault)
        );
        assertGt(yieldAssets, 0);
        assertGt(yieldShares, 0);

        // Record balances before claim
        uint256 portfolioAssetsBefore = _underlyingAsset.balanceOf(_portfolioAccount);

        // Claim yield as authorized caller
        vm.startPrank(_authorizedCaller);
        uint256 claimedAssets = ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(address(_mockVault));
        vm.stopPrank();

        // Verify yield was claimed
        assertGt(claimedAssets, 0);
        uint256 portfolioAssetsAfter = _underlyingAsset.balanceOf(_portfolioAccount);
        assertEq(portfolioAssetsAfter, portfolioAssetsBefore + claimedAssets);

        // Verify yield is now 0 (or very small due to rounding)
        (uint256 remainingYieldAssets, ) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield(
            address(_mockVault)
        );
        assertLt(remainingYieldAssets, 1e15); // Allow for small rounding errors
    }

    function testClaimVaultYieldRevertsWithNoShares() public {
        vm.startPrank(_authorizedCaller);
        vm.expectRevert("No shares deposited");
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(address(_mockVault));
        vm.stopPrank();
    }

    function testClaimVaultYieldRevertsWithNoYield() public {
        // Setup: deposit shares but no yield
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        vm.startPrank(_authorizedCaller);
        vm.expectRevert("No yield to harvest");
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(address(_mockVault));
        vm.stopPrank();
    }

    function testClaimVaultYieldRevertsWithUnauthorizedCaller() public {
        // Setup: deposit shares
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        // Try to claim as unauthorized caller
        vm.startPrank(_user);
        vm.expectRevert();
        ERC4626ClaimingFacet(_portfolioAccount).claimVaultYield(address(_mockVault));
        vm.stopPrank();
    }

    // ============ getAvailableYield Tests ============

    function testGetAvailableYieldNoShares() public view {
        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield(
            address(_mockVault)
        );
        assertEq(yieldAssets, 0);
        assertEq(yieldShares, 0);
    }

    function testGetAvailableYieldNoYieldAccumulated() public {
        // Setup: deposit shares
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield(
            address(_mockVault)
        );
        assertEq(yieldAssets, 0);
        assertEq(yieldShares, 0);
    }

    function testGetAvailableYieldWithAccumulatedYield() public {
        // Setup: deposit shares
        uint256 shares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), shares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), shares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        (uint256 yieldAssets, uint256 yieldShares) = ERC4626ClaimingFacet(_portfolioAccount).getAvailableYield(
            address(_mockVault)
        );

        // Yield should be close to YIELD_AMOUNT (slight variance due to share calculations)
        assertApproxEqRel(yieldAssets, YIELD_AMOUNT, 0.01e18); // 1% tolerance
        assertGt(yieldShares, 0);
    }

    // ============ getDepositInfo Tests ============

    function testGetDepositInfoNoDeposit() public view {
        (uint256 shares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));
        assertEq(shares, 0);
        assertEq(depositedAssets, 0);
        assertEq(currentAssets, 0);
    }

    function testGetDepositInfoWithDeposit() public {
        // Setup: deposit shares
        uint256 depositedShares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), depositedShares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), depositedShares);

        (uint256 shares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));

        assertEq(shares, depositedShares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        assertEq(currentAssets, INITIAL_DEPOSIT);
    }

    function testGetDepositInfoWithYield() public {
        // Setup: deposit shares
        uint256 depositedShares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), depositedShares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), depositedShares);

        // Simulate yield
        simulateYield(YIELD_AMOUNT);

        (uint256 shares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));

        assertEq(shares, depositedShares);
        assertEq(depositedAssets, INITIAL_DEPOSIT);
        // Current assets should be higher due to yield
        assertGt(currentAssets, depositedAssets);
        assertApproxEqRel(currentAssets, INITIAL_DEPOSIT + YIELD_AMOUNT, 0.01e18);
    }

    // ============ Multiple Deposits Tests ============

    function testMultipleDeposits() public {
        // First deposit
        uint256 firstShares = prepareUserWithVaultShares(INITIAL_DEPOSIT);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), firstShares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), firstShares);

        // Second deposit
        uint256 secondDeposit = INITIAL_DEPOSIT / 2;
        uint256 secondShares = prepareUserWithVaultShares(secondDeposit);
        vm.startPrank(_user);
        _mockVault.approve(address(_portfolioAccount), secondShares);
        vm.stopPrank();
        depositSharesViaMulticall(address(_mockVault), secondShares);

        // Verify total tracking
        (uint256 trackedShares, uint256 depositedAssets, uint256 currentAssets) = ERC4626ClaimingFacet(_portfolioAccount)
            .getDepositInfo(address(_mockVault));

        assertEq(trackedShares, firstShares + secondShares);
        assertEq(depositedAssets, INITIAL_DEPOSIT + secondDeposit);
        assertEq(currentAssets, INITIAL_DEPOSIT + secondDeposit);
    }
}
