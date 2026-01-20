// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title CancelListing
 * @dev Helper script to cancel a marketplace listing via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/CancelListing.s.sol:CancelListing --sig "run(uint256)" <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 forge script script/portfolio_account/helper/CancelListing.s.sol:CancelListing --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/CancelListing.s.sol:CancelListing --sig "run(uint256)" 109384 --rpc-url $BASE_RPC_URL --broadcast
 */
contract CancelListing is Script {
    using stdJson for string;

    /**
     * @dev Cancel a marketplace listing via PortfolioManager multicall
     * @param tokenId The veNFT token ID of the listing to cancel
     * @param owner The owner address (for getting portfolio from factory)
     */
    function cancelListing(
        uint256 tokenId,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = MarketplaceFacet.cancelListing.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "MarketplaceFacet.cancelListing not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Listing cancelled successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The veNFT token ID of the listing to cancel
     */
    function run(
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        cancelListing(tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/CancelListing.s.sol:CancelListing --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        cancelListing(tokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 forge script script/portfolio_account/helper/CancelListing.s.sol:CancelListing --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
