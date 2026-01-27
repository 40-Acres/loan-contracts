// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../src/facets/account/config/PortfolioAccountConfig.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @dev Interface for facets that expose _portfolioAccountConfig
interface IFacetWithConfig {
    function _portfolioAccountConfig() external view returns (PortfolioAccountConfig);
}

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
     * @dev Get PortfolioFactory for aerodrome from PortfolioManager
     * @param vm The forge-std Vm interface
     * @param portfolioManager The PortfolioManager instance
     * @return PortfolioFactory instance for the configured factory type
     * @notice Set FACTORY_SALT env var to override (e.g., "aerodrome-usdc-dynamic-fees"). Defaults to "aerodrome-usdc"
     */
    function getAerodromeFactory(Vm vm, PortfolioManager portfolioManager) internal view returns (PortfolioFactory) {
        string memory factorySalt = vm.envOr("FACTORY_SALT", string("aerodrome-usdc"));
        bytes32 salt = keccak256(abi.encodePacked(factorySalt));
        address factoryAddress = portfolioManager.factoryBySalt(salt);
        require(factoryAddress != address(0), string.concat("Factory not found for salt: ", factorySalt));
        return PortfolioFactory(factoryAddress);
    }

    /**
     * @dev Get or create portfolio address for an owner from the configured factory
     * @param vm The forge-std Vm interface
     * @param owner The owner address
     * @return portfolio The portfolio address (created if it doesn't exist)
     * @notice Uses FACTORY_SALT env var to select factory (defaults to "aerodrome-usdc")
     */
    function getPortfolioForOwner(Vm vm, address owner) internal returns (address) {
        PortfolioManager portfolioManager = loadPortfolioManager(vm);
        PortfolioFactory factory = getAerodromeFactory(vm, portfolioManager);
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

    /**
     * @dev Get PortfolioAccountConfig from a factory by reading it from a registered facet
     * @param factory The PortfolioFactory instance
     * @return PortfolioAccountConfig instance
     * @notice Reads _portfolioAccountConfig from the LendingFacet (borrow selector)
     */
    function getConfigFromFactory(PortfolioFactory factory) internal view returns (PortfolioAccountConfig) {
        FacetRegistry facetRegistry = factory.facetRegistry();
        // Use borrow selector (LendingFacet) to get a facet that has _portfolioAccountConfig
        bytes4 borrowSelector = bytes4(keccak256("borrow(uint256)"));
        address facetAddress = facetRegistry.getFacetForSelector(borrowSelector);
        require(facetAddress != address(0), "LendingFacet not registered. Deploy facets first.");
        return IFacetWithConfig(facetAddress)._portfolioAccountConfig();
    }

    /**
     * @dev Get vault address from a factory based on deployment type
     * @param vm The forge-std Vm interface
     * @param factory The PortfolioFactory instance
     * @return vault The vault address for this factory's deployment
     * @notice For DynamicFeesVault deployments (dynamic-fees salt), the vault IS the loan contract
     * @notice Set VAULT_ADDRESS env var to override automatic vault resolution
     */
    function getVaultFromFactory(Vm vm, PortfolioFactory factory) internal view returns (address) {
        // Allow explicit vault address override
        address vaultOverride = vm.envOr("VAULT_ADDRESS", address(0));
        if (vaultOverride != address(0)) {
            return vaultOverride;
        }

        PortfolioAccountConfig config = getConfigFromFactory(factory);
        string memory factorySalt = vm.envOr("FACTORY_SALT", string("aerodrome-usdc"));

        // For dynamic fees deployments, the loan contract IS the vault
        if (_containsDynamicFees(factorySalt)) {
            return config.getLoanContract();
        }

        // For legacy deployments, get vault from loan contract
        address loanContract = config.getLoanContract();
        require(loanContract != address(0), "LoanContract not set. Set VAULT_ADDRESS env var or configure loanContract in PortfolioAccountConfig.");
        return ILoanWithVault(loanContract)._vault();
    }

    /**
     * @dev Get vault address using current FACTORY_SALT
     * @param vm The forge-std Vm interface
     * @return vault The vault address for the configured factory
     * @notice Uses FACTORY_SALT env var to select factory (defaults to "aerodrome-usdc")
     */
    function getVault(Vm vm) internal view returns (address) {
        PortfolioManager portfolioManager = loadPortfolioManager(vm);
        PortfolioFactory factory = getAerodromeFactory(vm, portfolioManager);
        return getVaultFromFactory(vm, factory);
    }

    /**
     * @dev Check if factory salt indicates a dynamic fees deployment
     */
    function _containsDynamicFees(string memory salt) private pure returns (bool) {
        bytes memory saltBytes = bytes(salt);
        bytes memory pattern = bytes("dynamic-fees");

        if (saltBytes.length < pattern.length) return false;

        for (uint i = 0; i <= saltBytes.length - pattern.length; i++) {
            bool found = true;
            for (uint j = 0; j < pattern.length; j++) {
                if (saltBytes[i + j] != pattern[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    // Base USDC address - used as default debt token
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /**
     * @dev Get the debt token (underlying asset) address from the factory's config
     * @param vm The forge-std Vm interface
     * @param factory The PortfolioFactory instance
     * @return The debt token address (e.g., USDC)
     * @notice Set DEBT_TOKEN env var to override. Defaults to Base USDC if loan contract not configured.
     */
    function getDebtTokenFromFactory(Vm vm, PortfolioFactory factory) internal view returns (address) {
        // Allow explicit debt token override
        address debtTokenOverride = vm.envOr("DEBT_TOKEN", address(0));
        if (debtTokenOverride != address(0)) {
            return debtTokenOverride;
        }

        PortfolioAccountConfig config = getConfigFromFactory(factory);
        string memory factorySalt = vm.envOr("FACTORY_SALT", string("aerodrome-usdc"));

        // For dynamic fees deployments, call lendingAsset() on the vault
        if (_containsDynamicFees(factorySalt)) {
            return ILendingPool(config.getLoanContract()).lendingAsset();
        }

        // For legacy deployments, try to get from loan contract, default to USDC
        address loanContract = config.getLoanContract();
        if (loanContract == address(0)) {
            return BASE_USDC;
        }
        return ILoanWithAsset(loanContract)._asset();
    }
}

interface ILendingPool {
    function lendingAsset() external view returns (address);
}

interface ILoanWithVault {
    function _vault() external view returns (address);
}

interface ILoanWithAsset {
    function _asset() external view returns (address);
}

