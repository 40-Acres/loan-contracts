// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./FortyAcresPortfolioAccount.sol";
import "./FacetRegistry.sol";
import "./PortfolioManager.sol";
import {CollateralStorage} from "../storage/CollateralStorage.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
/**
 * @title PortfolioFactory
 * @dev Dynamic factory contract that deploys diamond-based FortyAcresPortfolioAccount contracts
 */
contract PortfolioFactory {
    FacetRegistry public immutable facetRegistry;
    PortfolioManager public portfolioManager;

    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => address) public portfolios; // owner => portfolio
    mapping(address => address) public owners; // portfolio => owner
    EnumerableSet.AddressSet private portfolioAddresses;

    event AccountCreated(address indexed user, address indexed portfolio);

    
    error AccountAlreadyExists(address user);
    error AccountCreationFailed(address user);
    
    /**
     * @dev Constructor - uses centralized facet registry
     * @param _facetRegistry The centralized facet registry address
     */
    constructor(
        address _facetRegistry
    ) {
        require(_facetRegistry != address(0));
        facetRegistry = FacetRegistry(_facetRegistry);
        portfolioManager = PortfolioManager(msg.sender);
    }

    /**
     * @dev Creates a new FortyAcresPortfolioAccount using centralized facet registry
     * @param portfolio The address for which to create an portfolio
     * @return portfolio The address of the deployed FortyAcresPortfolioAccount contract
     */
    function createAccount(address user) external returns (address portfolio) {
        require(portfolios[user] == address(0), AccountAlreadyExists(user));
        // Generate salt from portfolio address
        bytes32 salt = keccak256(abi.encodePacked(user));
        
        // Encode constructor parameters for FortyAcresPortfolioAccount
        bytes memory bytecode = abi.encodePacked(
            type(FortyAcresPortfolioAccount).creationCode,
            abi.encode(address(facetRegistry))
        );
        
        assembly {
            portfolio := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        if (portfolio == address(0)) {
            revert AccountCreationFailed(user);
        }
        
        portfolios[user] = portfolio;
        owners[portfolio] = user;
        portfolioAddresses.add(portfolio);
        
        // Register portfolio with PortfolioManager
        portfolioManager.registerPortfolio(portfolio, user);
        
        emit AccountCreated(user, portfolio);
        
        return portfolio;
    }
    
    /**
     * @dev Get facet registry version
     * @return Current registry version
     */
    function getRegistryVersion() external view returns (uint256) {
        return facetRegistry.getVersion();
    }

    function ownerOf(address portfolio) external view returns (address) {
        return owners[portfolio];
    }

    function portfolioOf(address owner) external view returns (address) {
        return portfolios[owner];
    }

    /**
     * @dev Checks if portfolio exists (check if owner exists)
     */
    function isPortfolio(address _portfolio) external view virtual returns (bool) {
        return owners[_portfolio] != address(0);
    }
    
    function getAllPortfolios() external view returns (address[] memory) {
        return portfolioAddresses.values();
    }
    
    function getPortfoliosLength() external view returns (uint256) {
        return portfolioAddresses.length();
    }

    function getPortfolio(uint256 index) external view returns (address) {
        return portfolioAddresses.at(index);
    }
}