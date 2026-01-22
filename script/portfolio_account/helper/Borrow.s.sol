// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title Borrow
 * @dev Helper script to borrow USDC against collateral via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/Borrow.s.sol:Borrow --sig "run(uint256)" <AMOUNT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: AMOUNT=1000000 forge script script/portfolio_account/helper/Borrow.s.sol:Borrow --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/Borrow.s.sol:Borrow --sig "run(uint256)" 1000000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract Borrow is Script {
    using stdJson for string;

    /**
     * @dev Borrow USDC via PortfolioManager multicall
     * @param amount The amount of USDC to borrow (in wei, 6 decimals for USDC)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function borrow(
        uint256 amount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = LendingFacet.borrow.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "LendingFacet.borrow not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Check max loan available
        (uint256 maxLoan, ) = CollateralFacet(portfolioAddress).getMaxLoan();
        console.log("Max loan available:", maxLoan);
        require(amount <= maxLoan, "Requested amount exceeds max loan");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            amount
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Borrow successful!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Amount borrowed:", amount);

        // Check updated debt
        uint256 totalDebt = CollateralFacet(portfolioAddress).getTotalDebt();
        console.log("Total debt after borrow:", totalDebt);
    }

    /**
     * @dev Main run function for forge script execution
     * @param amount The amount of USDC to borrow (in wei)
     */
    function run(
        uint256 amount
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        borrow(amount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... AMOUNT=1000000 forge script script/portfolio_account/helper/Borrow.s.sol:Borrow --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        borrow(amount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000 forge script script/portfolio_account/helper/Borrow.s.sol:Borrow --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
