// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title UserSwap
 * @dev Helper script to swap tokens via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * The user must approve the portfolio account to spend the input token before calling.
 * Note: Cannot swap the collateral token (veNFT).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/UserSwap.s.sol:UserSwap --sig "run(address,bytes,address,uint256,address,uint256)" <SWAP_TARGET> <SWAP_DATA> <INPUT_TOKEN> <INPUT_AMOUNT> <OUTPUT_TOKEN> <MIN_OUTPUT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: SWAP_TARGET=0x... SWAP_DATA=0x... INPUT_TOKEN=0x... INPUT_AMOUNT=1000000 OUTPUT_TOKEN=0x... MIN_OUTPUT=900000 forge script script/portfolio_account/helper/UserSwap.s.sol:UserSwap --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/UserSwap.s.sol:UserSwap --sig "run(address,bytes,address,uint256,address,uint256)" 0x... 0x... 0x... 1000000 0x... 900000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract UserSwap is Script {
    using stdJson for string;

    /**
     * @dev Swap tokens via PortfolioManager multicall
     * @param swapTarget The DEX router/aggregator address
     * @param swapData The encoded swap call data
     * @param inputToken The token to swap from
     * @param inputAmount The amount of input token to swap
     * @param outputToken The token to receive
     * @param minimumOutputAmount The minimum amount of output token to receive
     * @param owner The owner address (for getting portfolio from factory)
     */
    function userSwap(
        address swapTarget,
        bytes memory swapData,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minimumOutputAmount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = SwapFacet.userSwap.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "SwapFacet.userSwap not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Check owner has approved the portfolio for input token
        IERC20 inputTokenContract = IERC20(inputToken);
        uint256 allowance = inputTokenContract.allowance(owner, portfolioAddress);
        require(allowance >= inputAmount, "Insufficient allowance. Please approve the portfolio account first.");

        // Check owner has sufficient balance
        uint256 balance = inputTokenContract.balanceOf(owner);
        require(balance >= inputAmount, "Insufficient balance");

        console.log("Swap Details:");
        console.log("  Input Token:", inputToken);
        console.log("  Input Amount:", inputAmount);
        console.log("  Output Token:", outputToken);
        console.log("  Minimum Output:", minimumOutputAmount);

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            swapTarget,
            swapData,
            inputToken,
            inputAmount,
            outputToken,
            minimumOutputAmount
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Swap successful!");
        console.log("Portfolio Address:", portfolioAddress);
    }

    /**
     * @dev Main run function for forge script execution
     * @param swapTarget The DEX router/aggregator address
     * @param swapData The encoded swap call data
     * @param inputToken The token to swap from
     * @param inputAmount The amount of input token to swap
     * @param outputToken The token to receive
     * @param minimumOutputAmount The minimum amount of output token to receive
     */
    function run(
        address swapTarget,
        bytes memory swapData,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 minimumOutputAmount
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        userSwap(swapTarget, swapData, inputToken, inputAmount, outputToken, minimumOutputAmount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... SWAP_TARGET=0x... SWAP_DATA=0x... INPUT_TOKEN=0x... INPUT_AMOUNT=1000000 OUTPUT_TOKEN=0x... MIN_OUTPUT=900000 forge script script/portfolio_account/helper/UserSwap.s.sol:UserSwap --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        address swapTarget = vm.envAddress("SWAP_TARGET");
        bytes memory swapData = vm.envBytes("SWAP_DATA");
        address inputToken = vm.envAddress("INPUT_TOKEN");
        uint256 inputAmount = vm.envUint("INPUT_AMOUNT");
        address outputToken = vm.envAddress("OUTPUT_TOKEN");
        uint256 minimumOutputAmount = vm.envUint("MIN_OUTPUT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        userSwap(swapTarget, swapData, inputToken, inputAmount, outputToken, minimumOutputAmount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// SWAP_TARGET=0x... SWAP_DATA=0x... INPUT_TOKEN=0x... INPUT_AMOUNT=1000000 OUTPUT_TOKEN=0x... MIN_OUTPUT=900000 forge script script/portfolio_account/helper/UserSwap.s.sol:UserSwap --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
