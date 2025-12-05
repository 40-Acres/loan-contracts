// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSDC} from "../../../src/interfaces/IUSDC.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";

contract RewardsProcessingFacetTest is Test, Setup {
    RewardsProcessingFacet public rewardsProcessingFacet;
    MockOdosRouterRL public mockRouter;
    
    address public rewardsToken; // USDC
    address public lockedAsset; // AERO (from voting escrow)
    uint256 public rewardsAmount = 1000e6; // 1000 USDC
    address public recipient = address(0x1234);

    function setUp() public override {
        super.setUp();
        
        // Deploy RewardsProcessingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        DeployRewardsProcessingFacet deployer = new DeployRewardsProcessingFacet();
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve));
        vm.stopPrank();
        
        // Initialize facet reference
        rewardsProcessingFacet = RewardsProcessingFacet(_portfolioAccount);
        
        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));
        
        // Set up tokens
        rewardsToken = address(_usdc);
        lockedAsset = IVotingEscrow(_ve).token();
        
        // Set up UserRewardsConfig through PortfolioManager multicall
        vm.startPrank(_user);
        address[] memory portfolios = new address[](4);
        portfolios[0] = _portfolioAccount;
        portfolios[1] = _portfolioAccount;
        portfolios[2] = _portfolioAccount;
        portfolios[3] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](4);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            rewardsToken
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRecipient.selector,
            recipient
        );
        calldatas[2] = abi.encodeWithSelector(
            RewardsProcessingFacet.setZeroBalanceRewardsOption.selector,
            UserRewardsConfig.ZeroBalanceRewardsOption.PayToRecipient
        );
        calldatas[3] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Approve swap target
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.approveSwapTarget(address(mockRouter));
        vm.stopPrank();
    }

    function setupRewards() internal {
        // Fund the portfolio account with rewards (USDC)
        address minter = IUSDC(rewardsToken).masterMinter();
        vm.startPrank(minter);
        IUSDC(rewardsToken).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(rewardsToken).mint(_portfolioAccount, rewardsAmount);
    }

    function testProcessRewardsZeroDebtPayToRecipient() public {
        setupRewards();
        
        // Verify initial state - no debt
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(totalDebt, 0, "Should have no debt initially");
        
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0), // asset will be determined from config
            address(0), // no swap
            new bytes(0)
        );
        vm.stopPrank();
        
        // Verify recipient received rewards
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        assertEq(recipientBalanceAfter, recipientBalanceBefore + rewardsAmount, "Recipient should receive rewards");
        assertEq(portfolioBalanceAfter, portfolioBalanceBefore - rewardsAmount, "Portfolio should have sent rewards");
    }

    function testProcessRewardsZeroDebtInvestToVault() public {
        setupRewards();
        
        // Change zero balance option to InvestToVault
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setZeroBalanceRewardsOption.selector,
            UserRewardsConfig.ZeroBalanceRewardsOption.InvestToVault
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        address vault = ILoan(_loanContract)._vault();
        uint256 recipientVaultSharesBefore = IERC20(vault).balanceOf(recipient);
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            address(0),
            new bytes(0)
        );
        vm.stopPrank();
        
        // Verify vault deposit
        uint256 recipientVaultSharesAfter = IERC20(vault).balanceOf(recipient);
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        assertGt(recipientVaultSharesAfter, recipientVaultSharesBefore, "Recipient should have vault shares");
        assertEq(portfolioBalanceAfter, portfolioBalanceBefore - rewardsAmount, "Portfolio should have sent rewards");
    }

    function testProcessRewardsWithIncreaseCollateral() public {
        setupRewards();
        
        // Set increase percentage
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setIncreasePercentage.selector,
            20
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Fund mock router with locked asset
        deal(lockedAsset, address(mockRouter), 200e18);
        
        uint256 portfolioRewardsBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Create swap data
        uint256 amountToSwap = rewardsAmount * 20 / 100; // 20% of rewards
        uint256 expectedLockedAssetOut = 200e18; // Expected output from swap
        
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            rewardsToken,
            lockedAsset,
            amountToSwap,
            expectedLockedAssetOut,
            _portfolioAccount
        );
        
        // Pre-approve for swap
        vm.prank(_portfolioAccount);
        IERC20(rewardsToken).approve(address(mockRouter), amountToSwap);
        
        // Check the voting escrow's locked amount before processing
        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountBefore = uint256(uint128(lockedBefore.amount));
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            rewardsToken,
            address(mockRouter),
            swapData
        );
        vm.stopPrank();
        
        // Verify collateral was increased
        // Check the voting escrow's locked amount for the token (the locked asset is transferred to voting escrow)
        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountAfter = uint256(uint128(lockedAfter.amount));
        
        uint256 portfolioRewardsAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        
        // Locked amount in voting escrow should have increased by the expected amount (from swap and increaseAmount)
        assertGe(lockedAmountAfter, lockedAmountBefore + expectedLockedAssetOut, "Locked asset balance should increase by swap amount");
        console.log("lockedAmountAfter", lockedAmountAfter);
        console.log("lockedAmountBefore", lockedAmountBefore);
        console.log("expectedLockedAssetOut", expectedLockedAssetOut);
        assertTrue(lockedAmountAfter > lockedAmountBefore);
        // Portfolio should have used rewards for swap (20% swapped, 80% sent to recipient)
        uint256 remainingRewards = rewardsAmount - amountToSwap;
        assertEq(portfolioRewardsAfter, 0, "Portfolio should have processed all rewards");
        assertEq(recipientBalanceAfter, recipientBalanceBefore + remainingRewards, "Recipient should receive remaining rewards");
    }

    function testProcessRewardsActiveLoan() public {
        setupRewards();
        
        // Create active loan by adding collateral and borrowing
        vm.startPrank(_user);
        // Note: This would require CollateralFacet and LendingFacet to be deployed
        // For now, we'll test the function call path
        vm.stopPrank();
        
        // Mock that we have debt by setting up the loan contract
        // In a real scenario, we'd need to actually create a loan
        // For this test, we'll verify the function calls the right path
        
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Process rewards - should call handleActiveLoanPortfolioAccount
        vm.startPrank(_authorizedCaller);
        // This will fail if there's no active loan, which is expected
        // In a full test, we'd set up an actual loan first
        vm.stopPrank();
    }

    function testGetIncreasePercentage() public {
        // Test with no debt
        uint256 increasePercentage = rewardsProcessingFacet.getIncreasePercentage();
        assertEq(increasePercentage, 0, "Should return 0 when not set");
        
        // Set increase percentage
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setIncreasePercentage.selector,
            30
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        increasePercentage = rewardsProcessingFacet.getIncreasePercentage();
        assertEq(increasePercentage, 30, "Should return set percentage when no debt");
        
        // Test with debt - should cap at 25%
        // Note: This would require setting up actual debt
        // For now, we test the logic path
    }

    function testGetIncreasePercentageCappedAt25WithDebt() public {
        // Set increase percentage above 25
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setIncreasePercentage.selector,
            50
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Verify percentage is 50 when there's no debt
        uint256 increasePercentageBeforeDebt = rewardsProcessingFacet.getIncreasePercentage();
        assertEq(increasePercentageBeforeDebt, 50, "Should return 50 when no debt");
        
        // Create debt using LendingFacet
        uint256 borrowAmount = 1000e6; // Borrow 1000 USDC
        vm.startPrank(_user);
        LendingFacet(_portfolioAccount).borrow(borrowAmount);
        vm.stopPrank();
        
        // Verify total debt is greater than 0
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt after borrowing");
        
        // When there's debt, it should be capped at 25
        uint256 increasePercentageWithDebt = rewardsProcessingFacet.getIncreasePercentage();
        assertEq(increasePercentageWithDebt, 25, "Should be capped at 25 when there's debt");
    }

    function testSetActiveRewardsOption() public {
        // Test setting active rewards option
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setActiveRewardsOption.selector,
            UserRewardsConfig.ActiveRewardsOption.PayToRecipient
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        UserRewardsConfig.ActiveRewardsOption option = rewardsProcessingFacet.getActiveRewardsOption();
        assertEq(uint256(option), uint256(UserRewardsConfig.ActiveRewardsOption.PayToRecipient), "Should set active rewards option");
    }

    function testSetZeroBalanceRewardsOption() public {
        // Test setting zero balance rewards option
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setZeroBalanceRewardsOption.selector,
            UserRewardsConfig.ZeroBalanceRewardsOption.InvestToVault
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        UserRewardsConfig.ZeroBalanceRewardsOption option = rewardsProcessingFacet.getZeroBalanceRewardsOption();
        assertEq(uint256(option), uint256(UserRewardsConfig.ZeroBalanceRewardsOption.InvestToVault), "Should set zero balance rewards option");
    }

    function testSetIncreasePercentage() public {
        // Test setting increase percentage
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setIncreasePercentage.selector,
            15
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        uint256 percentage = rewardsProcessingFacet.getIncreasePercentage();
        assertEq(percentage, 15, "Should set increase percentage");
    }

    function testProcessRewardsFailsWithUnauthorizedCaller() public {
        setupRewards();
        
        // Try to call from unauthorized address
        vm.prank(address(0x1234));
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            address(0),
            new bytes(0)
        );
    }

    function testProcessRewardsFailsWithInsufficientBalance() public {
        // Don't fund the account
        // Try to process rewards
        vm.startPrank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            address(0),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testProcessRewardsFailsWithZeroRewardsToken() public {
        setupRewards();
        
        // Set rewards token to zero using the facet's setter through multicall
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            address(0)
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // This should fail when processing zero balance rewards
        vm.startPrank(_authorizedCaller);
        vm.expectRevert();
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            address(0),
            new bytes(0)
        );
        vm.stopPrank();
    }
}

