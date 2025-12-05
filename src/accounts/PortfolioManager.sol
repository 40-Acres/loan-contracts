// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./PortfolioFactory.sol";
import "./FacetRegistry.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PortfolioManager
 * @dev Central manager for the portfolio system that deploys FacetRegistries and PortfolioFactories,
 * tracks all portfolio accounts, and provides cross-account multicall functionality.
 * Allows portfolio owners to execute calls across multiple portfolio accounts in a single transaction.
 */
contract PortfolioManager is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Registered factories
    EnumerableSet.AddressSet private factories;
    mapping(address => bool) public isRegisteredFactory;

    // Deployed FacetRegistries
    EnumerableSet.AddressSet private facetRegistries;
    mapping(address => bool) public isDeployedFacetRegistry;

    // Track portfolio accounts across all factories
    // portfolio => factory that created it
    mapping(address => address) public portfolioToFactory;
    // owner => all portfolio accounts across all factories
    mapping(address => EnumerableSet.AddressSet) private ownerPortfolios;

    // Authorized callers - global authorization across all portfolios
    mapping(address => bool) public authorizedCallers;

    // Struct for cross-account multicall
    struct PortfolioCall {
        address portfolio;  // The portfolio account to call
        bytes data;         // The calldata to send to the portfolio account
    }

    event FacetRegistryDeployed(address indexed facetRegistry, address indexed owner);
    event FactoryDeployed(address indexed factory, address indexed facetRegistry);
    event PortfolioRegistered(address indexed portfolio, address indexed factory, address indexed owner);
    event CrossAccountMulticall(address indexed owner, address[] portfolios);
    event AuthorizedCallerSet(address indexed caller, bool authorized);

    error FactoryNotRegistered(address factory);
    error PortfolioNotRegistered(address portfolio);
    error PortfolioAlreadyRegistered(address portfolio);
    error NotPortfolioOwner(address portfolio, address caller);
    error ArrayLengthMismatch();
    error CallFailed(address portfolio, bytes reason);
    error FactoryDeploymentFailed();
    error FacetRegistryDeploymentFailed();

    /**
     * @dev Constructor - sets the initial owner
     * @param initialOwner The address that will own this router
     */
    constructor(address initialOwner) Ownable(initialOwner) {}


    /**
     * @dev Deploy a new PortfolioFactory and automatically register it
     * Automatically deploys a FacetRegistry for the factory
     * Only the router owner can deploy factories
     * @param salt Optional salt for CREATE2 deployment (0 for non-deterministic)
     * @return factory The address of the deployed PortfolioFactory
     * @return facetRegistry The address of the deployed FacetRegistry
     */
    function deployFactory(
        bytes32 salt
    ) external onlyOwner returns (PortfolioFactory, FacetRegistry) {
        // First, deploy a FacetRegistry for this factory
        address registryOwner = owner();
        address facetRegistry;
        address factory;
        
        // Encode constructor parameters for FacetRegistry
        bytes memory registryBytecode = abi.encodePacked(
            type(FacetRegistry).creationCode,
            abi.encode(registryOwner)
        );
        
        // Use a derived salt for the FacetRegistry to ensure uniqueness
        bytes32 registrySalt = keccak256(abi.encodePacked(salt, "facet-registry"));
        assembly {
            facetRegistry := create2(0, add(registryBytecode, 0x20), mload(registryBytecode), registrySalt)
        }
        
        if (facetRegistry == address(0)) {
            revert FacetRegistryDeploymentFailed();
        }
        
        // Track the deployed FacetRegistry
        facetRegistries.add(facetRegistry);
        isDeployedFacetRegistry[facetRegistry] = true;
        
        emit FacetRegistryDeployed(facetRegistry, registryOwner);
        
        // Now deploy the PortfolioFactory with the FacetRegistry
        bytes memory factoryBytecode = abi.encodePacked(
            type(PortfolioFactory).creationCode,
            abi.encode(facetRegistry)
        );
        
        assembly {
            factory := create2(0, add(factoryBytecode, 0x20), mload(factoryBytecode), salt)
        }
        
        if (factory == address(0)) {
            revert FactoryDeploymentFailed();
        }
        
        // Automatically register the factory
        factories.add(factory);
        isRegisteredFactory[factory] = true;
        
        emit FactoryDeployed(factory, facetRegistry);
        
        return (PortfolioFactory(factory), FacetRegistry(facetRegistry));
    }


    /**
     * @dev Register a portfolio account with the manager
     * Can only be called by a registered factory
     * @param portfolio The portfolio account address
     * @param owner The owner of the portfolio account
     */
    function registerPortfolio(address portfolio, address owner) external {
        // Verify caller is a registered factory
        if (!isRegisteredFactory[msg.sender]) {
            revert FactoryNotRegistered(msg.sender);
        }
        
        // Verify portfolio is not already registered
        if (portfolioToFactory[portfolio] != address(0)) {
            revert PortfolioAlreadyRegistered(portfolio);
        }
        
        // Map portfolio to factory
        portfolioToFactory[portfolio] = msg.sender;
        
        // Add portfolio to owner's set
        ownerPortfolios[owner].add(portfolio);
        
        // Emit event
        emit PortfolioRegistered(portfolio, msg.sender, owner);
    }

    /**
     * @dev Execute multiple calls across different portfolio accounts
     * Verifies that msg.sender owns all portfolio accounts before executing
     * Reverts if any call fails
     * @param calldatas Array of calldatas to execute
     * @param portfolios Array of portfolio addresses to execute the calldatas on
     * @return results Array of return data from each call
     */
    function multicall(
        bytes[] calldata calldatas,
        address[] calldata portfolios
    ) external returns (bytes[] memory results) {
        require(calldatas.length > 0, "PortfolioManager: No calldatas provided");
        require(portfolios.length > 0, "PortfolioManager: No portfolios provided");
        require(calldatas.length == portfolios.length, "PortfolioManager: Calldatas and portfolios length mismatch");
        
        results = new bytes[](calldatas.length);
        
        // verify ownership of all portfolios
        for (uint256 i = 0; i < calldatas.length; i++) {
            address portfolio = portfolios[i];
            
            // Verify portfolio is registered
            address factory = portfolioToFactory[portfolio];
            require(factory != address(0), PortfolioNotRegistered(portfolio));
            
            // Verify ownership
            PortfolioFactory portfolioFactory = PortfolioFactory(factory);
            address owner = portfolioFactory.ownerOf(portfolio);
            require(owner == msg.sender, NotPortfolioOwner(portfolio, msg.sender));
        }
        
        // execute all calls
        for (uint256 i = 0; i < calldatas.length; i++) {
            (bool success, bytes memory result) = portfolios[i].call(calldatas[i]);
            
            if (success) {
                results[i] = result;
            } else {
                // Try to get revert reason
                if (result.length > 0) {
                    assembly {
                        let returndata_size := mload(result)
                        revert(add(32, result), returndata_size)
                    }
                } else {
                    revert CallFailed(portfolios[i], result);
                }
            }
        }
        
        emit CrossAccountMulticall(msg.sender, portfolios);
        
        return results;
    }

    /**
     * @dev Get all registered factories
     * @return Array of factory addresses
     */
    function getAllFactories() external view returns (address[] memory) {
        return factories.values();
    }

    /**
     * @dev Get number of registered factories
     * @return Number of factories
     */
    function getFactoriesLength() external view returns (uint256) {
        return factories.length();
    }

    /**
     * @dev Get factory at index
     * @param index The index
     * @return Factory address
     */
    function getFactory(uint256 index) external view returns (address) {
        return factories.at(index);
    }

    /**
     * @dev Get all deployed FacetRegistries
     * @return Array of FacetRegistry addresses
     */
    function getAllFacetRegistries() external view returns (address[] memory) {
        return facetRegistries.values();
    }

    /**
     * @dev Get number of deployed FacetRegistries
     * @return Number of FacetRegistries
     */
    function getFacetRegistriesLength() external view returns (uint256) {
        return facetRegistries.length();
    }

    /**
     * @dev Get FacetRegistry at index
     * @param index The index
     * @return FacetRegistry address
     */
    function getFacetRegistry(uint256 index) external view returns (address) {
        return facetRegistries.at(index);
    }

    /**
     * @dev Get all portfolio accounts for an owner across all factories
     * @param owner The owner address
     * @return Array of portfolio account addresses
     */
    function getPortfoliosForOwner(address owner) external view returns (address[] memory) {
        return ownerPortfolios[owner].values();
    }

    /**
     * @dev Get number of portfolio accounts for an owner
     * @param owner The owner address
     * @return Number of portfolio accounts
     */
    function getPortfoliosCountForOwner(address owner) external view returns (uint256) {
        return ownerPortfolios[owner].length();
    }

    /**
     * @dev Get portfolio account at index for an owner
     * @param owner The owner address
     * @param index The index
     * @return Portfolio account address
     */
    function getPortfolioForOwner(address owner, uint256 index) external view returns (address) {
        return ownerPortfolios[owner].at(index);
    }

    /**
     * @dev Get the factory that created a portfolio account
     * @param portfolio The portfolio account address
     * @return Factory address
     */
    function getFactoryForPortfolio(address portfolio) external view returns (address) {
        return portfolioToFactory[portfolio];
    }

    /**
     * @dev Check if a portfolio account is registered
     * @param portfolio The portfolio account address
     * @return True if registered
     */
    function isPortfolioRegistered(address portfolio) external view returns (bool) {
        return portfolioToFactory[portfolio] != address(0);
    }

    /**
     * @dev Set an authorized caller (only owner can set)
     * @param caller The address to authorize/unauthorize
     * @param authorized Whether the caller is authorized
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }

    /**
     * @dev Check if a caller is owner of a portfolio
     * @param portfolio The portfolio account address
     * @return True if caller is owner of portfolio
     */
    function isPortfolioOwner(address portfolio) external view returns (bool) {
        return PortfolioFactory(portfolioToFactory[portfolio]).ownerOf(portfolio) == msg.sender;
    }

    function isAuthorizedCaller(address caller) external view returns (bool) {
        return authorizedCallers[caller];
    }
}

