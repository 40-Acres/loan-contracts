// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {UserRewardsConfig} from "../../../src/facets/account/rewards_processing/UserRewardsConfig.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title SetRewardsOption
 * @dev Helper script to set rewards processing option via PortfolioManager multicall
 *
 * Rewards options:
 * - 0: PayBalance - Use rewards to pay down debt
 * - 1: IncreaseCollateral - Use rewards to increase veAERO lock
 * - 2: PayToRecipient - Send rewards to a specified recipient
 * - 3: InvestToVault - Invest rewards into the vault
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetRewardsOption.s.sol:SetRewardsOption --sig "run(uint8)" <OPTION> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: REWARDS_OPTION=0 forge script script/portfolio_account/helper/SetRewardsOption.s.sol:SetRewardsOption --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetRewardsOption.s.sol:SetRewardsOption --sig "run(uint8)" 0 --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetRewardsOption is Script {
    using stdJson for string;

    /**
     * @dev Set rewards option via PortfolioManager multicall
     * @param option The rewards option (0=PayBalance, 1=IncreaseCollateral, 2=PayToRecipient, 3=InvestToVault)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setRewardsOption(
        uint8 option,
        address owner
    ) internal {
        require(option <= 3, "Invalid rewards option. Must be 0-3");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = RewardsProcessingFacet.setRewardsOption.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "RewardsProcessingFacet.setRewardsOption not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            UserRewardsConfig.RewardsOption(option)
        );

        portfolioManager.multicall(calldatas, factories);

        string memory optionName;
        if (option == 0) optionName = "PayBalance";
        else if (option == 1) optionName = "IncreaseCollateral";
        else if (option == 2) optionName = "PayToRecipient";
        else if (option == 3) optionName = "InvestToVault";

        console.log("Rewards option set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Rewards Option:", optionName);
    }

    /**
     * @dev Main run function for forge script execution
     * @param option The rewards option (0-3)
     */
    function run(
        uint8 option
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setRewardsOption(option, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... REWARDS_OPTION=0 forge script script/portfolio_account/helper/SetRewardsOption.s.sol:SetRewardsOption --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 option = vm.envUint("REWARDS_OPTION");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setRewardsOption(uint8(option), owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// REWARDS_OPTION=0 forge script script/portfolio_account/helper/SetRewardsOption.s.sol:SetRewardsOption --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
