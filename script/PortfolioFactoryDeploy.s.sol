// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract PortfolioFactoryDeploy is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    
    function deployFacetRegistry(string memory platform) public returns (FacetRegistry) {
        bytes32 salt = keccak256(abi.encodePacked(platform, "FacetRegistry"));
        return new FacetRegistry{salt: salt}(DEPLOYER_ADDRESS);
    }
    
    function deployPortfolioFactory(string memory platform, address facetRegistry) public returns (PortfolioFactory) {
        bytes32 salt = keccak256(abi.encodePacked(platform));
        return new PortfolioFactory{salt: salt}(facetRegistry);
    }

    function _deploy(string memory platform) internal returns (FacetRegistry, PortfolioFactory) {
        address facetRegistryAddr = vm.envOr(string.concat("_FACET_REGISTRY"), address(0));
        FacetRegistry facetRegistry;
        if (facetRegistryAddr == address(0)) {
            facetRegistry = deployFacetRegistry(platform);
            facetRegistryAddr = address(facetRegistry);
        } else {
            facetRegistry = FacetRegistry(facetRegistryAddr);
        }
        return (facetRegistry, deployPortfolioFactory(platform, facetRegistryAddr));
    }
}

contract DeployPortfolioFactoryAerodrome is PortfolioFactoryDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        
        _deploy("aerodrome");
        
        vm.stopBroadcast();
    }
}

contract DeployPortfolioFactoryVelodrome is PortfolioFactoryDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        
        _deploy("velodrome");
        
        vm.stopBroadcast();
    }
}


// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 10 --rpc-url $OP_RPC_URL --etherscan-api-key $OPSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/PortfolioFactoryDeploy.s.sol:DeployPortfolioFactoryVelodrome  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
