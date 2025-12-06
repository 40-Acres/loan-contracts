// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/**
 * @title AccountFacetsDeploy
 * @dev Base contract for deploying and upgrading account facets
 */
contract AccountFacetsDeploy is Script {
    /**
     * @dev Get the FacetRegistry address from environment variable or PortfolioFactory
     * @return The FacetRegistry instance
     */
    function getFacetRegistry() internal view returns (FacetRegistry) {
        address facetRegistryAddr = vm.envOr("FACET_REGISTRY", address(0));
        if (facetRegistryAddr != address(0)) {
            return FacetRegistry(facetRegistryAddr);
        }
        // Fallback: get from PortfolioFactory
        address portfolioFactoryAddr = vm.envOr("PORTFOLIO_FACTORY", address(0));
        require(portfolioFactoryAddr != address(0), "FACET_REGISTRY or PORTFOLIO_FACTORY must be set");
        PortfolioFactory portfolioFactory = PortfolioFactory(portfolioFactoryAddr);
        return portfolioFactory.facetRegistry();
    }
    /**
     * @dev Register a facet in the FacetRegistry
     * @param portfolioFactory The PortfolioFactory address
     * @param facetAddress The address of the facet
     * @param selectors The function selectors
     * @param name The name of the facet
     */
    function registerFacet(
        address portfolioFactory,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name,
        bool impersonate
    ) internal {
        PortfolioFactory factory = PortfolioFactory(portfolioFactory);
        FacetRegistry registry = factory.facetRegistry();
        
        // Get the owner of the FacetRegistry
        address owner = IOwnable(address(registry)).owner();
        
        // Check if facet already exists
        address oldFacet = registry.getFacetForSelector(selectors[0]);
        
        // Impersonate the owner to register/replace the facet
        if (impersonate) {
            vm.startPrank(owner);
        }
        if (oldFacet == address(0)) {
            registry.registerFacet(facetAddress, selectors, name);
        } else {
            registry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
        if (impersonate) {
            vm.stopPrank();
        }
    }


    /**
     * @dev Get selectors for a facet (must be implemented by child contracts or passed as parameter)
     * This is a placeholder - selectors should be provided when calling register/upgrade functions
     */
    function getSelectorsForFacet() internal virtual pure returns (bytes4[] memory) {
        // This should be overridden or selectors should be passed directly
        revert("Selectors must be provided explicitly");
    }
}

