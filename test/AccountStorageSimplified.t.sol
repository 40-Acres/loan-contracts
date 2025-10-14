// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/accounts/PortfolioFactory.sol";
import "../src/accounts/FacetRegistry.sol";

contract AccountStorageSimplifiedTest is Test {
    PortfolioFactory public portfolioFactory;
    address public owner = address(0x1);
    address public factory = address(0x2);
    address public user = address(0x3);
    address public account = address(0x4);

    function setUp() public {
        vm.prank(owner);
        FacetRegistry facetRegistry = new FacetRegistry();
        portfolioFactory = new PortfolioFactory(address(facetRegistry));
        
        // Note: Current PortfolioFactory doesn't have authorization
        // Anyone can call createAccount
    }

    function testCreateAccount() public {
        // Test account creation
        vm.prank(factory);
        address createdAccount = portfolioFactory.createAccount(user);
        
        // Check account exists
        assertEq(portfolioFactory.ownerOf(createdAccount), user);
        assertEq(portfolioFactory.ownerOf(user), createdAccount);
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

    function testAnyoneCanCreateAccount() public {
        // Current PortfolioFactory allows anyone to create accounts
        vm.prank(user);
        address createdAccount = portfolioFactory.createAccount(user);
        
        // Verify account was created successfully
        assertEq(portfolioFactory.ownerOf(createdAccount), user);
    }

    function testAccountDoesNotExist() public {
        // Try to get owner of non-existent account
        vm.expectRevert();
        portfolioFactory.ownerOf(account);
    }

    function testisUserAccount() public {
        // Account doesn't exist initially
        assertFalse(portfolioFactory.ownerOf(account) == address(0));
        
        // Create account
        vm.prank(factory);
        address createdAccount = portfolioFactory.createAccount(user);
        
        // Account now exists
        assertTrue(portfolioFactory.ownerOf(createdAccount) != address(0));
    }
}
