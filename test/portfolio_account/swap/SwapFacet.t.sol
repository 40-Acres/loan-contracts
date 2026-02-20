// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";

contract SwapFacetTest is Test, LocalSetup {
    SwapFacet public swapFacet;
    MockOdosRouterRL public mockRouter;
    
    address public inputToken; // AERO
    address public outputToken; // USDC
    uint256 public inputAmount = 1000e18;
    uint256 public outputAmount = 500e6; // 500 USDC
    uint256 public expectedOutputAmount = 450e6; // 450 USDC (with slippage tolerance)

    function setupSwapTest() internal {
        // SwapFacet is already deployed via DeployFacets in Setup
        // Just initialize the swapFacet reference
        swapFacet = SwapFacet(_portfolioAccount);
        
        // Deploy MockOdosRouter
        mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));
        
        // Set up tokens
        inputToken = address(_aero);
        outputToken = address(_usdc);
        
        // Fund the portfolio account with input tokens (AERO)
        deal(inputToken, _portfolioAccount, inputAmount);

        // Fund the mock router with output tokens (USDC)
        deal(outputToken, address(mockRouter), outputAmount * 2);
    }

    function testSwap() public {
        setupSwapTest();
        
        // Record initial balances
        uint256 portfolioInputBefore = IERC20(inputToken).balanceOf(_portfolioAccount);
        uint256 portfolioOutputBefore = IERC20(outputToken).balanceOf(_portfolioAccount);
        uint256 routerInputBefore = IERC20(inputToken).balanceOf(address(mockRouter));
        uint256 routerOutputBefore = IERC20(outputToken).balanceOf(address(mockRouter));
        
        // Pre-approve input token for mock router (since SwapFacet only approves output token)
        vm.prank(_portfolioAccount);
        IERC20(inputToken).approve(address(mockRouter), inputAmount);
        
        // Create swap data to call executeSwap on MockOdosRouter
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken,      // tokenIn
            outputToken,     // tokenOut
            inputAmount,     // amountIn
            outputAmount,    // amountOut
            _portfolioAccount // receiver
        );
        
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
        // Execute swap via authorized caller
        vm.startPrank(_authorizedCaller);
        swapFacet.swap(
            address(mockRouter),
            swapData,
            inputToken,
            IERC20(inputToken).balanceOf(_portfolioAccount),
            outputToken,
            expectedOutputAmount
        );
        vm.stopPrank();
        
        // Verify balances after swap
        uint256 portfolioInputAfter = IERC20(inputToken).balanceOf(_portfolioAccount);
        uint256 portfolioOutputAfter = IERC20(outputToken).balanceOf(_portfolioAccount);
        
        // Portfolio account should have lost input tokens
        assertEq(portfolioInputAfter, portfolioInputBefore - inputAmount, "Portfolio should have sent input tokens");
        
        // Portfolio account should have gained output tokens
        assertEq(portfolioOutputAfter, portfolioOutputBefore + outputAmount, "Portfolio should have received output tokens");
        
        
        // Verify output amount meets expected minimum
        uint256 actualOutput = portfolioOutputAfter - portfolioOutputBefore;
        assertGe(actualOutput, expectedOutputAmount, "Output amount should meet expected minimum");
    }

    function testSwapFailsWithInsufficientOutput() public {
        setupSwapTest();
        
        // Pre-approve input token
        vm.prank(_portfolioAccount);
        IERC20(inputToken).approve(address(mockRouter), inputAmount);
        
        // Create swap data with lower output amount than expected
        uint256 lowOutputAmount = expectedOutputAmount - 1;
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken,
            outputToken,
            inputAmount,
            lowOutputAmount,
            _portfolioAccount
        );
        
        // This should fail because output amount is less than expected
        vm.startPrank(_authorizedCaller, _authorizedCaller);
        vm.expectRevert();
        swapFacet.swap(
            address(mockRouter),
            swapData,
            inputToken,
            inputAmount,
            outputToken,
            expectedOutputAmount
        );
        vm.stopPrank();
    }

    function testSwapFailsWithUnauthorizedCaller() public {
        setupSwapTest();
        
        // Pre-approve input token
        vm.prank(_portfolioAccount);
        IERC20(inputToken).approve(address(mockRouter), inputAmount);
        
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            _portfolioAccount
        );
        
        // Try to call from unauthorized address
        vm.prank(address(0x1234));
        vm.expectRevert();
        swapFacet.swap(
            address(mockRouter),
            swapData,
            inputToken,
            inputAmount,
            outputToken,
            expectedOutputAmount
        );
    }

    function testSwapFailsWithZeroOutputToken() public {
        setupSwapTest();

        vm.startPrank(_authorizedCaller, _authorizedCaller);
        vm.expectRevert();
        swapFacet.swap(
            address(mockRouter),
            new bytes(0),
            inputToken,
            inputAmount,
            address(0), // zero address should fail
            expectedOutputAmount
        );
        vm.stopPrank();
    }

    function testSwapFailsWithZeroExpectedOutput() public {
        setupSwapTest();

        vm.startPrank(_authorizedCaller, _authorizedCaller);
        vm.expectRevert();
        swapFacet.swap(
            address(mockRouter),
            new bytes(0),
            inputToken,
            inputAmount,
            outputToken,
            0 // zero expected output should fail
        );
        vm.stopPrank();
    }

    function testSwapFailsWithCollateralToken() public {
        setupSwapTest();
        
        // Get the collateral token address
        address collateralToken = CollateralFacet(_portfolioAccount).getCollateralToken();
        
        bytes memory swapData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            collateralToken,  // Attempt to swap collateral token
            outputToken,
            inputAmount,
            outputAmount,
            _portfolioAccount
        );
        
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _swapConfig.setApprovedSwapTarget(address(mockRouter), true);
        vm.stopPrank();
        
        // Attempt to swap collateral token - should fail
        vm.startPrank(_authorizedCaller);
        vm.expectRevert("Input token cannot be collateral token");
        swapFacet.swap(
            address(mockRouter),
            swapData,
            collateralToken,  // Using collateral token as input
            inputAmount,
            outputToken,
            expectedOutputAmount
        );
        vm.stopPrank();
    }
}

