// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./FortyAcresPortfolioAccount.sol";
import "./FacetRegistry.sol";
import {CollateralStorage} from "../storage/CollateralStorage.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
/**
 * @title PortfolioFactory
 * @dev Dynamic factory contract that deploys diamond-based FortyAcresPortfolioAccount contracts
 */
contract PortfolioFactory {
    FacetRegistry public immutable facetRegistry;

    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => address) public portfolios; // user => portfolio
    mapping(address => address) public portfolioOwners; // portfolio => owner
    mapping(address => bool) public portfolioExists;
    EnumerableSet.AddressSet private portfolioAddresses;

    event AccountCreated(address indexed portfolio, address indexed owner, address indexed portfolioContract);

    
    error AccountAlreadyExists(address portfolio);
    error AccountCreationFailed(address portfolio);
    
    /**
     * @dev Constructor - uses centralized facet registry
     * @param _facetRegistry The centralized facet registry address
     */
    constructor(
        address _facetRegistry
    ) {
        require(_facetRegistry != address(0));
        facetRegistry = FacetRegistry(_facetRegistry);
    }

    /**
     * @dev Creates a new FortyAcresPortfolioAccount using centralized facet registry
     * @param portfolio The address for which to create an portfolio
     * @return portfolioContract The address of the deployed FortyAcresPortfolioAccount contract
     */
    function createAccount(address portfolio) external returns (address portfolioContract) {
        // Check if portfolio already exists
        if (portfolioExists[portfolio]) {
            revert AccountAlreadyExists(portfolio);
        }
        
        // Generate salt from portfolio address
        bytes32 salt = keccak256(abi.encodePacked(portfolio));
        
        // Encode constructor parameters for FortyAcresPortfolioAccount
        bytes memory bytecode = abi.encodePacked(
            type(FortyAcresPortfolioAccount).creationCode,
            abi.encode(address(facetRegistry))
        );
        
        assembly {
            portfolioContract := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        
        if (portfolioContract == address(0)) {
            revert AccountCreationFailed(portfolio);
        }
        
        portfolios[portfolio] = portfolioContract;
        portfolioOwners[portfolioContract] = portfolio;
        portfolioExists[portfolio] = true;
        portfolioAddresses.add(portfolioContract);
        
        
        emit AccountCreated(portfolio, portfolio, portfolioContract);
        
        return portfolioContract;
    }
    
    /**
     * @dev Get facet registry version
     * @return Current registry version
     */
    function getRegistryVersion() external view returns (uint256) {
        return facetRegistry.getVersion();
    }

    
    /**
     * @dev Get portfolio for a user
     * @param user The user address
     * @return The portfolio address
     */
    function getAccount(address user) external view returns (address) {
        return portfolios[user];
    }
    
    /**
     * @dev Check if portfolio exists
     * @param portfolio The portfolio address
     * @return True if portfolio exists
     */
    function isAccount(address portfolio) external view returns (bool) {
        return portfolioExists[portfolio];
    }
    
    /**
     * @dev Gets portfolio owner
     */
    function getAccountOwner(address _portfolio) external view returns (address) {
        address portfolioOwner = portfolioOwners[_portfolio];
        require(portfolioOwner != address(0));
        return portfolioOwner;
    }

    /**
     * @dev Gets the portfolio for a user
     */
    function getUserAccount(address _user) external view returns (address) {
        return portfolios[_user];
    }

    /**
     * @dev Checks if portfolio exists (check if owner exists)
     */
    function isUserAccount(address _portfolio) external view virtual returns (bool) {
        return portfolioOwners[_portfolio] != address(0);
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