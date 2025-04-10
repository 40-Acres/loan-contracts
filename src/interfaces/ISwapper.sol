// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import { IRouter } from "./IRouter.sol";

interface ISwapper {
    function getBestRoute(
        address token0,
        address token1,
        uint256 amountIn
    ) external view returns (IRouter.Route[] memory);

    function getMinimumAmountOut(
        IRouter.Route[] calldata routes,
        uint256 amountIn
    ) external view returns (uint256 amountOutMin);

    function flattenToken(address[][] memory tokens) external pure returns (address[] memory);

    function getTokenBalances(address[] memory tokens) external view returns (uint256[] memory balances);
}