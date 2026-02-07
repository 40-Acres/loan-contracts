// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title SetTopUp
 * @dev Helper script to enable or disable automatic top-up via PortfolioManager multicall
 *
 * When enabled, the protocol can automatically borrow up to max loan on behalf of the user.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetTopUp.s.sol:SetTopUp --sig "run(bool)" <ENABLED> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: ENABLED=true forge script script/portfolio_account/helper/SetTopUp.s.sol:SetTopUp --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetTopUp.s.sol:SetTopUp --sig "run(bool)" true --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetTopUp is Script {
    using stdJson for string;

    /**
     * @dev Set top-up preference via PortfolioManager multicall
     * @param enabled Whether to enable or disable automatic top-up
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setTopUp(
        bool enabled,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = BaseLendingFacet.setTopUp.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "BaseLendingFacet.setTopUp not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            enabled
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Top-up preference updated!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Top-up enabled:", enabled);
    }

    /**
     * @dev Main run function for forge script execution
     * @param enabled Whether to enable or disable automatic top-up
     */
    function run(
        bool enabled
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setTopUp(enabled, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... ENABLED=true forge script script/portfolio_account/helper/SetTopUp.s.sol:SetTopUp --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        string memory enabledStr = vm.envString("ENABLED");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Parse enabled string to bool
        bool enabled;
        bytes memory enabledBytes = bytes(enabledStr);
        if (enabledBytes.length == 1 && enabledBytes[0] == '1') {
            enabled = true;
        } else if (keccak256(enabledBytes) == keccak256(bytes("true"))) {
            enabled = true;
        } else if (enabledBytes.length == 1 && enabledBytes[0] == '0') {
            enabled = false;
        } else if (keccak256(enabledBytes) == keccak256(bytes("false"))) {
            enabled = false;
        } else {
            revert("ENABLED must be 'true', 'false', '1', or '0'");
        }

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setTopUp(enabled, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// ENABLED=true forge script script/portfolio_account/helper/SetTopUp.s.sol:SetTopUp --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
