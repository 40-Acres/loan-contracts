// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../../src/accounts/PortfolioFactory.sol";
import "../../src/accounts/FacetRegistry.sol";

contract GenerateVanityPortfolioFactory is Script {
    function run() external {
        console.log("Looking for PortfolioFactory address starting with 0x40...");
        
        // Use a deployer address that starts with 0x40
        address deployer = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
        
        vm.startPrank(deployer);
        // connect to base network
        uint256 fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        // Create a mock FacetRegistry for bytecode generation
        FacetRegistry mockFacetRegistry = new FacetRegistry{salt: keccak256(abi.encodePacked("40acres","FacetRegistry"))}(deployer);
        
        // Generate the actual PortfolioFactory bytecode
        bytes memory bytecode = abi.encodePacked(
            type(PortfolioFactory).creationCode,
            abi.encode(address(mockFacetRegistry))
        );
        
        bytes32 bytecodeHash = keccak256(bytecode);
        
        bytes32 salt;
        address predictedAddress;
        uint256 attempts = 0;
        uint256 maxAttempts = 500000000; // Increased limit for more specific patterns
        
        while (attempts < maxAttempts) {
            salt = keccak256(abi.encodePacked(block.timestamp, attempts, deployer));
            predictedAddress = computeCreate2AddressCustom(salt, bytecodeHash, deployer);
            
            uint160 expectedAddress = uint160(0x40ac2e);
            uint8 numberOfBits = 4 * 6; // 0x40a is 12 bits (3 hex digits)
            if (uint160(predictedAddress) >> (160 - numberOfBits) == expectedAddress) {
                console.log("Found vanity address!");
                console.log("Salt:", vm.toString(salt));
                console.log("Predicted address:", predictedAddress);
                console.log("Attempts needed:", attempts);
                break;
            }
            
            attempts++;
            
            // Reduce logging frequency to save memory
            if (attempts % 100000 == 0) {
                console.log("Attempts so far:", attempts);
            }
        }
        
        if (attempts >= maxAttempts) {
            console.log("Could not find address starting with 0x40 in", maxAttempts, "attempts");
            console.log("Try running the script again or increase maxAttempts");
        }
    }
    
    function computeCreate2AddressCustom(
        bytes32 salt,
        bytes32 bytecodeHash,
        address deployer
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            bytecodeHash
        )))));
    }
}
