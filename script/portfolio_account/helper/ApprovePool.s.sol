// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title ApprovePool
 * @dev Helper script to approve or disapprove pools in VotingConfig
 * 
 * VotingConfig address can be loaded from addresses.json or passed as a parameter/environment variable.
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run(address,bool)" <POOL_ADDRESS> <APPROVED> --rpc-url $RPC_URL --broadcast
 * 2. From addresses.json + env vars: POOL=0x123... APPROVED=true forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run(address,bool)" 0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0 true --rpc-url $BASE_RPC_URL --broadcast
 */
contract ApprovePool is Script {
    using stdJson for string;

    /**
     * @dev Load PortfolioManager address from addresses.json or environment variable
     */
    function loadPortfolioManager() internal view returns (PortfolioManager) {
        address portfolioManagerAddr;
        
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            portfolioManagerAddr = addressesJson.readAddress(".portfoliomanager");
        } catch {
            // Fall back to environment variable
            portfolioManagerAddr = vm.envAddress("PORTFOLIO_MANAGER");
        }
        
        require(portfolioManagerAddr != address(0), "PortfolioManager address not found. Set PORTFOLIO_MANAGER env var or allow file access with --fs addresses");
        return PortfolioManager(portfolioManagerAddr);
    }

    /**
     * @dev Get PortfolioFactory from PortfolioManager
     * @notice Set FACTORY_SALT env var to override (e.g., "aerodrome-usdc-dynamic-fees"). Defaults to "aerodrome-usdc"
     */
    function getAerodromeFactory(PortfolioManager portfolioManager) internal view returns (PortfolioFactory) {
        string memory factorySalt = vm.envOr("FACTORY_SALT", string("aerodrome-usdc"));
        bytes32 salt = keccak256(abi.encodePacked(factorySalt));
        address factoryAddress = portfolioManager.factoryBySalt(salt);
        require(factoryAddress != address(0), string.concat("Factory not found for salt: ", factorySalt));
        return PortfolioFactory(factoryAddress);
    }

    /**
     * @dev Load PortfolioAccountConfig address from addresses.json or environment variable
     */
    function loadPortfolioAccountConfig() internal view returns (PortfolioAccountConfig) {
        address configAddr;
        
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            if (addressesJson.keyExists(".portfolioaccountconfig")) {
                configAddr = addressesJson.readAddress(".portfolioaccountconfig");
            } else if (addressesJson.keyExists(".portfolioAccountConfig")) {
                configAddr = addressesJson.readAddress(".portfolioAccountConfig");
            }
        } catch {
            // File read failed, will fall back to env vars
        }
        
        // Fall back to environment variable
        if (configAddr == address(0)) {
            try vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG") returns (address envAddr) {
                configAddr = envAddr;
            } catch {
                // Try alternative env var name
                configAddr = vm.envAddress("PORTFOLIOACCOUNTCONFIG");
            }
        }
        
        require(configAddr != address(0), "PortfolioAccountConfig address not found. Set PORTFOLIO_ACCOUNT_CONFIG env var or allow file access with --fs addresses");
        return PortfolioAccountConfig(configAddr);
    }

    /**
     * @dev Approve or disapprove a pool in VotingConfig
     * @param poolAddress The address of the pool to approve or disapprove
     * @param approved Whether the pool should be approved (true) or disapproved (false)
     */
    function approvePool(address poolAddress, bool approved) internal {
        require(poolAddress != address(0), "Pool address cannot be zero");
        
        VotingConfig votingConfig = VotingConfig(0xdebEE5c3DFa953DBb1a48819dfF3cC9c12226E0C);
        console.log("VotingConfig address:", address(votingConfig));
        
        // Check current approval status
        bool currentStatus = votingConfig.isApprovedPool(poolAddress);
        console.log("Current approval status:", currentStatus);
        
        if (currentStatus == approved) {
            console.log("Pool already has the desired approval status");
            console.log("Pool:", poolAddress);
            console.log("Approved:", approved);
            return;
        }
        
        // Approve or disapprove the pool
        console.log("Setting pool approval status...");
        votingConfig.setApprovedPool(poolAddress, approved);
        
        console.log("Pool approval status updated!");
        console.log("Pool:", poolAddress);
        console.log("Approved:", approved);
    }

    /**
     * @dev Main run function for forge script execution
     * @param poolAddress The address of the pool to approve or disapprove
     * @param approved Whether the pool should be approved (true) or disapproved (false)
     */
    function run(address poolAddress, bool approved) external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        approvePool(poolAddress, approved);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * 
     * Environment variables:
     * - POOL: The pool address to approve/disapprove (required)
     * - APPROVED: "true" or "false" as string, or "1"/"0" (required)
     * - FORTY_ACRES_DEPLOYER: Private key for FORTY_ACRES_DEPLOYER (required)
     * 
     * Usage: 
     * POOL=0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0 APPROVED=true forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
     */
    function run() external {
        address poolAddress = vm.envAddress("POOL");
        string memory approvedStr = vm.envString("APPROVED");
        
        // Parse approved string to bool
        bool approved;
        bytes memory approvedBytes = bytes(approvedStr);
        if (approvedBytes.length == 1 && approvedBytes[0] == '1') {
            approved = true;
        } else if (keccak256(approvedBytes) == keccak256(bytes("true"))) {
            approved = true;
        } else if (approvedBytes.length == 1 && approvedBytes[0] == '0') {
            approved = false;
        } else if (keccak256(approvedBytes) == keccak256(bytes("false"))) {
            approved = false;
        } else {
            revert("APPROVED must be 'true', 'false', '1', or '0'");
        }
        
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        approvePool(poolAddress, approved);
        vm.stopBroadcast();
    }
}

// Example usage:
// POOL=0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0 APPROVED=true forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run()" --rpc-url $BASE_RPC_URL --broadcast

