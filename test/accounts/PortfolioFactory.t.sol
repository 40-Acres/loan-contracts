// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";

contract PortfolioFactoryTest is Test {
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioManager public portfolioManager;
    
    address public constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address[] public users;
    address[] public portfolios;

    function setUp() public {
        // Deploy FacetRegistry
        facetRegistry = new FacetRegistry(FORTY_ACRES_DEPLOYER);
        
        // Deploy PortfolioManager
        portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        
        // Deploy PortfolioFactory through PortfolioManager
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory, FacetRegistry registry) = portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("test"))));
        portfolioFactory = factory;
        facetRegistry = registry;
        vm.stopPrank();
        
        // Create multiple users and portfolios for testing
        users = new address[](10);
        portfolios = new address[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(1000 + i));
            portfolios[i] = portfolioFactory.createAccount(users[i]);
        }
    }
}

