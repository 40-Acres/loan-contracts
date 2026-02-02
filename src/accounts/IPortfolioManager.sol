// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "./PortfolioFactory.sol";
import {FacetRegistry} from "./FacetRegistry.sol";

interface IPortfolioManager {
    // Struct for cross-account multicall
    struct PortfolioCall {
        address portfolio;  // The portfolio account to call
        bytes data;         // The calldata to send to the portfolio account
    }

    // Events
    event FacetRegistryDeployed(address indexed facetRegistry, address indexed owner);
    event FactoryDeployed(address indexed factory, address indexed facetRegistry);
    event PortfolioRegistered(address indexed portfolio, address indexed factory, address indexed owner);
    event CrossAccountMulticall(address indexed owner, address[] portfolios);
    event AuthorizedCallerSet(address indexed caller, bool authorized);

    // Errors
    error FactoryNotRegistered(address factory);
    error PortfolioNotRegistered(address portfolio);
    error PortfolioAlreadyRegistered(address portfolio);
    error NotPortfolioOwner(address portfolio, address caller);
    error ArrayLengthMismatch();
    error CallFailed(address portfolio, bytes reason);
    error FactoryDeploymentFailed();
    error FacetRegistryDeploymentFailed();
    error InsufficientCollateral();

    // State getters
    function isRegisteredFactory(address factory) external view returns (bool);
    function isDeployedFacetRegistry(address facetRegistry) external view returns (bool);
    function portfolioToFactory(address portfolio) external view returns (address);
    function factoryBySalt(bytes32 salt) external view returns (address);
    function authorizedCallers(address caller) external view returns (bool);

    // Factory management
    function deployFactory(bytes32 salt) external returns (PortfolioFactory, FacetRegistry);

    // Portfolio registration
    function registerPortfolio(address portfolio, address owner) external;

    // Multicall
    function multicall(
        bytes[] calldata calldatas,
        address[] calldata portfolioFactories
    ) external returns (bytes[] memory results);

    // Factory queries
    function getAllFactories() external view returns (address[] memory);
    function getFactoriesLength() external view returns (uint256);
    function getFactory(uint256 index) external view returns (address);

    // FacetRegistry queries
    function getAllFacetRegistries() external view returns (address[] memory);
    function getFacetRegistriesLength() external view returns (uint256);
    function getFacetRegistry(uint256 index) external view returns (address);

    // Portfolio queries
    function getPortfoliosForOwner(address owner) external view returns (address[] memory);
    function getPortfoliosCountForOwner(address owner) external view returns (uint256);
    function getPortfolioForOwner(address owner, uint256 index) external view returns (address);
    function getFactoryForPortfolio(address portfolio) external view returns (address);
    function isPortfolioRegistered(address portfolio) external view returns (bool);

    // Authorization
    function setAuthorizedCaller(address caller, bool authorized) external;
    function isPortfolioOwner(address portfolio) external view returns (bool);
    function isAuthorizedCaller(address caller) external view returns (bool);

    // Ownable
    function owner() external view returns (address);
}
