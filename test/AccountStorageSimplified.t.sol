// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/accounts/PortfolioFactory.sol";
import "../src/storage/AssetStorage.sol";
import "../src/accounts/FacetRegistry.sol";

contract AccountStorageSimplifiedTest is Test {
    PortfolioFactory public portfolioFactory;
    address public owner = address(0x1);
    address public factory = address(0x2);
    address public user = address(0x3);
    address public account = address(0x4);

    function setUp() public {
        vm.prank(owner);
        AssetStorage assetStorage = new AssetStorage();
        FacetRegistry facetRegistry = new FacetRegistry();
        portfolioFactory = new PortfolioFactory(address(assetStorage), address(facetRegistry));
        
        // Factory doesn't need authorization
    }

    function testCreateAccount() public {
        // Test account creation
        vm.prank(factory);
        portfolioFactory.createAccount(user);
        
        // Check account exists
        assertTrue(portfolioFactory.isUserAccount(account));
        assertEq(portfolioFactory.getAccountOwner(account), user);
        assertEq(portfolioFactory.getUserAccount(user), account);
    }

    function testAccountAlreadyExists() public {
        // Create first account
        vm.prank(factory);
        portfolioFactory.createAccount(user);
        
        // Try to create duplicate
        vm.prank(factory);
        vm.expectRevert();
        portfolioFactory.createAccount(user);
    }

    function testOnlyAuthorizedFactory() public {
        // Try to create account without authorization
        vm.prank(user);
        vm.expectRevert();
        portfolioFactory.createAccount(user);
    }

    function testAccountDoesNotExist() public {
        // Try to get owner of non-existent account
        vm.expectRevert();
        portfolioFactory.getAccountOwner(account);
    }

    function testisUserAccount() public {
        // Account doesn't exist initially
        assertFalse(portfolioFactory.isUserAccount(account));
        
        // Create account
        vm.prank(factory);
        portfolioFactory.createAccount(user);
        
        // Account now exists
        assertTrue(portfolioFactory.isUserAccount(account));
    }
}
