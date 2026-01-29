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
 * @title SetVotingMode
 * @dev Helper script to switch between manual and automatic voting modes via PortfolioManager multicall
 *
 * Voting modes:
 * - Manual (true): User must vote manually each epoch
 * - Automatic (false): Protocol can vote on behalf of user using default votes
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetVotingMode.s.sol:SetVotingMode --sig "run(uint256,bool)" <TOKEN_ID> <MANUAL_VOTING> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 MANUAL_VOTING=true forge script script/portfolio_account/helper/SetVotingMode.s.sol:SetVotingMode --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetVotingMode.s.sol:SetVotingMode --sig "run(uint256,bool)" 109384 true --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetVotingMode is Script {
    using stdJson for string;

    /**
     * @dev Set voting mode via PortfolioManager multicall
     * @param tokenId The voting escrow token ID
     * @param manualVoting Whether to enable manual voting (true) or automatic (false)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setVotingMode(
        uint256 tokenId,
        bool manualVoting,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingFacet.setVotingMode.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingFacet.setVotingMode not registered in FacetRegistry. Please deploy facets first.");

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
            manualVoting
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Voting mode set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Manual Voting:", manualVoting);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The voting escrow token ID
     * @param manualVoting Whether to enable manual voting
     */
    function run(
        uint256 tokenId,
        bool manualVoting
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setVotingMode(tokenId, manualVoting, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 MANUAL_VOTING=true forge script script/portfolio_account/helper/SetVotingMode.s.sol:SetVotingMode --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        string memory manualVotingStr = vm.envString("MANUAL_VOTING");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Parse manualVoting string to bool
        bool manualVoting;
        bytes memory manualVotingBytes = bytes(manualVotingStr);
        if (manualVotingBytes.length == 1 && manualVotingBytes[0] == '1') {
            manualVoting = true;
        } else if (keccak256(manualVotingBytes) == keccak256(bytes("true"))) {
            manualVoting = true;
        } else if (manualVotingBytes.length == 1 && manualVotingBytes[0] == '0') {
            manualVoting = false;
        } else if (keccak256(manualVotingBytes) == keccak256(bytes("false"))) {
            manualVoting = false;
        } else {
            revert("MANUAL_VOTING must be 'true', 'false', '1', or '0'");
        }

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setVotingMode(tokenId, manualVoting, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 MANUAL_VOTING=true forge script script/portfolio_account/helper/SetVotingMode.s.sol:SetVotingMode --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
