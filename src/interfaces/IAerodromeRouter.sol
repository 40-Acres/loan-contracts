// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouter} from "./IRouter.sol";

interface IAerodromeRouter {

    error DepositsNotEqual();
    error BelowMinimumK();
    error FactoryAlreadySet();
    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error IsPaused();
    error InvalidTo();
    error K();
    error NotEmergencyCouncil();
    
  function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IRouter.Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, IRouter.Route[] memory routes) external view returns (uint256[] memory amounts);
}