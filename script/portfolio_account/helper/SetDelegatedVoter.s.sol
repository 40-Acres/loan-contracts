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
 * @title SetDelegatedVoter
 * @dev Helper script to set a delegated voter for a veNFT via PortfolioManager multicall
 *
 * A delegated voter can vote on behalf of the token owner using the delegateVote function.
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/SetDelegatedVoter.s.sol:SetDelegatedVoter --sig "run(uint256,address)" <TOKEN_ID> <DELEGATED_VOTER> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 DELEGATED_VOTER=0x... forge script script/portfolio_account/helper/SetDelegatedVoter.s.sol:SetDelegatedVoter --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/SetDelegatedVoter.s.sol:SetDelegatedVoter --sig "run(uint256,address)" 109384 0x1234... --rpc-url $BASE_RPC_URL --broadcast
 */
contract SetDelegatedVoter is Script {
    using stdJson for string;

    /**
     * @dev Set delegated voter via PortfolioManager multicall
     * @param tokenId The voting escrow token ID
     * @param delegatedVoter The address of the delegated voter (address(0) to remove delegation)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function setDelegatedVoter(
        uint256 tokenId,
        address delegatedVoter,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingFacet.setDelegatedVoter.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingFacet.setDelegatedVoter not registered in FacetRegistry. Please deploy facets first.");

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
            delegatedVoter
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Delegated voter set successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Delegated Voter:", delegatedVoter);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The voting escrow token ID
     * @param delegatedVoter The address of the delegated voter
     */
    function run(
        uint256 tokenId,
        address delegatedVoter
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        setDelegatedVoter(tokenId, delegatedVoter, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 DELEGATED_VOTER=0x... forge script script/portfolio_account/helper/SetDelegatedVoter.s.sol:SetDelegatedVoter --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        address delegatedVoter = vm.envAddress("DELEGATED_VOTER");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        setDelegatedVoter(tokenId, delegatedVoter, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 DELEGATED_VOTER=0x1234... forge script script/portfolio_account/helper/SetDelegatedVoter.s.sol:SetDelegatedVoter --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
