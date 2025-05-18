// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;


import { IPairFactory } from "../interfaces/IPairFactory.sol";
import { IPair } from "../interfaces/IPair.sol";
import { IRouter } from "./interfaces/IRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PathEncoder } from "../helpers/PathEncoder.sol";
import { console } from "forge-std/console.sol";

contract PharaohSwapper {
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

    /**
     * @dev Internal function to generate all possible token swap routes between two tokens.
     *      The function considers intermediate tokens from the list of supported tokens
     *      and creates routes with up to two hops.
     * @param token0 The address of the first token in the swap.
     * @param token1 The address of the second token in the swap.
     * @return tokenRoutes A 2D array of routes, where each route consists of two hops.
     *         Each hop is represented as an `IRouter.route` struct.
     * @return length The number of valid routes generated.
     */
    function _getAllRoutes(
        address token0,
        address token1
    ) internal view returns (IRouter.route[2][6] memory, uint256) {
        uint256 length = 0;
        IRouter.route[2][6] memory tokenRoutes; // max 6 intermediate tokens, each route has 2 hops
        if (token0 == token1) {
            return (tokenRoutes, length); // if both tokens are the same, return early
        }
        address[] memory _supportedTokens = supportedTokens;

        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            if (_supportedTokens[i] == token0 || _supportedTokens[i] == token1) {
                continue; // skip if token is the same as token0 or token1
            }
            // Add routes for token0 -> supportedToken -> token1
            tokenRoutes[length][0] = IRouter.route(token0, _supportedTokens[i], true);
            tokenRoutes[length + 1][0] = IRouter.route(token0, _supportedTokens[i], false);

            tokenRoutes[length][1] = IRouter.route(_supportedTokens[i], token1, false);
            tokenRoutes[length + 1][1] = IRouter.route(_supportedTokens[i], token1, false);
            length += 2;
        }

        return (tokenRoutes, length);
    }

    /**
     * @notice Finds the best route for swapping a given amount of token0 to token1.
     * @dev This function evaluates multiple routes and selects the one that provides the highest output amount.
     *      It uses the `_getAllRoutes` function to retrieve all possible routes and checks their validity.
     * @param token0 The address of the input token.
     * @param token1 The address of the output token.
     * @param amountIn The amount of token0 to be swapped.
     * @return routes An array of `IRouter.route` structs representing the best route for the swap.
     */
    function getBestRoute(
        address token0,
        address token1,
        uint256 amountIn
    ) external view returns (IRouter.route[] memory) {
        uint256 optimalIndex;
        uint256 optimalAmountOut;
        IRouter.route[] memory routes = new IRouter.route[](2);
        uint256[] memory amountsOut;

        (IRouter.route[2][6] memory tokenRoutes, uint256 length) = _getAllRoutes(token0, token1);
        for (uint256 i = 0; i < length; i++) {
            routes[0] = tokenRoutes[i][0];
            routes[1] = tokenRoutes[i][1];

            if (router.pairFor(routes[0].from, routes[0].to, routes[0].stable) == address(0)) {
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
        IRouter.route[] memory directRoute = new IRouter.route[](1);
        directRoute[0] = IRouter.route(token0, token1, false);
        amountsOut = router.getAmountsOut(amountIn, directRoute);
        uint256 singleSwapAmountOut = amountsOut[1];
        if(singleSwapAmountOut > optimalAmountOut) {
            return directRoute; // if direct route is better, return it
        }
        return routes;
    }

    /**
     * @notice Calculates the minimum amount of output tokens that can be received for a given input amount
     *         across a series of swap routes, accounting for slippage.
     * @dev Iterates through the provided routes to compute the output amount at each step.
     *      If any pool in the route does not exist, the function returns 0.
     * @param routes An array of swap routes, where each route specifies the token pair, factory, and stability.
     * @param amountIn The amount of input tokens to be swapped.
     * @return amountOut The minimum amount of output tokens after applying slippage.
     */
    function getMinimumAmountOut(
        IRouter.route[] calldata routes,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 length = routes.length;

        for (uint256 i = 0; i < length; i++) {
            IRouter.route[] memory route = new IRouter.route[](1);
            route[0] = routes[i];
            // address pool = router.pairFor(route.from, route.to, route.stable);
            // if (pool == address(0)) return 0;
            uint256[] memory amountsOut = router.getAmountsOut(amountIn, route);
            uint256 amountOut = amountsOut[amountsOut.length - 1];
            amountIn = amountOut;
        }

        return (amountIn * (10000 - SLIPPAGE)) / 10000;
    }
    
    /**
     * @dev Flattens a two-dimensional array of token addresses into a single-dimensional array.
     * @param tokens A two-dimensional array of token addresses to be flattened.
     * @return An array containing all token addresses from the input in a single dimension.
     */
    function flattenToken(address[][] memory tokens) public pure returns (address[] memory) {
        uint256 totalLength = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalLength += tokens[i].length;
        }
        address[] memory totalTokens = new address[](totalLength);
        uint256 index = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                totalTokens[index] = tokens[i][j];
                index++;
            }
        }
        return totalTokens;
    }

    /**
     * @dev Retrieves the token balances of the caller (`msg.sender`) for a given list of token addresses.
     * @param tokens An array of ERC20 token addresses to query balances for.
     * @return balances An array of token balances corresponding to the provided token addresses.
     */
    function getTokenBalances(address[] memory tokens) public view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = IERC20(tokens[i]).balanceOf(msg.sender);
        }
    }

}