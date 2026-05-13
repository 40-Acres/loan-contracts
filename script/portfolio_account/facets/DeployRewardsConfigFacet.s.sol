// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

contract DeployRewardsConfigFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        RewardsConfigFacet facet = new RewardsConfigFacet(PORTFOLIO_FACTORY, SWAP_CONFIG);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "RewardsConfigFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address swapConfig) external {
        RewardsConfigFacet newFacet = new RewardsConfigFacet(portfolioFactory, swapConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "RewardsConfigFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = RewardsConfigFacet.setRecipient.selector;
        selectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        selectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        selectors[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        selectors[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        selectors[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        return selectors;
    }
}
