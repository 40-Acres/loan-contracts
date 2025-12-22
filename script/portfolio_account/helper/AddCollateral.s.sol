// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title AddCollateral
 * @dev Helper script to add collateral via PortfolioManager multicall
 * 
 * Portfolio address can be loaded from addresses.json (field: "portfolioaddress" or "portfolioAddress")
 * or passed as a parameter/environment variable.
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run(address,uint256)" <PORTFOLIO_ADDRESS> <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From addresses.json + env vars: TOKEN_ID=1 forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run(address,uint256)" 0x123... 1 --rpc-url $BASE_RPC_URL --broadcast
 */
contract AddCollateral is Script {
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
     * @dev Get PortfolioFactory for aerodrome-usdc from PortfolioManager
     */
    function getAerodromeFactory(PortfolioManager portfolioManager) internal view returns (PortfolioFactory) {
        bytes32 salt = keccak256(abi.encodePacked("aerodrome-usdc"));
        address factoryAddress = portfolioManager.factoryBySalt(salt);
        require(factoryAddress != address(0), "Aerodrome factory not found");
        return PortfolioFactory(factoryAddress);
    }

    /**
     * @dev Get or create portfolio address for an owner from the aerodrome-usdc factory
     */
    function getPortfolioForOwner(address owner) internal returns (address) {
        PortfolioManager portfolioManager = loadPortfolioManager();
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
     */
    function loadPortfolioAddress() internal view returns (address) {
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
            
            // Note: We don't create portfolio here - that happens during broadcast
            // If owner is in JSON, we'll return 0 and let the broadcast block handle creation
        } catch {
            // File read failed, will fall back to env vars
        }
        
        return address(0);
    }

    /**
     * @dev Add collateral via PortfolioManager multicall
     * @param portfolioAddress The portfolio account address
     * @param tokenId The token ID of the voting escrow NFT to add as collateral
     */
    function addCollateral(
        address portfolioAddress,
        uint256 tokenId
    ) internal {
        PortfolioManager portfolioManager = loadPortfolioManager();
        
        // Verify the facet is registered
        PortfolioFactory factory = getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = CollateralFacet.addCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.addCollateral not registered in FacetRegistry. Please deploy facets first.");
        
        address[] memory portfolios = new address[](1);
        portfolios[0] = portfolioAddress;
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId
        );
        
        portfolioManager.multicall(calldatas, portfolios);
        
        console.log("Collateral added successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        
        // Optionally check the total locked collateral
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total Locked Collateral:", totalCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     * @param portfolioAddress The portfolio account address
     * @param tokenId The token ID of the voting escrow NFT to add as collateral
     */
    function run(
        address portfolioAddress,
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        addCollateral(portfolioAddress, tokenId);
        vm.stopBroadcast();
    }

    /**
     * @dev Get address from private key
     */
    function getAddressFromPrivateKey(uint256 pk) internal pure returns (address) {
        return vm.addr(pk);
    }

    /**
     * @dev Alternative run function that reads parameters from addresses.json and environment variables
     * Portfolio address is loaded from addresses.json if available, otherwise from PORTFOLIO_ADDRESS env var,
     * or from PRIVATE_KEY/OWNER env var using the aerodrome-usdc factory
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        // Get owner address from private key
        address owner = getAddressFromPrivateKey(privateKey);
        
        vm.startBroadcast(privateKey);
        
        // Get or create portfolio (must happen during broadcast)
        // Always use owner-based lookup when PRIVATE_KEY is available to ensure portfolio exists
        address portfolioAddress = getPortfolioForOwner(owner);
        
        // Only use PORTFOLIO_ADDRESS if explicitly provided and different from owner-based lookup
        try vm.envAddress("PORTFOLIO_ADDRESS") returns (address providedAddr) {
            if (providedAddr != address(0) && providedAddr != portfolioAddress) {
                // Validate that provided address is registered
                PortfolioManager portfolioManager = loadPortfolioManager();
                address factory = portfolioManager.portfolioToFactory(providedAddr);
                if (factory != address(0)) {
                    portfolioAddress = providedAddr;
                } else {
                    console.log("Warning: PORTFOLIO_ADDRESS not registered, using owner-based portfolio");
                }
            }
        } catch {
            // PORTFOLIO_ADDRESS not set, use owner-based portfolio
        }
        
        addCollateral(portfolioAddress, tokenId);
        vm.stopBroadcast();
    }
}

// CLI Usage Examples:
// ===================
//
// 1. Using PRIVATE_KEY (portfolio will be looked up from signer's address via aerodrome-usdc factory):
//    PRIVATE_KEY=0x1234567890123456789012345678901234567890123456789012345678901234 \
//    TOKEN_ID=1 \
//    forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral \
//      --sig "run()" \
//      --rpc-url $BASE_RPC_URL \
//      --broadcast
//
// 2. Using direct parameters with PRIVATE_KEY:
//    PRIVATE_KEY=0x1234567890123456789012345678901234567890123456789012345678901234 \
//    forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral \
//      --sig "run(address,uint256)" \
//      0x1234567890123456789012345678901234567890 \
//      1 \
//      --rpc-url $BASE_RPC_URL \
//      --broadcast
//
// 3. Using PORTFOLIO_ADDRESS env var with PRIVATE_KEY:
//    PRIVATE_KEY=0x1234567890123456789012345678901234567890123456789012345678901234 \
//    PORTFOLIO_ADDRESS=0x1234567890123456789012345678901234567890 \
//    TOKEN_ID=1 \
//    forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral \
//      --sig "run()" \
//      --rpc-url $BASE_RPC_URL \
//      --broadcast
//
// Note: PRIVATE_KEY is required for broadcasting transactions
//       Token ID is the voting escrow NFT token ID to add as collateral
//       If portfolio address is not provided, it will be looked up from the signer's address

