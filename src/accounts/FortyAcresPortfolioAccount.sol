// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {FacetRegistry} from "./FacetRegistry.sol";

/**
 * @title FortyAcresPortfolioAccount
 * @dev Account contract that references centralized facets
 */
contract FortyAcresPortfolioAccount {
    FacetRegistry public immutable facetRegistry;
    
    event AccountCreated(address indexed portfolio, address indexed owner);
    
    constructor(address _facetRegistry) {
        require(_facetRegistry != address(0));
        
        facetRegistry = FacetRegistry(_facetRegistry);
        
        // Initialize diamond storage with msg.sender as owner
        LibDiamond.setContractOwner(msg.sender);
        
        emit AccountCreated(address(this), msg.sender);
    }

    /**
     * @dev Get facet for a function selector from centralized registry
     */
    function _getFacetForSelector(bytes4 selector) internal view returns (address) {
        return facetRegistry.getFacetForSelector(selector);
    }

    fallback() external payable {
        address facet = _getFacetForSelector(msg.sig);
        require(facet != address(0));
        
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}