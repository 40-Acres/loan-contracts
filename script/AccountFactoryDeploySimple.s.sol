// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {Loan} from "../src/LoanV2.sol";

/**
 * @title PortfolioFactoryDeploySimple
 * @dev Simple deployment script for quick testing
 */
contract PortfolioFactoryDeploySimple is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying Account Factory System...");
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy PortfolioFactory
        FacetRegistry facetRegistry = new FacetRegistry();
        PortfolioFactory factory = new PortfolioFactory(address(facetRegistry));
        console.log("PortfolioFactory:", address(factory));
        
        // Deploy a simple loan contract for testing
        TestLoanContract loanContract = new TestLoanContract();
        console.log("Test Loan Contract:", address(loanContract));
        
        
        vm.stopBroadcast();
        
        // Test account creation
        testAccountCreation(address(factory), deployer);
    }
    
    function testAccountCreation(address factory, address user) internal {
        console.log("\n=== Testing Account Creation ===");
        
        // Create account
        address account = PortfolioFactory(factory).createAccount(user);
        console.log("Account created:", account);
        
        // Verify account
        require(PortfolioFactory(factory).isAccount(account), "Account not found");
        require(PortfolioFactory(factory).getAccount(user) == account, "Account mismatch");
        
        console.log("Account creation successful!");
    }
}

/**
 * @title TestLoanContract
 * @dev Simple test loan contract for testing
 */
contract TestLoanContract {
    string public constant VERSION = "1.0.0";
    
    function getVersion() external pure returns (string memory) {
        return VERSION;
    }
    
    function test() external pure returns (string memory) {
        return "Test loan contract working!";
    }
    
    function requestLoan(uint256 tokenId, uint256 amount) external pure returns (bool) {
        // Simple test function
        return true;
    }
}

