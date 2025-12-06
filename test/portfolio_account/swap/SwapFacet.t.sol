// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {MockOdosRouterRL} from "../../mocks/MockOdosRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSDC} from "../../../src/interfaces/IUSDC.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

contract SwapFacetTest is Test, Setup {
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
        // Try deal first, if it doesn't work, transfer from a known holder
        deal(inputToken, _portfolioAccount, inputAmount);
        
        // Verify balance and transfer from known holder if needed
        if (IERC20(inputToken).balanceOf(_portfolioAccount) < inputAmount) {
            // Transfer from a known AERO holder (similar to Aerodrome.t.sol)
            address aeroHolder = 0x7269de76188E6597444D0859C4e5c336D3c39dDb;
            vm.prank(aeroHolder);
            IERC20(inputToken).transfer(_portfolioAccount, inputAmount);
        }
        
        // Fund the mock router with output tokens (USDC)
        // For USDC, we need to mint it
        address minter = IUSDC(outputToken).masterMinter();
        vm.startPrank(minter);
        IUSDC(outputToken).configureMinter(address(this), type(uint256).max);
        vm.stopPrank();
        IUSDC(outputToken).mint(address(mockRouter), outputAmount * 2); // Mint enough for the swap
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
        _swapConfig.approveSwapTarget(address(mockRouter));
        vm.stopPrank();
        // Execute swap via authorized caller
        vm.startPrank(_authorizedCaller);
        swapFacet.swap(
            address(_swapConfig),
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
        uint256 routerInputAfter = IERC20(inputToken).balanceOf(address(mockRouter));
        uint256 routerOutputAfter = IERC20(outputToken).balanceOf(address(mockRouter));
        
        // Portfolio account should have lost input tokens
        assertEq(portfolioInputAfter, portfolioInputBefore - inputAmount, "Portfolio should have sent input tokens");
        
        // Portfolio account should have gained output tokens
        assertEq(portfolioOutputAfter, portfolioOutputBefore + outputAmount, "Portfolio should have received output tokens");
        
        // Router should have received input tokens
        assertEq(routerInputAfter, routerInputBefore + inputAmount, "Router should have received input tokens");
        
        // Router should have sent output tokens
        assertEq(routerOutputAfter, routerOutputBefore - outputAmount, "Router should have sent output tokens");
        
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
            address(_swapConfig),
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
            address(_swapConfig),
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
            address(_swapConfig),
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
            address(_swapConfig),
            address(mockRouter),
            new bytes(0),
            inputToken,
            inputAmount,
            outputToken,
            0 // zero expected output should fail
        );
        vm.stopPrank();
    }
}

