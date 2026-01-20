// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title ClaimFees
 * @dev Helper script to claim Aerodrome fees via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/ClaimFees.s.sol:ClaimFees --sig "run(address[],address[][],uint256)" <FEES> <TOKENS> <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: FEES='["0x..."]' TOKENS='[["0x...","0x..."]]' TOKEN_ID=1 forge script script/portfolio_account/helper/ClaimFees.s.sol:ClaimFees --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/ClaimFees.s.sol:ClaimFees --sig "run(uint256)" 109384 --rpc-url $BASE_RPC_URL --broadcast
 */
contract ClaimFees is Script {
    using stdJson for string;

    /**
     * @dev Claim fees via PortfolioManager multicall
     * @param fees Array of fee contract addresses
     * @param tokens Array of token arrays (one for each fee contract)
     * @param tokenId The voting escrow token ID
     * @param owner The owner address (for getting portfolio from factory)
     */
    function claimFees(
        address[] memory fees,
        address[][] memory tokens,
        uint256 tokenId,
        address owner
    ) internal {
        require(fees.length == tokens.length, "Fees and tokens arrays must have the same length");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = ClaimingFacet.claimFees.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "ClaimingFacet.claimFees not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            fees,
            tokens,
            tokenId
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Fees claimed successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Number of fee contracts:", fees.length);
    }

    /**
     * @dev Main run function for forge script execution with empty fees/tokens (for quick claiming)
     * @param tokenId The voting escrow token ID
     */
    function run(
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        // Use empty arrays - the facet will handle discovering claimable fees
        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);

        vm.startBroadcast(privateKey);
        claimFees(fees, tokens, tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Full run function with fee and token parameters
     * @param fees Array of fee contract addresses
     * @param tokens Array of token arrays
     * @param tokenId The voting escrow token ID
     */
    function run(
        address[] memory fees,
        address[][] memory tokens,
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        claimFees(fees, tokens, tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 FEES='["0x..."]' TOKENS='[["0x...","0x..."]]' forge script script/portfolio_account/helper/ClaimFees.s.sol:ClaimFees --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Try to get fees and tokens from env, use empty arrays if not provided
        address[] memory fees;
        address[][] memory tokens;

        try vm.envString("FEES") returns (string memory feesJson) {
            fees = vm.parseJsonAddressArray(feesJson, "");
        } catch {
            fees = new address[](0);
        }

        // For tokens, we need to handle the nested array structure
        // This is simplified - in practice you might need custom parsing
        tokens = new address[][](fees.length);

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        claimFees(fees, tokens, tokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 forge script script/portfolio_account/helper/ClaimFees.s.sol:ClaimFees --sig "run(uint256)" 109384 --rpc-url $BASE_RPC_URL --broadcast
