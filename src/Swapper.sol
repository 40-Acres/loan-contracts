// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;


import { IRouter } from "./interfaces/IRouter.sol";
import { IPoolFactory } from "./interfaces/IPoolFactory.sol";
import { IPool } from "./interfaces/IPool.sol";

import {Test, console} from "forge-std/Test.sol";

contract Swapper {
    address[] public supportedTokens;
    address public factory;
    IRouter public router;
    uint256 public constant GRANULARITY = 3;
    uint256 public constant SLIPPAGE = 500; // 5% slippage

    constructor(address _factory, address _router, address[] memory _supportedTokens) {
        require(_supportedTokens.length <= 3, "Swapper: Too many supported tokens, max 3 allowed");
        factory = _factory;
        router = IRouter(_router);
        supportedTokens = _supportedTokens;
    }

    function _getAllRoutes(
        address token0,
        address token1
    ) internal view returns (IRouter.Route[2][6] memory, uint256) {
        uint256 length = 0;
        IRouter.Route[2][6] memory tokenRoutes; // max 6 intermediate tokens, each route has 2 hops
        if (token0 == token1) {
            return (tokenRoutes, length); // if both tokens are the same, return early
        }
        // Ensure the tokens are not zero address
        address _factory = factory;
        address[] memory _supportedTokens = supportedTokens;

        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            if (_supportedTokens[i] == token0 || _supportedTokens[i] == token1) {
                continue; // skip if token is the same as token0 or token1
            }
            // Add routes for token0 -> supportedToken -> token1
            tokenRoutes[length][0] = IRouter.Route(token0, _supportedTokens[i], true, _factory);
            tokenRoutes[length + 1][0] = IRouter.Route(token0, _supportedTokens[i], false, _factory);

            tokenRoutes[length][1] = IRouter.Route(_supportedTokens[i], token1, false, _factory);
            tokenRoutes[length + 1][1] = IRouter.Route(_supportedTokens[i], token1, false, _factory);
            length += 2;
        }

        return (tokenRoutes, length);
    }

    function getBestRoute(
        address token0,
        address token1,
        uint256 amountIn
    ) external view returns (IRouter.Route[] memory) {
        uint256 optimalIndex;
        uint256 optimalAmountOut;
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        uint256[] memory amountsOut;

        (IRouter.Route[2][6] memory tokenRoutes, uint256 length) = _getAllRoutes(token0, token1);
        for (uint256 i = 0; i < length; i++) {
            routes[0] = tokenRoutes[i][0];
            routes[1] = tokenRoutes[i][1];

            if (IPoolFactory(routes[0].factory).getPool(routes[0].from, routes[0].to, routes[0].stable) == address(0)) {
                continue;
            }
            try router.getAmountsOut(amountIn, routes) returns (uint256[] memory _amountsOut) {
                amountsOut = _amountsOut;
            } catch {
                continue;
            }
            
            uint256 amountOut = amountsOut[2];
            if (amountOut > optimalAmountOut) {
                optimalAmountOut = amountOut;
                optimalIndex = i;
            }
        }
        
        // use the optimal route determined from the loop
        for( uint256 j = 0; j < routes.length; j++) {
            routes[j] = tokenRoutes[optimalIndex][j];
        }

        // check if direct route is better
        IRouter.Route[] memory directRoute = new IRouter.Route[](1);
        directRoute[0] = IRouter.Route(token0, token1, false, factory);
        amountsOut = router.getAmountsOut(amountIn, directRoute);
        uint256 singleSwapAmountOut = amountsOut[1];
        if(singleSwapAmountOut > optimalAmountOut) {
            return directRoute; // if direct route is better, return it
        }
        return routes;
    }

    function getMinimumAmountOut(
        IRouter.Route[] calldata routes,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 length = routes.length;

        for (uint256 i = 0; i < length; i++) {
            IRouter.Route memory route = routes[i];
            address pool = IPoolFactory(route.factory).getPool(route.from, route.to, route.stable);
            if (pool == address(0)) return 0;
            uint256 amountOut = IPool(pool).quote(route.from, amountIn, GRANULARITY);
            amountIn = amountOut;
        }

        return  (amountIn * (10000 - SLIPPAGE)) / 10000;
    }
}