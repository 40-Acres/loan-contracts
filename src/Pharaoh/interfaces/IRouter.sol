// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IRouter {
    struct route {
        address from;
        address to;
        bool stable;
    }


    function pairFor(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);

    function getAmountsOut(
        uint256 amountIn,
        route[] memory routes
    ) external view returns (uint256[] memory amounts);


    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
