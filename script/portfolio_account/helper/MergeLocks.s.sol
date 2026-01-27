// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title MergeLocks
 * @dev Helper script to merge two voting escrow locks via PortfolioManager multicall
 *
 * The 'from' lock must be owned by the user (not in the portfolio),
 * and the 'to' lock must be owned by the portfolio (collateralized).
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/MergeLocks.s.sol:MergeLocks --sig "run(uint256,uint256)" <FROM_TOKEN_ID> <TO_TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: FROM_TOKEN_ID=1 TO_TOKEN_ID=2 forge script script/portfolio_account/helper/MergeLocks.s.sol:MergeLocks --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/MergeLocks.s.sol:MergeLocks --sig "run(uint256,uint256)" 1 2 --rpc-url $BASE_RPC_URL --broadcast
 */
contract MergeLocks is Script {
    using stdJson for string;

    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO on Base

    /**
     * @dev Merge two locks via PortfolioManager multicall
     * @param fromTokenId The token ID to merge from (owned by user)
     * @param toTokenId The token ID to merge into (owned by portfolio)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function mergeLocks(
        uint256 fromTokenId,
        uint256 toTokenId,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingEscrowFacet.merge.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingEscrowFacet.merge not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Verify ownership
        IVotingEscrow votingEscrow = IVotingEscrow(VOTING_ESCROW);
        require(votingEscrow.ownerOf(fromTokenId) == owner, "From token must be owned by the user");
        require(votingEscrow.ownerOf(toTokenId) == portfolioAddress, "To token must be owned by the portfolio");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            fromTokenId,
            toTokenId
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Locks merged successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("From Token ID:", fromTokenId);
        console.log("To Token ID:", toTokenId);
    }

    /**
     * @dev Main run function for forge script execution
     * @param fromTokenId The token ID to merge from (owned by user)
     * @param toTokenId The token ID to merge into (owned by portfolio)
     */
    function run(
        uint256 fromTokenId,
        uint256 toTokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        mergeLocks(fromTokenId, toTokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... FROM_TOKEN_ID=1 TO_TOKEN_ID=2 forge script script/portfolio_account/helper/MergeLocks.s.sol:MergeLocks --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 fromTokenId = vm.envUint("FROM_TOKEN_ID");
        uint256 toTokenId = vm.envUint("TO_TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        mergeLocks(fromTokenId, toTokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// FROM_TOKEN_ID=109382 TO_TOKEN_ID=109384 forge script script/portfolio_account/helper/MergeLocks.s.sol:MergeLocks --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
