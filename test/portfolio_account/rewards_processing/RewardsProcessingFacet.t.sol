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
import {DeployRewardsProcessingFacet} from "../../../script/portfolio_account/facets/DeployRewardsProcessingFacet.s.sol";
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
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_swapConfig), address(_ve), _vault);
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
        address[] memory portfolioFactories = new address[](4);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);
        portfolioFactories[3] = address(_portfolioFactory);
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
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.PayToRecipient
        );
        calldatas[3] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
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

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
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
            rewardsAmount, // asset will be determined from config
            address(0), // no swap
            0, // minimum output amount
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify recipient received rewards (accounting for zero balance fee)
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Calculate expected amount after zero balance fee (1% = 100 basis points)
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - feeAmount;
        
        assertEq(recipientBalanceAfter, recipientBalanceBefore + expectedRecipientAmount, "Recipient should receive rewards minus fee");
        assertEq(portfolioBalanceAfter, portfolioBalanceBefore - rewardsAmount, "Portfolio should have sent rewards");
    }

    function testProcessRewardsZeroDebtInvestToVault() public {
        setupRewards();
        
        // Change zero balance option to InvestToVault
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.InvestToVault
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            100
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        address vault = ILoan(_loanContract)._vault();
        uint256 portfolioOwnerVaultSharesBefore = IERC20(vault).balanceOf(_portfolioFactory.ownerOf(_portfolioAccount));
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0, // minimum output amount
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify vault deposit
        uint256 portfolioOwnerVaultSharesAfter = IERC20(vault).balanceOf(_portfolioFactory.ownerOf(_portfolioAccount));
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        
        assertGt(portfolioOwnerVaultSharesAfter, portfolioOwnerVaultSharesBefore, "Portfolio owner should have vault shares");
        assertEq(portfolioBalanceAfter, portfolioBalanceBefore - rewardsAmount, "Portfolio should have sent rewards");
    }

    function testProcessRewardsWithIncreaseCollateral() public {
        setupRewards();
        
        // Set increase percentage
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            20
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.IncreaseCollateral
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
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
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(mockRouter),
            0,
            swapData,
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify collateral was increased
        // Check the voting escrow's locked amount for the token (the locked asset is transferred to voting escrow)
        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountAfter = uint256(uint128(lockedAfter.amount));
        
        uint256 portfolioRewardsAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        
        // Locked amount in voting escrow should have increased by the expected amount (from swap and increaseAmount)
        assertGe(lockedAmountAfter, lockedAmountBefore + expectedLockedAssetOut, "Locked asset balance should increase by swap amount");
        console.log("lockedAmountAfter", lockedAmountAfter);
        console.log("lockedAmountBefore", lockedAmountBefore);
        console.log("expectedLockedAssetOut", expectedLockedAssetOut);
        assertTrue(lockedAmountAfter > lockedAmountBefore);
        // Portfolio should have used rewards for swap (20% swapped, remaining sent to recipient minus zero balance fee)
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 remainingRewards = rewardsAmount - amountToSwap - feeAmount;
        assertEq(portfolioRewardsAfter, 0, "Portfolio should have processed all rewards");
        assertEq(recipientBalanceAfter, recipientBalanceBefore + remainingRewards, "Recipient should receive remaining rewards minus fee");
    }


    function testProcessRewardsRevertSlippage() public {
        setupRewards();
        
        // Set increase percentage
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](2);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            20
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.IncreaseCollateral
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
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
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        vm.expectRevert("Slippage exceeded");
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(mockRouter),
            10000e18,
            swapData,
            0 // gas reclamation
        );
        vm.stopPrank();
    }

    function testProcessRewardsActiveLoan() public {
        // Create active loan by adding collateral and borrowing
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 500e6; // 500 USDC
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Verify we have debt (may be less than requested if capped by vault constraints)
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt after borrowing");
        assertLe(totalDebt, borrowAmount, "Debt should not exceed requested amount");
        
        // Get the loan contract asset (should be USDC)
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund the portfolio account with loan asset (USDC) for rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        uint256 portfolioBalanceBefore = IERC20(loanAsset).balanceOf(_portfolioAccount);
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        
        // Process rewards - should pay down debt
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount, // asset will be determined from loan contract
            address(0), // no swap
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify debt was decreased
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 portfolioBalanceAfter = IERC20(loanAsset).balanceOf(_portfolioAccount);
        
        // Calculate expected fees
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        uint256 zeroBalanceFee = (rewardsAmount * _loanConfig.getZeroBalanceFee()) / 10000;
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        uint256 amountForDebt = rewardsAmount - totalFees;
        
        // Debt should be decreased by amountForDebt (or to zero if less)
        uint256 expectedDebt = debtBefore > amountForDebt ? debtBefore - amountForDebt : 0;
        assertEq(debtAfter, expectedDebt, "Debt should be decreased");
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have used all rewards");
    }

    function testProcessRewardsActiveLoanWithRemaining() public {
        setupRewards();
        
        // Create active loan with small debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 100e6; // 100 USDC (smaller than rewards)
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund the portfolio account with loan asset for rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 portfolioOwnerVaultSharesBefore = IERC20(vault).balanceOf(portfolioOwner);
        
        // Process rewards - should pay down debt and deposit remaining to vault as shares for portfolio owner
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify debt is zero (fully paid)
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be fully paid");
        
        // Calculate expected amounts
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        uint256 zeroBalanceFee = (rewardsAmount * _loanConfig.getZeroBalanceFee()) / 10000;
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        // Use actual debt (may be less than borrowAmount if capped)
        uint256 actualDebt = debtBefore;
        uint256 amountForDebt = actualDebt; // Actual debt used
        uint256 remainingAfterDebt = rewardsAmount - totalFees - amountForDebt;
        
        // When debt is fully paid, remaining funds should be deposited to vault as shares for portfolio owner
        // Note: zero balance fee was already paid in _processActiveLoanRewards, so remaining goes to portfolio owner as vault shares
        uint256 portfolioOwnerVaultSharesAfter = IERC20(vault).balanceOf(portfolioOwner);
        uint256 portfolioOwnerVaultSharesReceived = portfolioOwnerVaultSharesAfter - portfolioOwnerVaultSharesBefore;
        assertGt(portfolioOwnerVaultSharesReceived, 0, "Portfolio owner should receive vault shares");
    }

    function testProcessRewardsActiveLoanWithIncreaseCollateral() public {
        setupRewards();
        
        // Set increase percentage
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](3);
        portfolioFactories[0] = address(_portfolioFactory);
        portfolioFactories[1] = address(_portfolioFactory);
        portfolioFactories[2] = address(_portfolioFactory);

        bytes[] memory calldatas = new bytes[](3);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            15 // 15% (capped at 25% when there's debt)
        );
        calldatas[1] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.IncreaseCollateral
        );
        calldatas[2] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        
        // Borrow to create active loan
        uint256 borrowAmount = 500e6;
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund mock router with locked asset
        deal(lockedAsset, address(mockRouter), 200e18);
        
        // Fund the portfolio account with loan asset for rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        // Create swap data for collateral increase
        uint256 amountToSwap = rewardsAmount * 15 / 100; // 15% of rewards
        uint256 expectedLockedAssetOut = 200e18;
        
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            loanAsset,
            lockedAsset,
            amountToSwap,
            expectedLockedAssetOut,
            _portfolioAccount
        );
        
        // Pre-approve for swap
        vm.prank(_portfolioAccount);
        IERC20(loanAsset).approve(address(mockRouter), amountToSwap);
        
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        IVotingEscrow.LockedBalance memory lockedBefore = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountBefore = uint256(uint128(lockedBefore.amount));
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(mockRouter),
            0,
            swapData,
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify collateral was increased
        IVotingEscrow.LockedBalance memory lockedAfter = IVotingEscrow(_ve).locked(_tokenId);
        uint256 lockedAmountAfter = uint256(uint128(lockedAfter.amount));
        assertGe(lockedAmountAfter, lockedAmountBefore + expectedLockedAssetOut, "Collateral should increase");
        
        // Verify debt was decreased
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 remainingAfterSwap = rewardsAmount - amountToSwap;
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        uint256 zeroBalanceFee = (rewardsAmount * _loanConfig.getZeroBalanceFee()) / 10000;
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        uint256 amountForDebt = remainingAfterSwap - totalFees;
        
        uint256 expectedDebt = debtBefore > amountForDebt ? debtBefore - amountForDebt : 0;
        assertEq(debtAfter, expectedDebt, "Debt should be decreased");
    }

    function testProcessRewardsActiveLoanPartialPayment() public {
        setupRewards();
        
        // Create active loan with large debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 2000e6; // 2000 USDC (larger than rewards)
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund the portfolio account with loan asset for rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        address owner = _portfolioAccountConfig.owner();
        uint256 ownerBalanceBefore = IERC20(loanAsset).balanceOf(owner);
        uint256 vaultBalanceBefore = IERC20(loanAsset).balanceOf(vault);
        
        // Process rewards - should partially pay down debt
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify fees were paid
        uint256 ownerBalanceAfter = IERC20(loanAsset).balanceOf(owner);
        uint256 vaultBalanceAfter = IERC20(loanAsset).balanceOf(vault);
        
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        
        assertEq(ownerBalanceAfter - ownerBalanceBefore, protocolFee, "Owner should receive protocol fee");

        // Lender premium should be routed to the vault along with the debt payment
        uint256 totalFees = protocolFee + lenderPremium;
        uint256 amountForDebt = rewardsAmount - totalFees;
        uint256 balancePayment = debtBefore > amountForDebt ? amountForDebt : debtBefore;
        uint256 expectedVaultIncrease = balancePayment + lenderPremium;
        assertEq(vaultBalanceAfter - vaultBalanceBefore, expectedVaultIncrease, "Vault should receive lender premium and debt payment");
        
        // Verify debt was partially decreased
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 expectedDebt = debtBefore - amountForDebt;
        assertEq(debtAfter, expectedDebt, "Debt should be decreased by payment amount minus fees");
        assertGt(debtAfter, 0, "Debt should still exist after partial payment");
    }

    function testProcessRewardsActiveLoanFeesCalculation() public {
        setupRewards();
        
        // Create active loan
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 500e6;
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund the portfolio account with loan asset for rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        address owner = _portfolioAccountConfig.owner();
        uint256 ownerBalanceBefore = IERC20(loanAsset).balanceOf(owner);
        uint256 vaultBalanceBefore = IERC20(loanAsset).balanceOf(vault);
        
        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
        
        // Verify all fees are calculated and paid correctly
        uint256 ownerBalanceAfter = IERC20(loanAsset).balanceOf(owner);
        uint256 vaultBalanceAfter = IERC20(loanAsset).balanceOf(vault);
        
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        
        assertEq(ownerBalanceAfter - ownerBalanceBefore, protocolFee, "Owner should receive protocol fee");
        assertGe(vaultBalanceAfter - vaultBalanceBefore, lenderPremium, "Vault should receive at least lender premium");
    }

    function testGetRewardsOptionPercentage() public {
        // Test with no debt
        uint256 rewardsOptionPercentage = rewardsProcessingFacet.getRewardsOptionPercentage();
        assertEq(rewardsOptionPercentage, 0, "Should return 0 when not set");
        
        // Set rewards option percentage
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            30
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        rewardsOptionPercentage = rewardsProcessingFacet.getRewardsOptionPercentage();
        assertEq(rewardsOptionPercentage, 30, "Should return set percentage when no debt");
        
        // Test with debt - should cap at 25%
        // Note: This would require setting up actual debt
        // For now, we test the logic path
    }

    function testGetIncreasePercentageCappedAt25WithDebt() public {
        // Set increase percentage above 25
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            50
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        // Verify percentage is 50 when there's no debt
        uint256 increasePercentageBeforeDebt = rewardsProcessingFacet.getRewardsOptionPercentage();
        assertEq(increasePercentageBeforeDebt, 50, "Should return 50 when no debt");
        
        // Create debt using LendingFacet
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 1000e6; // Borrow 1000 USDC
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        // Verify total debt is greater than 0
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt after borrowing");
        
        // When there's debt, it should be capped at 25
        uint256 increasePercentageWithDebt = rewardsProcessingFacet.getRewardsOptionPercentage();
        assertEq(increasePercentageWithDebt, 25, "Should be capped at 25 when there's debt");
    }

    function testSetRewardsOption() public {
        // Test setting active rewards option
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.PayToRecipient
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        UserRewardsConfig.RewardsOption option = rewardsProcessingFacet.getRewardsOption();
        assertEq(uint256(option), uint256(UserRewardsConfig.RewardsOption.PayToRecipient), "Should set active rewards option");
    }

    function testSetZeroBalanceRewardsOption() public {
        // Test setting zero balance rewards option
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOption.selector,
            UserRewardsConfig.RewardsOption.InvestToVault
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        UserRewardsConfig.RewardsOption option = rewardsProcessingFacet.getRewardsOption();
        assertEq(uint256(option), uint256(UserRewardsConfig.RewardsOption.InvestToVault), "Should set zero balance rewards option");
    }

    function testSetRewardsOptionPercentage() public {
        // Test setting increase percentage
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsOptionPercentage.selector,
            15
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        uint256 percentage = rewardsProcessingFacet.getRewardsOptionPercentage();
        assertEq(percentage, 15, "Should set rewards option percentage");
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
            0,
            new bytes(0),
            0 // gas reclamation
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
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
    }

    function testProcessRewardsShouldFallbackToVaultAssetIfNoRewardsTokenSet() public {
        setupRewards();
        
        // Set rewards token to zero using the facet's setter through multicall
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            RewardsProcessingFacet.setRewardsToken.selector,
            address(0)
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        // Process rewards should fallback to vault asset if no rewards token set
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();
    }

    function testProcessRewardsWithGasReclamation() public {
        setupRewards();
        
        uint256 gasReclamationAmount = 10e6; // 10 USDC
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);
        
        // Process rewards with gas reclamation
        // Use vm.startPrank with both msg.sender and tx.origin set to _authorizedCaller
        // since gas reclamation is transferred to tx.origin
        vm.startPrank(_authorizedCaller, _authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            gasReclamationAmount
        );
        vm.stopPrank();
        
        // Verify gas reclamation was deducted from remaining and transferred
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceAfter = IERC20(rewardsToken).balanceOf(_authorizedCaller);
        
        // Calculate expected amounts
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - gasReclamationAmount - feeAmount;
        
        // Verify recipient received reduced amount (after gas reclamation deduction)
        assertEq(recipientBalanceAfter, recipientBalanceBefore + expectedRecipientAmount, "Recipient should receive rewards minus gas reclamation and fee");
        
        // Verify portfolio balance is 0 (all rewards processed)
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have processed all rewards");
        
        // Verify authorized caller received the gas reclamation
        assertEq(authorizedCallerBalanceAfter, authorizedCallerBalanceBefore + gasReclamationAmount, "Authorized caller should receive gas reclamation");
    }

    function testProcessRewardsWithGasReclamationCappedAt5Percent() public {
        setupRewards();
        
        uint256 gasReclamationAmount = 100e6; // 100 USDC (10% of rewards, should be capped at 5%)
        uint256 expectedCappedAmount = rewardsAmount * 5 / 100; // 5% cap = 50 USDC
        uint256 recipientBalanceBefore = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceBefore = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceBefore = IERC20(rewardsToken).balanceOf(_authorizedCaller);
        
        // Process rewards with gas reclamation that exceeds cap
        // Use vm.startPrank with both msg.sender and tx.origin set to _authorizedCaller
        vm.startPrank(_authorizedCaller, _authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            gasReclamationAmount // Will be capped at 5%
        );
        vm.stopPrank();
        
        // Verify gas reclamation was capped at 5%
        uint256 recipientBalanceAfter = IERC20(rewardsToken).balanceOf(recipient);
        uint256 portfolioBalanceAfter = IERC20(rewardsToken).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceAfter = IERC20(rewardsToken).balanceOf(_authorizedCaller);
        
        // Calculate expected amounts with capped gas reclamation
        uint256 zeroBalanceFee = _portfolioAccountConfig.getLoanConfig().getZeroBalanceFee();
        uint256 feeAmount = (rewardsAmount * zeroBalanceFee) / 10000;
        uint256 expectedRecipientAmount = rewardsAmount - expectedCappedAmount - feeAmount;
        
        // Verify recipient received amount after capped gas reclamation deduction
        assertEq(recipientBalanceAfter, recipientBalanceBefore + expectedRecipientAmount, "Recipient should receive rewards minus capped gas reclamation and fee");
        
        // Verify authorized caller received the capped gas reclamation
        assertEq(authorizedCallerBalanceAfter, authorizedCallerBalanceBefore + expectedCappedAmount, "Authorized caller should receive capped gas reclamation");
        
        // Verify portfolio balance is 0 (all rewards processed, including gas reclamation transfer)
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have processed all rewards");
    }

    function testProcessRewardsWithGasReclamationActiveLoan() public {
        // Create active loan
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 500e6;
        
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000;
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);
        
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund portfolio with rewards
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewardsAmount);
        
        uint256 gasReclamationAmount = 10e6; // 10 USDC
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 portfolioBalanceBefore = IERC20(loanAsset).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceBefore = IERC20(loanAsset).balanceOf(_authorizedCaller);
        
        // Process rewards with gas reclamation
        // Use vm.startPrank with both msg.sender and tx.origin set to _authorizedCaller
        // since gas reclamation is transferred to tx.origin
        vm.startPrank(_authorizedCaller, _authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewardsAmount,
            address(0),
            0,
            new bytes(0),
            gasReclamationAmount
        );
        vm.stopPrank();
        
        // Verify debt was decreased (accounting for gas reclamation deduction)
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 portfolioBalanceAfter = IERC20(loanAsset).balanceOf(_portfolioAccount);
        uint256 authorizedCallerBalanceAfter = IERC20(loanAsset).balanceOf(_authorizedCaller);
        
        // Calculate expected fees and debt payment
        uint256 protocolFee = (rewardsAmount * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewardsAmount * _loanConfig.getLenderPremium()) / 10000;
        uint256 zeroBalanceFee = (rewardsAmount * _loanConfig.getZeroBalanceFee()) / 10000;
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        uint256 amountForDebt = rewardsAmount - gasReclamationAmount - totalFees;
        
        // Debt should be decreased by amountForDebt (or to zero if less)
        uint256 expectedDebt = debtBefore > amountForDebt ? debtBefore - amountForDebt : 0;
        assertEq(debtAfter, expectedDebt, "Debt should be decreased accounting for gas reclamation");
        
        // Verify portfolio balance is 0 (all rewards processed)
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have processed all rewards");
        
        // Verify authorized caller received the gas reclamation
        assertEq(authorizedCallerBalanceAfter, authorizedCallerBalanceBefore + gasReclamationAmount, "Authorized caller should have received gas reclamation");
    }

    function testProcessRewardsActiveLoanWith100Rewards() public {
        // Create active loan by adding collateral and borrowing
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 100e6; // 100 USDC borrowed
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);

        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Get initial outstanding capital from loan contract
        uint256 outstandingCapitalBefore = ILoan(_loanContract).activeAssets();
        
        // Get actual debt (may include origination fees or other adjustments)
        uint256 actualDebtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        
        // Calculate required rewards amount to cover debt + fees
        // Since fees are a percentage of rewards, we need to solve: rewards >= debt + (rewards * feeRate / 10000)
        // This gives us: rewards >= debt / (1 - feeRate / 10000)
        uint256 treasuryFeeRate = _loanConfig.getTreasuryFee();
        uint256 lenderPremiumRate = _loanConfig.getLenderPremium();
        uint256 zeroBalanceFeeRate = _loanConfig.getZeroBalanceFee();
        uint256 totalFeeRate = treasuryFeeRate + lenderPremiumRate + zeroBalanceFeeRate;
        
        // Calculate minimum rewards needed: rewards = debt / (1 - totalFeeRate / 10000)
        // Using fixed point math: rewards = (debt * 10000) / (10000 - totalFeeRate)
        uint256 rewards = 100e6;
        if (actualDebtBefore > 0 && totalFeeRate < 10000) {
            uint256 minRewardsNeeded = (actualDebtBefore * 10000) / (10000 - totalFeeRate);
            if (rewards < minRewardsNeeded) {
                rewards = minRewardsNeeded;
            }
        }
        
        // Calculate fees based on final rewards amount
        uint256 protocolFee = (rewards * treasuryFeeRate) / 10000;
        uint256 lenderPremium = (rewards * lenderPremiumRate) / 10000;
        uint256 zeroBalanceFee = (rewards * zeroBalanceFeeRate) / 10000;
        
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewards);

        address owner = _portfolioAccountConfig.owner();
        uint256 ownerBalanceBefore = IERC20(loanAsset).balanceOf(owner);

        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewards,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();

        // Verify debt is fully paid
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be fully paid");

        // Recalculate fees based on actual rewards amount used (may have been increased)
        protocolFee = (rewards * _loanConfig.getTreasuryFee()) / 10000;
        lenderPremium = (rewards * _loanConfig.getLenderPremium()) / 10000;
        zeroBalanceFee = (rewards * _loanConfig.getZeroBalanceFee()) / 10000;

        // Verify owner received correct protocol fee
        uint256 ownerBalanceAfter = IERC20(loanAsset).balanceOf(owner);
        uint256 ownerReceived = ownerBalanceAfter - ownerBalanceBefore;
        assertEq(ownerReceived, protocolFee, "Owner should receive protocol fee");

        // Verify outstanding capital decreased by the amount paid
        uint256 outstandingCapitalAfter = ILoan(_loanContract).activeAssets();
        uint256 capitalDecreased = outstandingCapitalBefore - outstandingCapitalAfter;
        assertEq(capitalDecreased, actualDebtBefore, "Outstanding capital should decrease by debt amount");

        // Verify portfolio balance is zero (all funds used)
        uint256 portfolioBalanceAfter = IERC20(loanAsset).balanceOf(_portfolioAccount);
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have used all rewards");
    }

    function testProcessRewardsActiveLoanWith50DebtAnd100Rewards() public {
        // Create active loan with $50 debt
        addCollateralViaMulticall(_tokenId);
        uint256 borrowAmount = 50e6; // 50 USDC debt
        
        // Fund vault so borrow can succeed (need enough for 80% cap: borrowAmount / 0.8)
        address vault = ILoan(_loanContract)._vault();
        uint256 vaultBalance = (borrowAmount * 10000) / 8000; // Enough for 80% cap
        deal(address(_usdc), vault, vaultBalance);
        
        borrowViaMulticall(borrowAmount);

        // Get the loan contract asset
        address loanAsset = ILoan(_loanContract)._asset();
        
        // Fund the portfolio account with 500 USDC for rewards (increased to avoid rounding issues)
        uint256 rewards = 500e6;
        address minter = IUSDC(loanAsset).masterMinter();
        vm.startPrank(minter);
        IUSDC(loanAsset).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(loanAsset).mint(_portfolioAccount, rewards);

        address owner = _portfolioAccountConfig.owner();
        address recipientAddress = address(0x1234); // From setUp
        address portfolioOwner = _portfolioFactory.ownerOf(_portfolioAccount);
        uint256 ownerBalanceBefore = IERC20(loanAsset).balanceOf(owner);
        uint256 recipientBalanceBefore = IERC20(loanAsset).balanceOf(recipientAddress);
        uint256 portfolioOwnerVaultSharesBefore = IERC20(vault).balanceOf(portfolioOwner);
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();

        // Process rewards
        vm.startPrank(_authorizedCaller);
        rewardsProcessingFacet.processRewards(
            _tokenId,
            rewards,
            address(0),
            0,
            new bytes(0),
            0 // gas reclamation
        );
        vm.stopPrank();

        // Verify debt is fully paid
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be fully paid");

        // Calculate expected amounts
        uint256 protocolFee = (rewards * _loanConfig.getTreasuryFee()) / 10000;
        uint256 lenderPremium = (rewards * _loanConfig.getLenderPremium()) / 10000;
        uint256 zeroBalanceFee = (rewards * _loanConfig.getZeroBalanceFee()) / 10000;
        uint256 totalFees = protocolFee + lenderPremium + zeroBalanceFee;
        // Use actual debt (may be less than borrowAmount if capped)
        uint256 actualDebt = debtBefore;
        uint256 amountForDebt = actualDebt; // Actual debt used
        uint256 remainingAfterDebt = rewards - totalFees - amountForDebt;

        // Verify owner received protocol fee
        uint256 ownerBalanceAfter = IERC20(loanAsset).balanceOf(owner);
        uint256 ownerReceived = ownerBalanceAfter - ownerBalanceBefore;
        assertEq(ownerReceived, protocolFee, "Owner should receive protocol fee");

        // Verify portfolio owner received vault shares (not recipient)
        // Note: zero balance fee was already paid in _processActiveLoanRewards, so remaining goes to portfolio owner as vault shares
        uint256 portfolioOwnerVaultSharesAfter = IERC20(vault).balanceOf(portfolioOwner);
        uint256 portfolioOwnerVaultSharesReceived = portfolioOwnerVaultSharesAfter - portfolioOwnerVaultSharesBefore;
        assertGt(portfolioOwnerVaultSharesReceived, 0, "Portfolio owner should receive vault shares");
        
        // Verify recipient did NOT receive the loan asset
        uint256 recipientBalanceAfter = IERC20(loanAsset).balanceOf(recipientAddress);
        uint256 recipientReceived = recipientBalanceAfter - recipientBalanceBefore;
        assertEq(recipientReceived, 0, "Recipient should not receive loan asset");

        // Verify portfolio balance is zero (all funds used)
        uint256 portfolioBalanceAfter = IERC20(loanAsset).balanceOf(_portfolioAccount);
        assertEq(portfolioBalanceAfter, 0, "Portfolio should have used all rewards");
    }
}

