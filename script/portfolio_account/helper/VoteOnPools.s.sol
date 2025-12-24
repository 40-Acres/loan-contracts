// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {IVotingFacet} from "../../../src/facets/account/vote/interfaces/IVotingFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title VoteOnPools
 * @dev Helper script to vote on pools via PortfolioManager multicall
 * 
 * Portfolio address can be loaded from addresses.json (field: "portfolioaddress" or "portfolioAddress")
 * or passed as a parameter/environment variable.
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/VoteOnPools.s.sol:VoteOnPools --sig "run(uint256,address[],uint256[])" <TOKEN_ID> <POOLS_ARRAY> <WEIGHTS_ARRAY> --rpc-url $RPC_URL --broadcast
 * 2. From addresses.json + env vars: TOKEN_ID=1 POOLS=0x123... WEIGHTS=100e18 forge script script/portfolio_account/helper/VoteOnPools.s.sol:VoteOnPools --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/VoteOnPools.s.sol:VoteOnPools --sig "run(uint256,address[],uint256[])" 1 "[0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0]" "[100e18]" --rpc-url $BASE_RPC_URL --broadcast
 */
contract VoteOnPools is Script {
    using stdJson for string;

    /**
     * @dev Vote on pools via PortfolioManager multicall
     * @param portfolioAddress The portfolio account address
     * @param tokenId The voting escrow token ID
     * @param pools Array of pool addresses to vote on
     * @param weights Array of weights for each pool (should sum to 100e18)
     */
    function voteOnPools(
        address portfolioAddress,
        uint256 tokenId,
        address[] memory pools,
        uint256[] memory weights
    ) internal {
        require(pools.length > 0, "Pools array cannot be empty");
        require(pools.length == weights.length, "Pools and weights arrays must have the same length");
        
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        
        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingFacet.vote.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingFacet.vote not registered in FacetRegistry. Please deploy facets first.");
        
        // Use factory address instead of portfolio address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId,
            pools,
            weights
        );
        
        bytes[] memory results = portfolioManager.multicall(calldatas, factories);
        require(results.length > 0, "Multicall failed - no results");
        
        console.log("Vote submitted successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Number of pools:", pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            console.log("Pool", i, ":", pools[i]);
            console.log("Weight", i, ":", weights[i]);
        }
    }

    /**
     * @dev Main run function for forge script execution
     * @param portfolioAddress The portfolio account address
     * @param tokenId The voting escrow token ID
     * @param pools Array of pool addresses to vote on
     * @param weights Array of weights for each pool
     */
    function run(
        address portfolioAddress,
        uint256 tokenId,
        address[] memory pools,
        uint256[] memory weights
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        voteOnPools(portfolioAddress, tokenId, pools, weights);
        vm.stopBroadcast();
    }


    /**
     * @dev Alternative run function that reads parameters from addresses.json and environment variables
     * Portfolio address is loaded from addresses.json if available, otherwise from PORTFOLIO_ADDRESS env var,
     * or from PRIVATE_KEY/OWNER env var using the aerodrome-usdc factory
     * 
     * Environment variables:
     * - TOKEN_ID: The voting escrow token ID (required)
     * - POOLS: JSON array of pool addresses, e.g., ["0x123...","0x456..."] (required)
     * - WEIGHTS: JSON array of weights, e.g., ["50e18","50e18"] (required)
     * - PRIVATE_KEY: Private key for signing (required)
     * 
     * Usage: 
     * TOKEN_ID=1 POOLS='["0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0"]' WEIGHTS='["100e18"]' forge script script/portfolio_account/helper/VoteOnPools.s.sol:VoteOnPools --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        string memory poolsJson = vm.envString("POOLS");
        string memory weightsJson = vm.envString("WEIGHTS");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        
        vm.startBroadcast(privateKey);
        
        // Parse pools and weights from JSON
        address[] memory pools = vm.parseJsonAddressArray(poolsJson, "");
        uint256[] memory weights = vm.parseJsonUintArray(weightsJson, "");
        
        require(pools.length > 0, "Pools array cannot be empty");
        require(pools.length == weights.length, "Pools and weights arrays must have the same length");
        
        // Get or create portfolio (must happen during broadcast)
        // Always use owner-based lookup when PRIVATE_KEY is available to ensure portfolio exists
        address portfolioAddress = PortfolioHelperUtils.getPortfolioForOwner(vm, owner);
        
        // Only use PORTFOLIO_ADDRESS if explicitly provided and different from owner-based lookup
        try vm.envAddress("PORTFOLIO_ADDRESS") returns (address providedAddr) {
            if (providedAddr != address(0) && providedAddr != portfolioAddress) {
                // Validate that provided address is registered
                PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
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
        
        voteOnPools(portfolioAddress, tokenId, pools, weights);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 POOLS='["0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0"]' WEIGHTS='["100e18"]' forge script script/portfolio_account/helper/VoteOnPools.s.sol:VoteOnPools --sig "run()" --rpc-url $BASE_RPC_URL --broadcast

