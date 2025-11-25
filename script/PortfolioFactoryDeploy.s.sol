// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract PortfolioFactoryDeploy is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    
    function deployFacetRegistry() public returns (FacetRegistry) {
        bytes32 salt = keccak256(abi.encodePacked("FacetRegistry"));
        return new FacetRegistry{salt: salt}();
    }
    
    function deployPortfolioFactory(string memory platform, address facetRegistry) public returns (PortfolioFactory) {
        bytes32 salt = keccak256(abi.encodePacked(platform));
        return new PortfolioFactory{salt: salt}(facetRegistry);
    }
}

contract DeployPortfolioFactoryAerodrome is PortfolioFactoryDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        
        address facetRegistry = vm.envOr("FACET_REGISTRY", address(0));
        if (facetRegistry == address(0)) {
            facetRegistry = address(deployFacetRegistry());
        }
        
        deployPortfolioFactory("aerodrome", facetRegistry);
        
        vm.stopBroadcast();
    }
}

contract DeployPortfolioFactoryVelodrome is PortfolioFactoryDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        
        address facetRegistry = vm.envOr("FACET_REGISTRY", address(0));
        if (facetRegistry == address(0)) {
            facetRegistry = address(deployFacetRegistry());
        }
        
        deployPortfolioFactory("velodrome", facetRegistry);
        
        vm.stopBroadcast();
    }
}
