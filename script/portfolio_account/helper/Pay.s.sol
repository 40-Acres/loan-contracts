// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title Pay
 * @dev Helper script to repay debt via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/Pay.s.sol:Pay --sig "run(uint256)" <AMOUNT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: AMOUNT=1000000 forge script script/portfolio_account/helper/Pay.s.sol:Pay --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/Pay.s.sol:Pay --sig "run(uint256)" 1000000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract Pay is Script {
    using stdJson for string;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC

    /**
     * @dev Repay debt via PortfolioManager multicall
     * @param amount The amount of USDC to repay (in wei, 6 decimals for USDC)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function pay(
        uint256 amount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = BaseLendingFacet.pay.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "BaseLendingFacet.pay not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist.");

        // Check current debt
        uint256 currentDebt = CollateralFacet(portfolioAddress).getTotalDebt();
        console.log("Current debt:", currentDebt);

        // Approve portfolio to spend USDC from owner
        IERC20(USDC).approve(portfolioAddress, amount);

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            amount
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Payment successful!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Amount paid:", amount);

        // Check updated debt
        uint256 newDebt = CollateralFacet(portfolioAddress).getTotalDebt();
        console.log("Total debt after payment:", newDebt);
    }

    /**
     * @dev Main run function for forge script execution
     * @param amount The amount of USDC to repay (in wei)
     */
    function run(
        uint256 amount
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        pay(amount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... AMOUNT=1000000 forge script script/portfolio_account/helper/Pay.s.sol:Pay --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        pay(amount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000 forge script script/portfolio_account/helper/Pay.s.sol:Pay --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
