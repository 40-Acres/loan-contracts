// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
/**
 * @title SwapMod
 * @dev Diamond facet for swapping tokens
 */

library SwapMod {
    event SwapExecuted(address indexed swapTarget, address indexed inputToken, uint256 inputAmount, address indexed outputToken, uint256 outputAmount);
    
    error NotApprovedSwapTarget(address swapTarget);
    error SwapFailed();

    struct RouteParams {
        address swapConfig;
        address swapTarget;
        bytes swapData;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minimumOutputAmount;
    }

    function swap(RouteParams memory swapData) public returns (uint256 amount) {
        require(swapData.inputToken != swapData.outputToken, "Same token swap not allowed");
        uint256 balanceBefore = IERC20(swapData.outputToken).balanceOf(address(this));
        if(!SwapConfig(swapData.swapConfig).isApprovedSwapTarget(swapData.swapTarget)) {
            revert NotApprovedSwapTarget(swapData.swapTarget);
        }
        IERC20(swapData.inputToken).approve(swapData.swapTarget, swapData.inputAmount);
        (bool success, ) = swapData.swapTarget.call(swapData.swapData);
        require(success, "Swap failed");
        IERC20(swapData.inputToken).approve(swapData.swapTarget, 0);
        uint256 balanceAfter = IERC20(swapData.outputToken).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;
        require(amount >= swapData.minimumOutputAmount, "Slippage exceeded");
        emit SwapExecuted(swapData.swapTarget, swapData.inputToken, swapData.inputAmount, swapData.outputToken, amount);
        return amount;
    }

}
