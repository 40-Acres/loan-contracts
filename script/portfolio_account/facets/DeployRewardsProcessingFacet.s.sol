// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

/**
 * @title DeployRewardsProcessingFacet
 * @dev Deploy RewardsProcessingFacet and RewardsConfigFacet contracts
 */
contract DeployRewardsProcessingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VAULT = vm.envAddress("VAULT");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        RewardsProcessingFacet newFacet = new VotingEscrowRewardsProcessingFacet(PORTFOLIO_FACTORY, SWAP_CONFIG, VOTING_ESCROW, VAULT, IVotingEscrow(VOTING_ESCROW).token());

        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "RewardsProcessingFacet", false);

        RewardsConfigFacet configFacet = new RewardsConfigFacet(PORTFOLIO_FACTORY);
        registerFacet(PORTFOLIO_FACTORY, address(configFacet), getSelectorsForConfigFacet(), "RewardsConfigFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address swapConfig, address votingEscrow, address vault) external {
        RewardsProcessingFacet newFacet = new VotingEscrowRewardsProcessingFacet(portfolioFactory, swapConfig, votingEscrow, vault, IVotingEscrow(votingEscrow).token());
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "RewardsProcessingFacet", true);

        RewardsConfigFacet configFacet = new RewardsConfigFacet(portfolioFactory);
        registerFacet(portfolioFactory, address(configFacet), getSelectorsForConfigFacet(), "RewardsConfigFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RewardsProcessingFacet.processRewards.selector;
        selectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        selectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        selectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        selectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        return selectors;
    }

    function getSelectorsForConfigFacet() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        selectors[1] = RewardsConfigFacet.setRecipient.selector;
        selectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        selectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        selectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        selectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        selectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        return selectors;
    }
}
