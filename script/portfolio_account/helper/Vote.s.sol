// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title Vote
 * @dev Helper script to vote on pools via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * Voting sets the user to manual voting mode automatically.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/Vote.s.sol:Vote --sig "run(uint256,address[],uint256[])" <TOKEN_ID> "[pool1,pool2]" "[weight1,weight2]" --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 POOLS='["0x...","0x..."]' WEIGHTS='[50,50]' forge script script/portfolio_account/helper/Vote.s.sol:Vote --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/Vote.s.sol:Vote --sig "run(uint256,address[],uint256[])" 109384 "[0x1234...,0x5678...]" "[5000,5000]" --rpc-url $BASE_RPC_URL --broadcast
 */
contract Vote is Script {
    using stdJson for string;

    /**
     * @dev Vote on pools via PortfolioManager multicall
     * @param tokenId The voting escrow token ID
     * @param pools Array of pool addresses to vote for
     * @param weights Array of weights for each pool (should sum to 10000 for 100%)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function vote(
        uint256 tokenId,
        address[] memory pools,
        uint256[] memory weights,
        address owner
    ) internal {
        require(pools.length == weights.length, "Pools and weights arrays must have the same length");
        require(pools.length > 0, "Must provide at least one pool");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingFacet.vote.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingFacet.vote not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId,
            pools,
            weights
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Vote successful!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Number of pools:", pools.length);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The voting escrow token ID
     * @param pools Array of pool addresses to vote for
     * @param weights Array of weights for each pool
     */
    function run(
        uint256 tokenId,
        address[] memory pools,
        uint256[] memory weights
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        vote(tokenId, pools, weights, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 POOLS='["0x...","0x..."]' WEIGHTS='[50,50]' forge script script/portfolio_account/helper/Vote.s.sol:Vote --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Parse pools from JSON
        string memory poolsJson = vm.envString("POOLS");
        address[] memory pools = vm.parseJsonAddressArray(poolsJson, "");

        // Parse weights from JSON
        string memory weightsJson = vm.envString("WEIGHTS");
        uint256[] memory weights = vm.parseJsonUintArray(weightsJson, "");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        vote(tokenId, pools, weights, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 POOLS='["0x1234...","0x5678..."]' WEIGHTS='[5000,5000]' forge script script/portfolio_account/helper/Vote.s.sol:Vote --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
