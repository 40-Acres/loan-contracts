// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";
    
/**
 * @title BridgeFacet
 * @dev Facet that bridges tokens between chains
 * This facet is used to bridge tokens to the main chain of the portfolio
 */
contract BridgeFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    uint256 public immutable _mainChainId;

    
    constructor(address portfolioFactory, address accountConfigStorage, uint256 mainChainId) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _mainChainId = mainChainId;
    }

    function bridge(address token, uint256 amount) external {
        // TODO: Implement
    }
}

