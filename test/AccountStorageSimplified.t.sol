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
        
        // Authorize the factory address
        portfolioFactory.authorizeCaller(factory);
    }

    function testCreateAccount() public {
        // Test account creation
        vm.prank(factory);
        address createdAccount = portfolioFactory.createAccount(user);
        
        // Check account exists
        assertTrue(portfolioFactory.isUserAccount(createdAccount));
        assertEq(portfolioFactory.getAccountOwner(createdAccount), user);
        assertEq(portfolioFactory.getUserAccount(user), createdAccount);
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
        address createdAccount = portfolioFactory.createAccount(user);
        
        // Account now exists
        assertTrue(portfolioFactory.isUserAccount(createdAccount));
    }
}
