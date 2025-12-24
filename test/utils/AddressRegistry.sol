// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, stdJson} from "forge-std/Test.sol";

/**
 * @title AddressRegistry
 * @dev Helper contract for reading deployed contract addresses from JSON files
 * Addresses are organized by platform/network in addresses/{platform}.json
 * 
 * Usage in tests:
 * ```
 * import {AddressRegistry} from "../utils/AddressRegistry.sol";
 * 
 * contract MyTest is Test {
 *     using AddressRegistry for string;
 *     
 *     function setUp() public {
 *         address facetRegistry = AddressRegistry.getAddress("aerodrome", "FacetRegistry");
 *         address bridgeFacet = AddressRegistry.getFacetAddress("aerodrome", "BridgeFacet");
 *     }
 * }
 * ```
 */
contract AddressRegistry is Test {
    using stdJson for string;

    /**
     * @dev Get the path to the addresses file for a network/platform combination
     * @param network The network name (e.g., "base", "optimism", "avalanche")
     * @param platform The platform name (e.g., "aerodrome", "velodrome")
     * @return The file path
     */
    function getAddressesPath(string memory network, string memory platform) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(root, "/addresses/", network, "/", platform, ".json");
    }
    
    /**
     * @dev Get the path to the addresses file (backwards compatibility)
     * @param platform The platform name (e.g., "aerodrome", "velodrome")
     * @return The file path
     */
    function getAddressesPath(string memory platform) internal view returns (string memory) {
        // Default to "base" network for backwards compatibility
        return getAddressesPath("base", platform);
    }

    /**
     * @dev Read a contract address from the addresses file
     * @param network The network name (e.g., "base", "optimism")
     * @param platform The platform name (e.g., "aerodrome", "velodrome")
     * @param contractName The name of the contract (e.g., "FacetRegistry", "PortfolioFactory")
     * @return The contract address
     */
    function getAddress(string memory network, string memory platform, string memory contractName) internal view returns (address) {
        string memory path = getAddressesPath(network, platform);
        string memory json = vm.readFile(path);
        string memory key = string.concat(".contracts.", contractName);
        return json.readAddress(key);
    }

    /**
     * @dev Read a contract address (backwards compatibility - defaults to "base" network)
     * @param platform The platform name
     * @param contractName The name of the contract
     * @return The contract address
     */
    function getAddress(string memory platform, string memory contractName) internal view returns (address) {
        return getAddress("base", platform, contractName);
    }

    /**
     * @dev Read a facet address from the addresses file
     * @param network The network name
     * @param platform The platform name
     * @param facetName The name of the facet (e.g., "BridgeFacet", "ClaimingFacet")
     * @return The facet address
     */
    function getFacetAddress(string memory network, string memory platform, string memory facetName) internal view returns (address) {
        string memory path = getAddressesPath(network, platform);
        string memory json = vm.readFile(path);
        string memory key = string.concat(".contracts.facets.", facetName);
        return json.readAddress(key);
    }

    /**
     * @dev Read a facet address (backwards compatibility - defaults to "base" network)
     * @param platform The platform name
     * @param facetName The name of the facet
     * @return The facet address
     */
    function getFacetAddress(string memory platform, string memory facetName) internal view returns (address) {
        return getFacetAddress("base", platform, facetName);
    }

    /**
     * @dev Read the chain ID from the addresses file
     * @param network The network name
     * @param platform The platform name
     * @return The chain ID
     */
    function getChainId(string memory network, string memory platform) internal view returns (uint256) {
        string memory path = getAddressesPath(network, platform);
        string memory json = vm.readFile(path);
        return json.readUint(".chainId");
    }

    /**
     * @dev Read the chain ID (backwards compatibility - defaults to "base" network)
     * @param platform The platform name
     * @return The chain ID
     */
    function getChainId(string memory platform) internal view returns (uint256) {
        return getChainId("base", platform);
    }

    /**
     * @dev Check if an addresses file exists
     * @param network The network name
     * @param platform The platform name
     * @return True if the file exists
     */
    function addressesFileExists(string memory network, string memory platform) internal view returns (bool) {
        string memory path = getAddressesPath(network, platform);
        try vm.readFile(path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev Check if an addresses file exists (backwards compatibility)
     * @param platform The platform name
     * @return True if the file exists
     */
    function addressesFileExists(string memory platform) internal view returns (bool) {
        return addressesFileExists("base", platform);
    }

    /**
     * @dev Get all contract addresses for a network/platform combination
     * @param network The network name
     * @param platform The platform name
     * @return facetRegistry The FacetRegistry address
     * @return portfolioFactory The PortfolioFactory address
     * @return portfolioAccountConfig The PortfolioAccountConfig address
     * @return accountConfigStorage The AccountConfigStorage address
     */
    function getCoreAddresses(string memory network, string memory platform)
        internal
        view
        returns (
            address facetRegistry,
            address portfolioFactory,
            address portfolioAccountConfig,
            address accountConfigStorage
        )
    {
        facetRegistry = getAddress(network, platform, "FacetRegistry");
        portfolioFactory = getAddress(network, platform, "PortfolioFactory");
        portfolioAccountConfig = getAddress(network, platform, "PortfolioAccountConfig");
        accountConfigStorage = getAddress(network, platform, "AccountConfigStorage");
    }

    /**
     * @dev Get all contract addresses (backwards compatibility - defaults to "base" network)
     * @param platform The platform name
     * @return facetRegistry The FacetRegistry address
     * @return portfolioFactory The PortfolioFactory address
     * @return portfolioAccountConfig The PortfolioAccountConfig address
     * @return accountConfigStorage The AccountConfigStorage address
     */
    function getCoreAddresses(string memory platform)
        internal
        view
        returns (
            address facetRegistry,
            address portfolioFactory,
            address portfolioAccountConfig,
            address accountConfigStorage
        )
    {
        return getCoreAddresses("base", platform);
    }
}

