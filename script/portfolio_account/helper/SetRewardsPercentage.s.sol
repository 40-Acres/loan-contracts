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
 * @title SetRewardsPercentage
 * @dev Helper script to set the rewards option percentage via PortfolioManager multicall
 *
 * The percentage determines how much of the rewards go to the selected option (0-100).
 * The remainder goes to the default behavior (pay debt).
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetRewardsPercentage.s.sol:SetRewardsPercentage --sig "run(uint256)" <PERCENTAGE> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: PERCENTAGE=50 forge script script/portfolio_account/helper/SetRewardsPercentage.s.sol:SetRewardsPercentage --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetRewardsPercentage.s.sol:SetRewardsPercentage --sig "run(uint256)" 50 --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetRewardsPercentage is Script {
    using stdJson for string;

    /**
     * @dev Set rewards percentage via PortfolioManager multicall
     * @param percentage The percentage of rewards for the selected option (0-100)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setRewardsPercentage(
        uint256 percentage,
        address owner
    ) internal {
        require(percentage <= 100, "Percentage must be between 0 and 100");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = RewardsProcessingFacet.setRewardsOptionPercentage.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "RewardsProcessingFacet.setRewardsOptionPercentage not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            percentage
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Rewards percentage set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Rewards Percentage:", percentage);
    }

    /**
     * @dev Main run function for forge script execution
     * @param percentage The percentage of rewards for the selected option (0-100)
     */
    function run(
        uint256 percentage
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setRewardsPercentage(percentage, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... PERCENTAGE=50 forge script script/portfolio_account/helper/SetRewardsPercentage.s.sol:SetRewardsPercentage --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 percentage = vm.envUint("PERCENTAGE");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setRewardsPercentage(percentage, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// PERCENTAGE=50 forge script script/portfolio_account/helper/SetRewardsPercentage.s.sol:SetRewardsPercentage --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
