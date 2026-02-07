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
 * @title SetRewardsRecipient
 * @dev Helper script to set the rewards recipient via PortfolioManager multicall
 *
 * The recipient is used when rewards option is set to PayToRecipient (option 2).
 * Rewards will be sent to this address instead of being used to pay debt.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetRewardsRecipient.s.sol:SetRewardsRecipient --sig "run(address)" <RECIPIENT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: RECIPIENT=0x... forge script script/portfolio_account/helper/SetRewardsRecipient.s.sol:SetRewardsRecipient --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetRewardsRecipient.s.sol:SetRewardsRecipient --sig "run(address)" 0x1234... --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetRewardsRecipient is Script {
    using stdJson for string;

    /**
     * @dev Set rewards recipient via PortfolioManager multicall
     * @param recipient The address to receive rewards when PayToRecipient option is selected
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setRewardsRecipient(
        address recipient,
        address owner
    ) internal {
        require(recipient != address(0), "Recipient cannot be zero address");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = RewardsProcessingFacet.setRecipient.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "RewardsProcessingFacet.setRecipient not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            recipient
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Rewards recipient set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Recipient:", recipient);
    }

    /**
     * @dev Main run function for forge script execution
     * @param recipient The address to receive rewards
     */
    function run(
        address recipient
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setRewardsRecipient(recipient, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... RECIPIENT=0x... forge script script/portfolio_account/helper/SetRewardsRecipient.s.sol:SetRewardsRecipient --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        address recipient = vm.envAddress("RECIPIENT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setRewardsRecipient(recipient, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// RECIPIENT=0x1234... forge script script/portfolio_account/helper/SetRewardsRecipient.s.sol:SetRewardsRecipient --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
