// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "../LoanV2.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

contract PharoahLoanV2 is Loan {

        /* ORACLE */
    function confirmUsdcPrice() internal view override returns (bool) {
        return true;
    }

    function _swapToToken(
        uint256 amountIn,
        address fromToken,
        address toToken,
        address borrower
    ) internal override returns (uint256 amountOut) {
        require(fromToken != address(_ve)); // Prevent swapping veNFT
        if (fromToken == toToken || amountIn == 0) {
            return amountIn;
        }
        IERC20(fromToken).approve(address(_aeroRouter), 0); // reset approval first
        IERC20(fromToken).approve(address(_aeroRouter), amountIn);
        ISwapper swapper = ISwapper(getSwapper());
        IRouter.route[] memory routes = ISwapper(swapper).getBestRoute(fromToken, toToken, amountIn);
        uint256 minimumAmountOut = ISwapper(swapper).getMinimumAmountOut(routes, amountIn);
        
        if (minimumAmountOut == 0) {
            // send to borrower if the swap returns 0
            IERC20(fromToken).transfer(borrower, amountIn);
            return 0;
        }
        uint256[] memory amounts = IRouter(address(_aeroRouter)).swapExactTokensForTokens(
                amountIn,
                minimumAmountOut,
                routes,
                address(this),
                block.timestamp
            );
        return amounts[amounts.length - 1];
    }
}