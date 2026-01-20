// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title SetRewardsToken
 * @dev Helper script to set the rewards token via PortfolioManager multicall
 *
 * The rewards token is the token that rewards are converted to before processing.
 * Common choices: USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), AERO (0x940181a94A35A4569E4529A3CDfB74e38FD98631)
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetRewardsToken.s.sol:SetRewardsToken --sig "run(address)" <TOKEN_ADDRESS> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: REWARDS_TOKEN=0x... forge script script/portfolio_account/helper/SetRewardsToken.s.sol:SetRewardsToken --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetRewardsToken.s.sol:SetRewardsToken --sig "run(address)" 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetRewardsToken is Script {
    using stdJson for string;

    /**
     * @dev Set rewards token via PortfolioManager multicall
     * @param rewardsToken The address of the token to receive rewards in
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setRewardsToken(
        address rewardsToken,
        address owner
    ) internal {
        require(rewardsToken != address(0), "Rewards token cannot be zero address");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = RewardsProcessingFacet.setRewardsToken.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "RewardsProcessingFacet.setRewardsToken not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            rewardsToken
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Rewards token set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Rewards Token:", rewardsToken);
    }

    /**
     * @dev Main run function for forge script execution
     * @param rewardsToken The address of the token to receive rewards in
     */
    function run(
        address rewardsToken
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setRewardsToken(rewardsToken, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... REWARDS_TOKEN=0x... forge script script/portfolio_account/helper/SetRewardsToken.s.sol:SetRewardsToken --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        address rewardsToken = vm.envAddress("REWARDS_TOKEN");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setRewardsToken(rewardsToken, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// REWARDS_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 forge script script/portfolio_account/helper/SetRewardsToken.s.sol:SetRewardsToken --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
