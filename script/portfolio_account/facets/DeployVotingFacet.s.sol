// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";

contract DeployVotingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_CONFIG = vm.envAddress("VOTING_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        VotingFacet facet = new VotingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_CONFIG, VOTING_ESCROW, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "VotingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingConfig, address votingEscrow, address voter) external {
        VotingFacet newFacet = new VotingFacet(portfolioFactory, portfolioAccountConfig, votingConfig, votingEscrow, voter);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "VotingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VotingFacet.vote.selector;
        selectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        selectors[2] = VotingFacet.setVotingMode.selector;
        selectors[3] = VotingFacet.isManualVoting.selector;
        selectors[4] = VotingFacet.defaultVote.selector;
        return selectors;
    }
}

