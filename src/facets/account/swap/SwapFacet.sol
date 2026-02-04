// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwapMod} from "./SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {AccessControl} from "../../account/utils/AccessControl.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";

/**
 * @title SwapFacet
 * @dev Facet that swaps tokens within the portfolio
 */
contract SwapFacet is AccessControl {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    SwapConfig public immutable _swapConfig;
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _swapConfig = SwapConfig(swapConfig);
    }

    function swap(address swapTarget, bytes memory swapData, address inputToken, uint256 inputAmount, address outputToken, uint256 minimumOutputAmount) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 amount) {
        if(inputToken == CollateralFacet(address(this)).getCollateralToken()) {
            revert("Input token cannot be collateral token");
        }
        amount = SwapMod.swap(address(_swapConfig), swapTarget, swapData, inputToken, inputAmount, outputToken, minimumOutputAmount);
        return amount;
    }

    function userSwap(address swapTarget, bytes memory swapData, address inputToken, uint256 inputAmount, address outputToken, uint256 minimumOutputAmount) external onlyPortfolioManagerMulticall(_portfolioFactory) returns (uint256 amount) {
        if(inputToken == CollateralFacet(address(this)).getCollateralToken()) {
            revert("Input token cannot be collateral token");
        }
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        IERC20(inputToken).safeTransferFrom(portfolioOwner, address(this), inputAmount);
        amount = SwapMod.swap(address(_swapConfig), swapTarget, swapData, inputToken, inputAmount, outputToken, minimumOutputAmount);
        return amount;
    }

}

