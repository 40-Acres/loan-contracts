// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockBatchSwapTarget
 * @notice Single-pair aggregator stand-in for FortyAcresBatchRouter fork tests.
 * @dev Pulls the input the router approved and pays output from a pre-funded stash,
 *      exactly as a real executor contract would. Uses no cheatcodes so it works when
 *      the router is etched at a legacy address.
 */
contract MockBatchSwapTarget {
    function swap(address inputToken, uint256 pullAmount, address outputToken, uint256 outAmount) external {
        if (pullAmount > 0) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), pullAmount);
        }
        if (outAmount > 0) {
            IERC20(outputToken).transfer(msg.sender, outAmount);
        }
    }

    /// Two-output fill, used where the legacy blob produced two tokens at once.
    function swapTwo(
        address inputToken,
        uint256 pullAmount,
        address out1,
        uint256 amount1,
        address out2,
        uint256 amount2
    ) external {
        if (pullAmount > 0) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), pullAmount);
        }
        if (amount1 > 0) {
            IERC20(out1).transfer(msg.sender, amount1);
        }
        if (amount2 > 0) {
            IERC20(out2).transfer(msg.sender, amount2);
        }
    }
}
