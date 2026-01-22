// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
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
    ITokenMessenger public immutable _tokenMessenger;
    IERC20 public immutable _token;
    uint32 public immutable _destinationDomain;

    error NotApprovedBridge(address bridgeContract);
    
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address token, address tokenMessenger) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(tokenMessenger != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _token = IERC20(token);
        _destinationDomain = 2; // Optimism Mainnet https://developers.circle.com/cctp/cctp-supported-blockchains
        _tokenMessenger = ITokenMessenger(tokenMessenger);
    }

    function bridge(uint256 amount, uint256 maxFee) external  onlyAuthorizedCaller(_portfolioFactory) {
        uint32 minFinalityThreshold = 2000;
        _token.approve(address(_tokenMessenger), amount);
        _tokenMessenger.depositForBurn(
            amount,
            _destinationDomain, bytes32(uint256(uint160(address(this)))), 
            address(_token), 
            bytes32(uint256(uint160(address(0)))),
            maxFee, 
            minFinalityThreshold
        );
    }
}
