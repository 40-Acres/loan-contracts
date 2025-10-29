// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/**
 * @title FacetRegistry
 * @dev Central registry for managing facets across all accounts
 * This allows all accounts to share the same facet configuration
 */
contract FacetRegistry is Ownable2Step {
    // Events
    event FacetAdded(address indexed facet, bytes4[] selectors);
    event FacetRemoved(address indexed facet);
    event FacetReplaced(address indexed oldFacet, address indexed newFacet);
    event RegistryUpdated(uint256 version);

    // Registry state
    uint256 public version;
    
    // Central facet storage
    mapping(address => bool) public registeredFacets;
    mapping(bytes4 => address) public selectorToFacet;
    address[] public allFacets;
    
    // Facet metadata
    mapping(address => bytes4[]) public facetSelectors;
    mapping(address => string) public facetNames;
    
    
    modifier onlyRegisteredFacet(address facet) {
        require(registeredFacets[facet], "FacetRegistry: Facet not registered");
        _;
    }

    constructor() Ownable(msg.sender) {
        version = 1;
    }

    /**
     * @dev Register a new facet
     * @param facet The facet address
     * @param selectors The function selectors this facet implements
     * @param name Human-readable name for the facet
     */
    function registerFacet(
        address facet,
        bytes4[] calldata selectors,
        string calldata name
    ) external onlyOwner {
        require(facet != address(0));
        require(!registeredFacets[facet]);
        require(selectors.length > 0);

        // Register facet
        registeredFacets[facet] = true;
        allFacets.push(facet);
        facetNames[facet] = name;
        
        // Map selectors to facet
        for (uint256 i = 0; i < selectors.length; i++) {
            require(selectorToFacet[selectors[i]] == address(0));
            selectorToFacet[selectors[i]] = facet;
        }
        
        facetSelectors[facet] = selectors;
        version++;
        
        emit FacetAdded(facet, selectors);
        emit RegistryUpdated(version);
    }

    /**
     * @dev Remove a facet
     * @param facet The facet address to remove
     */
    function removeFacet(address facet) external onlyOwner onlyRegisteredFacet(facet) {
        // Clear selector mappings
        bytes4[] memory selectors = facetSelectors[facet];
        for (uint256 i = 0; i < selectors.length; i++) {
            delete selectorToFacet[selectors[i]];
        }
        
        // Remove from registry
        registeredFacets[facet] = false;
        delete facetSelectors[facet];
        delete facetNames[facet];
        
        // Remove from allFacets array
        for (uint256 i = 0; i < allFacets.length; i++) {
            if (allFacets[i] == facet) {
                allFacets[i] = allFacets[allFacets.length - 1];
                allFacets.pop();
                break;
            }
        }
        
        version++;
        
        emit FacetRemoved(facet);
        emit RegistryUpdated(version);
    }

    /**
     * @dev Replace a facet with a new one
     * @param oldFacet The facet to replace
     * @param newFacet The new facet address
     * @param newSelectors The new facet's selectors
     * @param newName The new facet's name
     */
    function replaceFacet(
        address oldFacet,
        address newFacet,
        bytes4[] calldata newSelectors,
        string calldata newName
    ) external onlyOwner onlyRegisteredFacet(oldFacet) {
        require(newFacet != address(0));
        require(!registeredFacets[newFacet]);

        // Remove old facet (inline removal logic)
        _removeFacetInternal(oldFacet);
        
        // Register new facet
        registeredFacets[newFacet] = true;
        allFacets.push(newFacet);
        facetNames[newFacet] = newName;
        
        // Map new selectors
        for (uint256 i = 0; i < newSelectors.length; i++) {
            selectorToFacet[newSelectors[i]] = newFacet;
        }
        
        facetSelectors[newFacet] = newSelectors;
        version++;
        
        emit FacetReplaced(oldFacet, newFacet);
        emit RegistryUpdated(version);
    }

    /**
     * @dev Get all registered facets
     * @return Array of facet addresses
     */
    function getAllFacets() external view returns (address[] memory) {
        return allFacets;
    }

    /**
     * @dev Get facet for a selector
     * @param selector The function selector
     * @return The facet address
     */
    function getFacetForSelector(bytes4 selector) external view returns (address) {
        return selectorToFacet[selector];
    }

    /**
     * @dev Get selectors for a facet
     * @param facet The facet address
     * @return Array of selectors
     */
    function getSelectorsForFacet(address facet) external view returns (bytes4[] memory) {
        return facetSelectors[facet];
    }

    /**
     * @dev Get facet name
     * @param facet The facet address
     * @return The facet name
     */
    function getFacetName(address facet) external view returns (string memory) {
        return facetNames[facet];
    }

    /**
     * @dev Check if a facet is registered
     * @param facet The facet address
     * @return True if registered
     */
    function isFacetRegistered(address facet) external view returns (bool) {
        return registeredFacets[facet];
    }

    /**
     * @dev Get current registry version
     * @return The version number
     */
    function getVersion() external view returns (uint256) {
        return version;
    }

    /**
     * @dev Internal function to remove a facet
     * @param facet The facet address to remove
     */
    function _removeFacetInternal(address facet) internal {
        // Clear selector mappings
        bytes4[] memory selectors = facetSelectors[facet];
        for (uint256 i = 0; i < selectors.length; i++) {
            delete selectorToFacet[selectors[i]];
        }
        
        // Remove from registry
        registeredFacets[facet] = false;
        delete facetSelectors[facet];
        delete facetNames[facet];
        
        // Remove from allFacets array
        for (uint256 i = 0; i < allFacets.length; i++) {
            if (allFacets[i] == facet) {
                allFacets[i] = allFacets[allFacets.length - 1];
                allFacets.pop();
                break;
            }
        }
    }
}
