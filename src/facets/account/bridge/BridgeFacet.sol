// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {BridgeConfigStorage} from "./BridgeConfigStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ITokenMessenger} from "../../../interfaces/ITokenMessenger.sol";

/**
 * @title BridgeFacet
 * @dev Facet that bridges tokens between chains
 * This facet is used to bridge tokens to the main chain of the portfolio
 */
contract BridgeFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    ITokenMessenger public immutable _tokenMessenger = ITokenMessenger(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
    IERC20 public immutable _usdc;
    uint32 public immutable _destinationDomain;

    error NotApprovedBridge(address bridgeContract);
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address usdc) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _usdc = IERC20(usdc);
        _destinationDomain = 2; // Optimism Mainnet https://developers.circle.com/cctp/cctp-supported-blockchains
    }

    function bridge() external  {
        uint32 minFinalityThreshold = 2000;
        uint256 maxFee = _usdc.balanceOf(address(this)) / 10000;
        _tokenMessenger.depositForBurn(
            _usdc.balanceOf(address(this)), 
            _destinationDomain, bytes32(uint256(uint160(address(this)))), 
            address(_usdc), 
            bytes32(uint256(uint160(address(this)))), 
            maxFee, 
            minFinalityThreshold
        );
    }
}
