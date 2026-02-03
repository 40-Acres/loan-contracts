// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {YieldBasisVotingFacet} from "../../../../src/facets/account/yieldbasis/YieldBasisVotingFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {IYieldBasisGaugeController} from "../../../../src/interfaces/IYieldBasisGaugeController.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../../utils/PortfolioHelperUtils.sol";

/**
 * @title VoteOnGauges (YieldBasis)
 * @dev Helper script to vote on YieldBasis gauge weights via PortfolioManager multicall
 *
 * veYB holders vote to direct YB emissions to liquidity gauges.
 * Weights are expressed in bps (0-10000, where 10000 = 100%).
 * There is a 10-day cooldown between vote changes per gauge.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run(address[],uint256[])" "[gauge1,gauge2]" "[weight1,weight2]" --rpc-url $ETH_RPC_URL --broadcast
 * 2. From env vars: GAUGES='["0x...","0x..."]' WEIGHTS='[5000,5000]' forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run(address[],uint256[])" "[0x1234...,0x5678...]" "[5000,5000]" --rpc-url $ETH_RPC_URL --broadcast
 */
contract VoteOnGauges is Script {
    using stdJson for string;

    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;

    /**
     * @dev Vote on gauges via PortfolioManager multicall
     * @param gauges Array of gauge addresses to vote for
     * @param weights Array of weights in bps for each gauge (must sum to <= 10000)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function voteOnGauges(
        address[] memory gauges,
        uint256[] memory weights,
        address owner
    ) internal {
        require(gauges.length == weights.length, "Gauges and weights arrays must have the same length");
        require(gauges.length > 0, "Must provide at least one gauge");

        // Validate total weight
        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        require(totalWeight <= 10000, "Total weight cannot exceed 10000 (100%)");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get YieldBasis factory
        PortfolioFactory factory = PortfolioHelperUtils.getYieldBasisFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = YieldBasisVotingFacet.vote.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "YieldBasisVotingFacet.vote not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please create a lock first.");

        // Check voting power directly from veYB
        IYieldBasisVotingEscrow veYB = IYieldBasisVotingEscrow(VE_YB);
        uint256 votingPower = veYB.balanceOf(portfolioAddress);
        require(votingPower > 0, "No voting power. Please create a veYB lock first.");
        console.log("Current Voting Power:", votingPower);

        // Check remaining voting power from gauge controller
        IYieldBasisGaugeController gaugeController = IYieldBasisGaugeController(GAUGE_CONTROLLER);
        uint256 usedPower = gaugeController.vote_user_power(portfolioAddress);
        uint256 remainingPower = 10000 - usedPower;
        console.log("Remaining Voting Power (bps):", remainingPower);

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(selector, gauges, weights);

        portfolioManager.multicall(calldatas, factories);

        console.log("Vote successful!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Number of gauges voted:", gauges.length);
        console.log("Total weight allocated (bps):", totalWeight);

        // Log individual votes
        for (uint256 i = 0; i < gauges.length; i++) {
            console.log("  Gauge:", gauges[i]);
            console.log("  Weight (bps):", weights[i]);
        }
    }

    /**
     * @dev Main run function for forge script execution
     * @param gauges Array of gauge addresses to vote for
     * @param weights Array of weights in bps for each gauge
     */
    function run(
        address[] memory gauges,
        uint256[] memory weights
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        voteOnGauges(gauges, weights, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... GAUGES='["0x...","0x..."]' WEIGHTS='[5000,5000]' forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
     */
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Parse gauges from JSON
        string memory gaugesJson = vm.envString("GAUGES");
        address[] memory gauges = vm.parseJsonAddressArray(gaugesJson, "");

        // Parse weights from JSON
        string memory weightsJson = vm.envString("WEIGHTS");
        uint256[] memory weights = vm.parseJsonUintArray(weightsJson, "");

        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        voteOnGauges(gauges, weights, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// GAUGES='["0x1234...","0x5678..."]' WEIGHTS='[5000,5000]' forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
// GAUGES='["0xf3081A2eB8927C0462864EC3FdbE927C842A0893","0xe4e656B5215a82009969219b1bAbB7c0757A3315","0x30ba8b27F2128c770B90C965FF671E08b9310D21","0xbc56e3edB67b56d598aCE07668b138815F45d7aa"]' WEIGHTS='[1500,2000,4000,2500]' forge script script/portfolio_account/yieldbasis/helper/VoteOnGauges.s.sol:VoteOnGauges --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
