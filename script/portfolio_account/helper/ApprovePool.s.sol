// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
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
     * @dev Load PortfolioFactoryConfig address from addresses.json or environment variable
     */
    function loadPortfolioFactoryConfig() internal view returns (PortfolioFactoryConfig) {
        address configAddr;
        
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            if (addressesJson.keyExists(".portfolioaccountconfig")) {
                configAddr = addressesJson.readAddress(".portfolioaccountconfig");
            } else if (addressesJson.keyExists(".portfolioFactoryConfig")) {
                configAddr = addressesJson.readAddress(".portfolioFactoryConfig");
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
        
        require(configAddr != address(0), "PortfolioFactoryConfig address not found. Set PORTFOLIO_ACCOUNT_CONFIG env var or allow file access with --fs addresses");
        return PortfolioFactoryConfig(configAddr);
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
     * @dev Batch approve multiple pools
     *
     * Usage:
     * forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "batchApprove()" --rpc-url $BASE_RPC_URL --broadcast
     */
    function batchApprove() external {
        address[] memory pools = new address[](1);
        pools[0] = 0x8845126640B36df1D24bf3dF9B2903fD4c730FE6;

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        for (uint256 i = 0; i < pools.length; i++) {
            approvePool(pools[i], true);
        }
        vm.stopBroadcast();
    }

    /**
     * @dev Batch approve pools on NOVA Voting Config
     *
     * Usage:
     * forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "batchApproveNova()" --rpc-url $ETH_RPC_URL --broadcast
     */
    function batchApproveNova() external {
        VotingConfig novaVotingConfig = VotingConfig(0x8a66bC8F873C541043347fC9D712F8d4a0C6730E);

        address[] memory pools = new address[](10);
        pools[0] = 0xDE758DB54c1b4a87B06b34B30EF0a710Dc35388F;
        pools[1] = 0xA65637601a767e247b6e24613AB40f78AD559E71;
        pools[2] = 0x40Ab23e8f571bf19A85605b9638E50Cc25a256EC;
        pools[3] = 0xe2CD94c812AEd174B2E09750fF146F45d845d668;
        pools[4] = 0x55347B4AB701Ab54eE394f20020175Bb385CA725;
        pools[5] = 0xE9930eA69Fcd58e73261BE38e1C5C13C290b391B;
        pools[6] = 0xA429A6C5B5EF08391D96e5F1d386e2E2909B7604;
        pools[7] = 0x8a02454CA2565d25f65531111B6dCaC1E5f1d671;
        pools[8] = 0xEd1050E2fE96f7327dc659613C79e41458E9Cf05;
        pools[9] = 0x059Ff12B18E628af46c5aB83e0318A6F22c6Ea4e;

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        novaVotingConfig.setApprovedPools(pools, true);
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
// POOL=$POOL APPROVED=true forge script script/portfolio_account/helper/ApprovePool.s.sol:ApprovePool --sig "run()" --rpc-url $BASE_RPC_URL --broadcast