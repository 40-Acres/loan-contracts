// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockOdosRouterRL is Test {
    address public testContract;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external returns (bool) {
        if(amountIn > 0) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }
        if(amountOut > 0) {
            uint256 balance = IERC20(tokenOut).balanceOf(receiver);
            deal(tokenOut, receiver, amountOut + balance);
        }
        return true;
    }

    function executeSwapMultiOutput(address token1, address token2, uint256 amount1, uint256 amount2, address receiver) external returns (bool) {
        if(amount1 > 0) {
            uint256 balance = IERC20(token1).balanceOf(receiver);
            deal(token1, receiver, amount1 + balance);
        }
        if(amount2 > 0) {
            uint256 balance = IERC20(token2).balanceOf(receiver);  
            deal(token2, receiver, amount2 + balance);
        }
        return true;
    }

}