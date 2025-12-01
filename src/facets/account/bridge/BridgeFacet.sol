// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {BridgeConfigStorage} from "./BridgeConfigStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BridgeFacet
 * @dev Facet that bridges tokens between chains
 * This facet is used to bridge tokens to the main chain of the portfolio
 */
contract BridgeFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    BridgeConfigStorage public immutable _bridgeConfigStorage;
    IERC20 public immutable _usdc;

    error NotApprovedBridge(address bridgeContract);
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address usdc) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _usdc = IERC20(usdc);
    }

    function bridge(address bridgeContract, bytes calldata data) external {
        require(_portfolioAccountConfig.isAuthorizedCaller(msg.sender));
        require(_bridgeConfigStorage.isApprovedBridge(bridgeContract), NotApprovedBridge(bridgeContract));
        _usdc.approve(address(bridgeContract),  _usdc.balanceOf(address(this)));
        (bool success, ) = bridgeContract.call(data);
        require(success);
    }
}

