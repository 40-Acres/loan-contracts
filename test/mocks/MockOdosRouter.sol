// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockOdosRouterRL is Test {
    address public testContract;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external returns (bool) {
        IERC20(tokenIn).transferFrom(receiver, address(this), amountIn);
        IERC20(tokenOut).transfer(receiver, amountOut);
        return true;
    }

}