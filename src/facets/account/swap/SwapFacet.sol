// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SwapFacet
 * @dev Facet that swaps tokens within the portfolio
 */
contract SwapFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;

    error NotApprovedSwapContract(address swapContract);
    
    constructor(address portfolioFactory, address portfolioAccountConfig) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function swap(address swapContract, bytes calldata data, address outputToken, uint256 expectedOutputAmount) external {
        uint256 beginningOutputTokenBalance = IERC20(outputToken).balanceOf(address(this));
        require(outputToken != address(0));
        require(expectedOutputAmount > 0);
        IERC20(outputToken).approve(address(swapContract), IERC20(outputToken).balanceOf(address(this)));
        (bool success, ) = swapContract.call(data);
        require(success);

        uint256 endingOutputTokenBalance = IERC20(outputToken).balanceOf(address(this));
        uint256 outputAmount = endingOutputTokenBalance - beginningOutputTokenBalance;  
        require(outputAmount >= expectedOutputAmount);
        IERC20(outputToken).approve(address(swapContract), 0);
    }
}

