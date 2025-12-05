// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
/**
 * @title SwapMod
 * @dev Diamond facet for swapping tokens
 */

library SwapMod {
    error NotApprovedSwapTarget(address swapTarget);

    error SwapFailed();

    function swap(address swapConfig, address swapTarget, bytes memory swapData, address inputToken, uint256 inputAmount, address outputToken, uint256 minimumOutputAmount) public returns (uint256 amount) {
        uint256 balanceBefore = IERC20(outputToken).balanceOf(address(this));
        if(!SwapConfig(swapConfig).isApprovedSwapTarget(swapTarget)) {
            revert NotApprovedSwapTarget(swapTarget);
        }
        IERC20(inputToken).approve(swapTarget, inputAmount);
        (bool success, ) = swapTarget.call(swapData);
        require(success, "Swap failed");
        uint256 balanceAfter = IERC20(outputToken).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;
        require(amount >= minimumOutputAmount, "Slippage exceeded");
        return amount;
    }
}
