// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title DeployRewardsProcessingFacet
 * @dev Deploy RewardsProcessingFacet contract
 */
contract DeployRewardsProcessingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        RewardsProcessingFacet newFacet = new RewardsProcessingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, SWAP_CONFIG, VOTING_ESCROW);
        
        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "RewardsProcessingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address swapConfig, address votingEscrow) external {
        RewardsProcessingFacet newFacet = new RewardsProcessingFacet(portfolioFactory, portfolioAccountConfig, swapConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "RewardsProcessingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RewardsProcessingFacet.processRewards.selector;
        selectors[1] = RewardsProcessingFacet.setRewardsOption.selector;
        selectors[2] = RewardsProcessingFacet.getRewardsOption.selector;
        selectors[3] = RewardsProcessingFacet.getRewardsOptionPercentage.selector;
        selectors[4] = RewardsProcessingFacet.setRewardsToken.selector;
        selectors[5] = RewardsProcessingFacet.setRecipient.selector;
        selectors[6] = RewardsProcessingFacet.setRewardsOptionPercentage.selector;
        return selectors;
    }
}

