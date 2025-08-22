// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Errors} from "./Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IPool} from "../interfaces/IPool.sol";
import {MarketStorage} from "./storage/MarketStorage.sol";
import {IWETH} from "../interfaces/IWETH.sol";

library SwapRouterLib {
    using SafeERC20 for IERC20;
    
    uint256 public constant GRANULARITY = 3;
    uint256 public constant SLIPPAGE = 500; // 5% slippage
    uint256 public constant DEADLINE = 300; // 5 minutes

    function enforceMinOut(uint256 beforeBalance, uint256 afterBalance, uint256 minOut) internal pure {
        if (afterBalance < beforeBalance + minOut) revert Errors.Slippage();
    }

    /**
     * @dev Internal function to generate all possible token swap routes between two tokens.
     *      The function considers intermediate tokens from the list of supported tokens
     *      and creates routes with up to two hops.
     * @param token0 The address of the first token in the swap.
     * @param token1 The address of the second token in the swap.
     * @param supportedTokens Array of supported intermediate tokens.
     * @param factory The pool factory address.
     * @return tokenRoutes A 2D array of routes, where each route consists of two hops.
     *         Each hop is represented as an `IRouter.Route` struct.
     * @return length The number of valid routes generated.
     */
    function getAllRoutes(
        address token0,
        address token1,
        address[] memory supportedTokens,
        address factory
    ) internal pure returns (IRouter.Route[2][6] memory, uint256) {
        uint256 length = 0;
        IRouter.Route[2][6] memory tokenRoutes; // max 6 intermediate tokens, each route has 2 hops
        
        if (token0 == token1) {
            return (tokenRoutes, length); // if both tokens are the same, return early
        }

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token0 || supportedTokens[i] == token1) {
                continue; // skip if token is the same as token0 or token1
            }
            // Add routes for token0 -> supportedToken -> token1
            tokenRoutes[length][0] = IRouter.Route(token0, supportedTokens[i], true, factory);
            tokenRoutes[length + 1][0] = IRouter.Route(token0, supportedTokens[i], false, factory);

            tokenRoutes[length][1] = IRouter.Route(supportedTokens[i], token1, false, factory);
            tokenRoutes[length + 1][1] = IRouter.Route(supportedTokens[i], token1, false, factory);
            length += 2;
        }

        return (tokenRoutes, length);
    }

    /**
     * @notice Finds the best route for swapping a given amount of token0 to token1.
     * @dev This function evaluates multiple routes and selects the one that provides the highest output amount.
     *      It uses the `getAllRoutes` function to retrieve all possible routes and checks their validity.
     * @param token0 The address of the input token.
     * @param token1 The address of the output token.
     * @param amountIn The amount of token0 to be swapped.
     * @param supportedTokens Array of supported intermediate tokens.
     * @param factory The pool factory address.
     * @param router The router address for getting amounts out.
     * @return routes An array of `IRouter.Route` structs representing the best route for the swap.
     */
    function getBestRoute(
        address token0,
        address token1,
        uint256 amountIn,
        address[] memory supportedTokens,
        address factory,
        IRouter router
    ) internal view returns (IRouter.Route[] memory) {
        uint256 optimalIndex;
        uint256 optimalAmountOut;
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        uint256[] memory amountsOut;

        (IRouter.Route[2][6] memory tokenRoutes, uint256 length) = getAllRoutes(token0, token1, supportedTokens, factory);
        
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
        IRouter.Route[] calldata routes,
        uint256 amountIn
    ) internal view returns (uint256) {
        uint256 length = routes.length;

        for (uint256 i = 0; i < length; i++) {
            IRouter.Route memory route = routes[i];
            address pool = IPoolFactory(route.factory).getPool(route.from, route.to, route.stable);
            if (pool == address(0)) return 0;
            uint256 amountOut = IPool(pool).quote(route.from, amountIn, GRANULARITY);
            amountIn = amountOut;
        }

        return (amountIn * (10000 - SLIPPAGE)) / 10000;
    }

    /**
     * @notice Executes a swap using the provided routes.
     * @dev Transfers tokens from the caller, executes the swap, and returns the output amount.
     * @param routes The swap routes to execute.
     * @param amountIn The amount of input tokens.
     * @param amountOutMin The minimum amount of output tokens to receive.
     * @param router The router contract to execute the swap.
     * @param deadline The deadline for the swap.
     * @return amounts The amounts received at each step of the swap.
     */
    function executeSwap(
        IRouter.Route[] memory routes,
        uint256 amountIn,
        uint256 amountOutMin,
        IRouter router,
        uint256 deadline
    ) internal returns (uint256[] memory amounts) {
        // Transfer input tokens from caller to this contract
        IERC20(routes[0].from).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Approve router to spend tokens
        IERC20(routes[0].from).forceApprove(address(router), amountIn);
        
        // Execute swap
        amounts = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            routes,
            address(this),
            deadline
        );
        
        // Reset approval
        IERC20(routes[0].from).forceApprove(address(router), 0);
    }

    /**
     * @notice Calculates the amount of input tokens needed to receive a specific amount of output tokens.
     * @dev Uses the best route to calculate the required input amount.
     * @param tokenIn The input token address.
     * @param tokenOut The output token address.
     * @param amountOut The desired output amount.
     * @param supportedTokens Array of supported intermediate tokens.
     * @param factory The pool factory address.
     * @param router The router address.
     * @return amountIn The required input amount.
     */
    function getAmountInForExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        address[] memory supportedTokens,
        address factory,
        IRouter router
    ) internal view returns (uint256 amountIn) {
        // For simplicity, we'll use a binary search approach
        // Start with a reasonable estimate
        uint256 estimate = amountOut;
        uint256 tolerance = amountOut / 1000; // 0.1% tolerance
        
        uint256 low = 0;
        uint256 high = amountOut * 10; // Assume max 10x slippage
        
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            
            IRouter.Route[] memory routes = getBestRoute(tokenIn, tokenOut, mid, supportedTokens, factory, router);
            
            if (routes.length == 0) {
                low = mid + 1;
                continue;
            }
            
            try router.getAmountsOut(mid, routes) returns (uint256[] memory amounts) {
                uint256 actualOut = amounts[amounts.length - 1];
                
                if (actualOut >= amountOut && actualOut <= amountOut + tolerance) {
                    return mid;
                } else if (actualOut < amountOut) {
                    low = mid + 1;
                } else {
                    high = mid - 1;
                }
            } catch {
                low = mid + 1;
            }
        }
        
        revert Errors.Slippage();
    }

    // ===== Address-based wrappers to avoid importing interfaces in callers =====
    function getAmountInForExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        address[] memory supportedTokens,
        address factory,
        address router
    ) internal view returns (uint256) {
        return getAmountInForExactOut(tokenIn, tokenOut, amountOut, supportedTokens, factory, IRouter(router));
    }

    function swapExactInBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] memory supportedTokens,
        address factory,
        address router,
        address to,
        uint256 deadline
    ) internal returns (uint256[] memory amounts) {
        IRouter.Route[] memory routes = getBestRoute(tokenIn, tokenOut, amountIn, supportedTokens, factory, IRouter(router));
        require(routes.length > 0, "NoValidRoute");
        // Execute swap and forward proceeds to `to`
        return IRouter(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            routes,
            to,
            deadline
        );
    }

    function swapExactInBestRouteFromUser(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] memory supportedTokens,
        address factory,
        address router,
        address to,
        uint256 deadline
    ) internal returns (uint256[] memory amounts) {
        IRouter.Route[] memory routes = getBestRoute(tokenIn, tokenOut, amountIn, supportedTokens, factory, IRouter(router));
        require(routes.length > 0, "NoValidRoute");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(router, amountIn);
        amounts = IRouter(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            routes,
            to,
            deadline
        );
        IERC20(tokenIn).forceApprove(router, 0);
    }

    // ===== ETH helpers =====
    function getAmountInETHForExactOut(
        address tokenOut,
        uint256 amountOut,
        address[] memory supportedTokens,
        address factory,
        address router
    ) internal view returns (uint256) {
        address weth = address(IRouter(router).weth());
        return getAmountInForExactOut(weth, tokenOut, amountOut, supportedTokens, factory, router);
    }

    function getAmountOutFromConfig(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        IRouter.Route[] memory routes = getBestRoute(tokenIn, tokenOut, amountIn, supported, factory, IRouter(router));
        if (routes.length == 0) return 0;
        try IRouter(router).getAmountsOut(amountIn, routes) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    function swapExactETHInBestRouteFromUser(
        address tokenOut,
        uint256 amountInETH,
        uint256 minAmountOut,
        address[] memory supportedTokens,
        address factory,
        address router,
        address to,
        uint256 deadline
    ) internal returns (uint256[] memory amounts) {
        // Build best route assuming WETH as tokenIn
        address weth = address(IRouter(router).weth());
        IRouter.Route[] memory routes = getBestRoute(weth, tokenOut, amountInETH, supportedTokens, factory, IRouter(router));
        require(routes.length > 0, "NoValidRoute");
        // Execute swap with ETH
        return IRouter(router).swapExactETHForTokens{value: amountInETH}(minAmountOut, routes, to, deadline);
    }

    // ===== Helpers: read config and supported tokens from storage =====
    function _copySupportedTokensFromConfig() private view returns (address[] memory tokens) {
        MarketStorage.MarketConfigLayout storage c = MarketStorage.configLayout();
        uint256 len = c.supportedSwapTokens.length;
        tokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i] = c.supportedSwapTokens[i];
        }
    }

    function _readRouterFactory() private view returns (address router, address factory) {
        MarketStorage.MarketConfigLayout storage c = MarketStorage.configLayout();
        router = c.swapRouter;
        factory = c.swapFactory;
        require(router != address(0) && factory != address(0), "SwapNotConfigured");
    }

    // ===== From-config wrappers =====
    function getAmountInForExactOutFromConfig(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) internal view returns (uint256) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        return getAmountInForExactOut(tokenIn, tokenOut, amountOut, supported, factory, router);
    }

    function getAmountInETHForExactOutFromConfig(
        address tokenOut,
        uint256 amountOut
    ) internal view returns (uint256) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        return getAmountInETHForExactOut(tokenOut, amountOut, supported, factory, router);
    }

    function swapExactInBestRouteFromUserFromConfig(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) internal returns (uint256[] memory) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        return swapExactInBestRouteFromUser(tokenIn, tokenOut, amountIn, minAmountOut, supported, factory, router, to, block.timestamp + DEADLINE);
    }

    function swapExactETHInBestRouteFromUserFromConfig(
        address tokenOut,
        uint256 amountInETH,
        uint256 minAmountOut,
        address to
    ) internal returns (uint256[] memory) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        return swapExactETHInBestRouteFromUser(tokenOut, amountInETH, minAmountOut, supported, factory, router, to, block.timestamp + DEADLINE);
    }

    function swapExactInBestRouteFromConfig(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) internal returns (uint256[] memory) {
        (address router, address factory) = _readRouterFactory();
        address[] memory supported = _copySupportedTokensFromConfig();
        return swapExactInBestRoute(tokenIn, tokenOut, amountIn, minAmountOut, supported, factory, router, to, block.timestamp + DEADLINE);
    }
}


