// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title PortfolioHelperUtils
 * @dev Utility library for portfolio helper scripts to reduce code duplication
 */
library PortfolioHelperUtils {
    using stdJson for string;

    /**
     * @dev Load PortfolioManager address from addresses.json or environment variable
     * @param vm The forge-std Vm interface
     * @return PortfolioManager instance
     */
    function loadPortfolioManager(Vm vm) internal view returns (PortfolioManager) {
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
     * @dev Get PortfolioFactory for aerodrome-usdc from PortfolioManager
     * @param portfolioManager The PortfolioManager instance
     * @return PortfolioFactory instance for aerodrome-usdc
     */
    function getAerodromeFactory(PortfolioManager portfolioManager) internal view returns (PortfolioFactory) {
        bytes32 salt = keccak256(abi.encodePacked("aerodrome-usdc"));
        address factoryAddress = portfolioManager.factoryBySalt(salt);
        require(factoryAddress != address(0), "Aerodrome factory not found");
        return PortfolioFactory(factoryAddress);
    }

    /**
     * @dev Get or create portfolio address for an owner from the aerodrome-usdc factory
     * @param vm The forge-std Vm interface
     * @param owner The owner address
     * @return portfolio The portfolio address (created if it doesn't exist)
     */
    function getPortfolioForOwner(Vm vm, address owner) internal returns (address) {
        PortfolioManager portfolioManager = loadPortfolioManager(vm);
        PortfolioFactory factory = getAerodromeFactory(portfolioManager);
        address portfolio = factory.portfolioOf(owner);
        
        // If portfolio doesn't exist, create it
        if (portfolio == address(0)) {
            portfolio = factory.createAccount(owner);
            console.log("Created new portfolio for owner:", owner);
            console.log("Portfolio address:", portfolio);
        }
        
        return portfolio;
    }

    /**
     * @dev Load PortfolioAddress from addresses.json (optional, returns address(0) if not found)
     * Note: This function does NOT create portfolios - only reads existing addresses
     * @param vm The forge-std Vm interface
     * @return portfolioAddress The portfolio address from addresses.json, or address(0) if not found
     */
    function loadPortfolioAddress(Vm vm) internal view returns (address) {
        // Try to read from addresses.json
        try vm.readFile(string.concat(vm.projectRoot(), "/addresses/addresses.json")) returns (string memory addressesJson) {
            // Try to read portfolioaddress (lowercase)
            if (addressesJson.keyExists(".portfolioaddress")) {
                return addressesJson.readAddress(".portfolioaddress");
            }
            
            // Try alternative field name (camelCase)
            if (addressesJson.keyExists(".portfolioAddress")) {
                return addressesJson.readAddress(".portfolioAddress");
            }
        } catch {
            // File read failed, will fall back to env vars
        }
        
        return address(0);
    }

    /**
     * @dev Get address from private key
     * @param vm The forge-std Vm interface
     * @param pk The private key
     * @return The address corresponding to the private key
     */
    function getAddressFromPrivateKey(Vm vm, uint256 pk) internal pure returns (address) {
        return vm.addr(pk);
    }
}

