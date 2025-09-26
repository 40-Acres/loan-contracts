// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {Loan} from "../src/LoanV2.sol";

/**
 * @title PortfolioFactoryDeploy
 * @dev Deployment script for the Account Factory system
 * Deploys all components needed for the diamond-based account system
 */
contract PortfolioFactoryDeploy is Script {
    // Deployment addresses
    address public unifiedStorage;
    address public loanContract;
    address public portfolioFactory;
    
    // Events for tracking deployment
    event UnifiedStorageDeployed(address indexed storageContract);
    event LoanContractDeployed(address indexed loan);
    event PortfolioFactoryDeployed(address indexed factory);
    event ApprovedAddressesConfigured();

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying Account Factory System...");
        console.log("Deployer:", deployer);
        console.log("Deployer Balance:", deployer.balance / 1e18, "ETH");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy components in order
        deployLoanContract();
        deployPortfolioFactory();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        logDeploymentSummary();
    }
    /**
     * @dev Deploy the Loan Contract
     */
    function deployLoanContract() internal {
        console.log("\n=== Deploying Loan Contract ===");
        
        // For testing, deploy a simple loan contract
        loanContract = address(new TestLoanContract());
        
        console.log("Loan Contract deployed at:", loanContract);
        emit LoanContractDeployed(loanContract);
    }

    /**
     * @dev Deploy the Account Factory
     */
    function deployPortfolioFactory() internal {
        console.log("\n=== Deploying Account Factory ===");
        
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();
        
        portfolioFactory = address(new PortfolioFactory(
            address(facetRegistry)
        ));
        
        // Authorize the factory in the unified storage
        // PortfolioFactory doesn't need authorization from storage
        
        console.log("Account Factory deployed at:", portfolioFactory);
        emit PortfolioFactoryDeployed(portfolioFactory);
    }

    /**
     * @dev Log deployment summary
     */
    function logDeploymentSummary() internal view {
        console.log("\n============================================================");
        console.log("ACCOUNT FACTORY DEPLOYMENT SUMMARY");
        console.log("============================================================");
        console.log("Unified Storage:", unifiedStorage);
        console.log("Loan Contract:", loanContract);
        console.log("Account Factory:", portfolioFactory);
        console.log("============================================================");
        
        // Verify deployment
        verifyDeployment();
    }

    /**
     * @dev Verify that the deployment was successful
     */
    function verifyDeployment() internal view {
        console.log("\n=== Verifying Deployment ===");
        
        // Check unified storage
        require(unifiedStorage != address(0), "Unified Storage not deployed");
        
        // Check loan contract
        require(loanContract != address(0), "Loan Contract not deployed");
        
        // Check account factory
        require(portfolioFactory != address(0), "Account Factory not deployed");
        // Verify factory was deployed
        require(portfolioFactory != address(0), "Factory not deployed");
        
        // Check approved addresses
        
        console.log("All deployments verified successfully!");
    }

    /**
     * @dev Test account creation (for verification)
     */
    function testAccountCreation() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("\n=== Testing Account Creation ===");
        
        // Create a test account
        address testAccount = PortfolioFactory(portfolioFactory).createAccount(deployer);
        console.log("Test account created at:", testAccount);
        
        // Verify account properties
        require(PortfolioFactory(portfolioFactory).isAccount(testAccount), "Account not registered");
        require(PortfolioFactory(portfolioFactory).getAccount(deployer) == testAccount, "Account address mismatch");
        
        // Test account functions
        (bool success, bytes memory data) = testAccount.staticcall(
            abi.encodeWithSignature("owner()")
        );
        require(success, "Failed to call owner()");
        address owner = abi.decode(data, (address));
        require(owner == deployer, "Account owner mismatch");
        
        console.log("Account creation test passed!");
        
        vm.stopBroadcast();
    }


}

/**
 * @title TestLoanContract
 * @dev Simple test loan contract for demonstration
 */
contract TestLoanContract {
    string public constant VERSION = "1.0.0";
    
    function getVersion() external pure returns (string memory) {
        return VERSION;
    }
    
    function testFunction() external pure returns (string memory) {
        return "Test loan contract working!";
    }
    
    function requestLoan(uint256 tokenId, uint256 amount) external pure returns (bool) {
        // Simple test function
        return true;
    }
}

